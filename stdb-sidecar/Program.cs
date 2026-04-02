using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using SpacetimeDB;
using SpacetimeDB.Types;

class Program
{
    static DbConnection? _db;
    static readonly int _sidecarPort = 27200;
    
    static readonly string API_VERSION = "1.0.0";
    static readonly ConcurrentQueue<InstructionQueue> _pending = new();
    static readonly SemaphoreSlim _syncGate = new SemaphoreSlim(0, 1);

    static readonly ConcurrentQueue<object> _deltaQueue = new();

    static readonly ConcurrentDictionary<uint, string> _steamHexByServerId = new();

    static async Task Main(string[] args)
    {
        string stdbUri = Environment.GetEnvironmentVariable("STDB_URI")  ?? "ws://127.0.0.1:3000";
        string stdbDb  = Environment.GetEnvironmentVariable("STDB_DB")   ?? "fivem-game";
        string token   = Environment.GetEnvironmentVariable("STDB_TOKEN") ?? "";

        Console.WriteLine($"[Sidecar] SpacetimeDB : {stdbUri}/{stdbDb}");
        Console.WriteLine($"[Sidecar] HTTP port   : {_sidecarPort}");

        _ = Task.Run(() => StartHttpListener());
        _ = Task.Run(SeedItemsWhenReady);

        await Connect(stdbUri, stdbDb, token);
    }

    static async Task Connect(string uri, string dbName, string token = "")
    {
        while (true)
        {
            try
            {
                Console.WriteLine("[Sidecar] Connecting to SpacetimeDB...");
                _db = DbConnection.Builder()
                    .WithUri(uri)
                    .WithDatabaseName(dbName)
                    .WithToken(token)
                    .OnConnect(OnConnected)
                    .OnConnectError((ex) => Console.WriteLine($"[Sidecar] Connect error: {ex.Message}"))
                    .OnDisconnect((conn, ex) => Console.WriteLine($"[Sidecar] Disconnected: {ex?.Message}"))
                    .Build();

                while (true) { _db.FrameTick(); await Task.Delay(50); }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[Sidecar] Fatal: {ex.Message} — retrying in 5s");
                await Task.Delay(5000);
            }
        }
    }

    static void OnConnected(DbConnection conn, Identity identity, string token)
    {
        Console.WriteLine($"[Sidecar] Connected. Identity: {identity}");
        conn.SubscriptionBuilder()
            .OnApplied(OnSubscriptionReady)
            .Subscribe(new[]
            {
                "SELECT * FROM instruction_queue WHERE consumed = false",
                "SELECT * FROM active_session",
                "SELECT * FROM player",
                "SELECT * FROM inventory_slot",
                "SELECT * FROM item_definition",
                "SELECT * FROM vehicle_inventory",
                "SELECT * FROM stash_definition",
            });
    }

    static void OnSubscriptionReady(SubscriptionEventContext ctx)
    {
        Console.WriteLine("[Sidecar] Subscription active. Signaling background tasks...");
        
        _db!.Db.InstructionQueue.OnInsert += OnInstructionInserted;

        _db!.Db.InventorySlot.OnInsert += (evCtx, slot) => {
            _deltaQueue.Enqueue(new { type = "added", slot = slot, owner_id = slot.OwnerId });
        };

        _db!.Db.InventorySlot.OnUpdate += (evCtx, oldSlot, newSlot) => {
            if (oldSlot.OwnerId != newSlot.OwnerId) {
                _deltaQueue.Enqueue(new { type = "deleted", slot_id = oldSlot.Id, owner_id = oldSlot.OwnerId });
            }
    _deltaQueue.Enqueue(new { type = "updated", slot = newSlot, owner_id = newSlot.OwnerId });
};

        _db!.Db.InventorySlot.OnDelete += (evCtx, slot) => {
            _deltaQueue.Enqueue(new { type = "deleted", slot_id = slot.Id, owner_id = slot.OwnerId });
        };

        _syncGate.Release();
    }

    static void OnInstructionInserted(EventContext ctx, InstructionQueue row)
    {
        if (row.Consumed) return;
        Console.WriteLine($"[Sidecar] Queued instruction #{row.Id}: opcode=0x{row.Opcode:X4}");
        _pending.Enqueue(row);
    }

    static void SeedItems()
    {
        Console.WriteLine("[Sidecar] Seeding item definitions...");
        foreach (var item in ItemSeed.Items)
        {
            try { _db!.Reducers.SeedItem(item.Id, item.Label, item.Weight,
                item.Stackable, item.Usable, item.MaxStack, item.Category,
                item.PropModel, item.MagCapacity, item.StoredCapacity, item.AmmoType); }
            catch (Exception ex) { Console.WriteLine($"[Sidecar] Seed error for {item.Id}: {ex.Message}"); }
        }

        // Starter kit seeding — configurable without touching Rust source
        var starterKit = new[] {
            ("phone", 1u), ("id_card", 1u), ("water_bottle", 2u),
            ("food_burger", 1u), ("bandage", 5u), ("cash", 500u),
            ("backpack", 1u),
        };
        Console.WriteLine("[Sidecar] Seeding starter kit...");
        foreach (var (itemId, qty) in starterKit)
        {
            try { _db!.Reducers.SeedStarterKit(itemId, qty); }
            catch (Exception ex) { Console.WriteLine($"[Sidecar] StarterKit seed error for {itemId}: {ex.Message}"); }
        }
        Console.WriteLine("[Sidecar] Seeding complete.");
    }

    // ── HTTP Listener ─────────────────────────────────────────────────────────

    static async Task StartHttpListener()
    {
        var listener = new HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{_sidecarPort}/");
        listener.Start();
        Console.WriteLine($"[Sidecar] HTTP listener on :{_sidecarPort}");

        while (true)
        {
            try
            {
                var ctx = await listener.GetContextAsync();
                _ = Task.Run(() => HandleRequest(ctx));
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[Sidecar] Listener error: {ex.Message}");
            }
        }
    }

    static async Task HandleRequest(HttpListenerContext ctx)
    {
        try
        {
            string path = ctx.Request.Url?.AbsolutePath ?? "";

            if (_db == null && path != "/version")
                    {
                        ctx.Response.StatusCode = 503;
                        var notReady = System.Text.Encoding.UTF8.GetBytes(
                            "{\"error\":\"sidecar_not_ready\",\"message\":\"SpacetimeDB connection pending\"}");
                        ctx.Response.ContentType = "application/json";
                        await ctx.Response.OutputStream.WriteAsync(notReady);
                        ctx.Response.Close();
                        return;
                    }

            if (ctx.Request.HttpMethod == "GET" && path == "/instructions")
            {
                var batch = new List<object>();
                while (_pending.TryDequeue(out var instr))
                {
                    batch.Add(new {
                        id                   = instr.Id,
                        target_entity_net_id = instr.TargetEntityNetId,
                        opcode               = instr.Opcode,
                        payload              = instr.Payload
                    });
                }
                await WriteJson(ctx, batch);
                return;
            }

            if (ctx.Request.HttpMethod == "POST" && path == "/seed-item")
                {
                    using var reader = new System.IO.StreamReader(ctx.Request.InputStream);
                    string body = await reader.ReadToEndAsync();
                    try
                    {
                        using var doc = JsonDocument.Parse(body);
                        var r = doc.RootElement;
                        _db!.Reducers.SeedItem(
                            r.GetProperty("item_id").GetString()    ?? "",
                            r.GetProperty("label").GetString()      ?? "",
                            (float)r.GetProperty("weight").GetDouble(),
                            r.GetProperty("stackable").GetBoolean(),
                            r.GetProperty("usable").GetBoolean(),
                            r.GetProperty("max_stack").GetUInt32(),
                            r.GetProperty("category").GetString()   ?? "misc",
                            r.TryGetProperty("prop_model",      out var pm) ? pm.GetString()  ?? "prop_cs_cardbox_01" : "prop_cs_cardbox_01",
                            r.TryGetProperty("mag_capacity",    out var mc) ? mc.GetInt32()    : 0,
                            r.TryGetProperty("stored_capacity", out var sc) ? sc.GetInt32()    : 0,
                            r.TryGetProperty("ammo_type",       out var at) ? at.GetString() ?? "" : ""
                        );
                        ctx.Response.StatusCode = 200; ctx.Response.Close();
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine($"[Sidecar] /seed-item error: {ex.Message}");
                        ctx.Response.StatusCode = 400; ctx.Response.Close();
                    }
                    return;
                }

            if (ctx.Request.HttpMethod == "GET" && path == "/slot-deltas")
            {
                var deltas = new List<object>();
                while (_deltaQueue.TryDequeue(out var delta))
                {
                    deltas.Add(delta);
                }
                await WriteJson(ctx, deltas);
                return;
            }

            if (ctx.Request.HttpMethod == "GET" && path == "/item-count")
{
                var qs      = System.Web.HttpUtility.ParseQueryString(ctx.Request.Url?.Query ?? "");
                string ownId = qs["owner_id"] ?? "";
                string itmId = qs["item_id"]  ?? "";

                if (string.IsNullOrEmpty(ownId) || string.IsNullOrEmpty(itmId))
                {
                    ctx.Response.StatusCode = 400; ctx.Response.Close(); return;
                }

                uint count = 0;
                if (_db != null)
                {
                    foreach (var slot in _db.Db.InventorySlot.Iter()
                        .Where(s => s.OwnerId == ownId && s.ItemId == itmId))
                    {
                        count += slot.Quantity;
                    }
                }

                await WriteJson(ctx, new { owner_id = ownId, item_id = itmId, count, has_item = count > 0 });
                return;
            }

            // ── POST /consumed — Lua confirms instructions were processed ──────
            if (ctx.Request.HttpMethod == "POST" && path == "/consumed")
            {
                using var reader = new System.IO.StreamReader(ctx.Request.InputStream);
                string body = await reader.ReadToEndAsync();
                using var doc = JsonDocument.Parse(body);
                foreach (var item in doc.RootElement.EnumerateArray())
                {
                    ulong id = item.GetUInt64();
                    _db?.Reducers.MarkInstructionConsumed(id);
                }
                ctx.Response.StatusCode = 200;
                ctx.Response.Close();
                return;
            }

            // ── POST /reducer — all reducer calls and data queries from Lua ────
            if (ctx.Request.HttpMethod == "POST" && path == "/reducer")
            {
                using var reader = new System.IO.StreamReader(ctx.Request.InputStream);
                string body = await reader.ReadToEndAsync();
                using var doc = JsonDocument.Parse(body);
                string name = doc.RootElement.GetProperty("name").GetString() ?? "";
                var    args = doc.RootElement.GetProperty("args");

                Console.WriteLine($"[Sidecar] Reducer call: {name}");

                if (_db == null) { ctx.Response.StatusCode = 503; ctx.Response.Close(); return; }

                switch (name)
                {
                    // ── Player ─────────────────────────────────────────────────
                        case "on_player_connect":
                            var connectServerId = args.GetProperty("server_id").GetUInt32();
                            var connectHex      = args.GetProperty("steam_hex").GetString() ?? "";
                            _db.Reducers.OnPlayerConnect(
                                connectHex,
                                args.GetProperty("display_name").GetString() ?? "",
                                connectServerId,
                                args.GetProperty("net_id").GetUInt32(),
                                args.TryGetProperty("heading", out var h) ? h.GetSingle() : 0.0f
                            );
                            // Track steam_hex so disconnect can find the right player
                            if (!string.IsNullOrEmpty(connectHex))
                                _steamHexByServerId[connectServerId] = connectHex;
                            break;

                        case "on_player_disconnect":
                        {
                            uint discServerId = args.TryGetProperty("server_id", out var sidEl)
                                ? sidEl.GetUInt32() : 0;
                            if (discServerId > 0 && _steamHexByServerId.TryRemove(discServerId, out var discHex))
                            {
                                _db.Reducers.OnPlayerDisconnect(discHex);
                            }
                            break;
                        }

                        case "request_spawn":
                        {
                            // Resolve steam_hex from the active session map using server_id
                            uint spawnServerId = args.GetProperty("server_id").GetUInt32();
                            if (!_steamHexByServerId.TryGetValue(spawnServerId, out var spawnHex))
                            {
                                Console.WriteLine($"[Sidecar] request_spawn: no steam_hex for server_id={spawnServerId}");
                                ctx.Response.StatusCode = 400; ctx.Response.Close(); return;
                            }
                            _db.Reducers.RequestSpawn(
                                spawnHex,
                                args.GetProperty("spawn_x").GetSingle(),
                                args.GetProperty("spawn_y").GetSingle(),
                                args.GetProperty("spawn_z").GetSingle(),
                                args.GetProperty("heading").GetSingle()
                            );
                            break;
                        }

                    // ── Inventory ──────────────────────────────────────────────
                    case "move_item":
                        _db.Reducers.MoveItem(
                            args.GetProperty("slot_id").GetUInt64(),
                            args.GetProperty("new_slot_index").GetUInt32()
                        );
                        break;

                    case "transfer_item":
                        _db.Reducers.TransferItem(
                            args.GetProperty("slot_id").GetUInt64(),
                            args.GetProperty("new_owner_id").GetString()   ?? "",
                            args.GetProperty("new_owner_type").GetString() ?? "player",
                            args.GetProperty("new_slot_index").GetUInt32()
                        );
                        break;

                    case "transfer_item_to_player":
                        {
                            ulong tSlotId   = args.GetProperty("slot_id").GetUInt64();
                            uint  tServerId = args.GetProperty("server_id").GetUInt32();
                        
                            var tSession = _db!.Db.ActiveSession.Iter()
                                .FirstOrDefault(a => a.ServerId == tServerId);
                        
                            if (tSession == null)
                            {
                                await WriteJson(ctx, new { ok = false, error = "player not online" });
                                return;
                            }
                        
                            var tIdentity = tSession.SteamHex;
                        
                            var tSlot = _db!.Db.InventorySlot.Iter().FirstOrDefault(s => s.Id == tSlotId);
                            if (tSlot == null || string.IsNullOrEmpty(tSlot.OwnerId))
                            {
                                await WriteJson(ctx, new { ok = false, error = "slot not found" });
                                return;
                            }
                        
                            try
                            {
                                _db!.Reducers.RemoveItem(tSlot.OwnerId, tSlot.ItemId, tSlot.Quantity);
                                _db!.Reducers.GiveItemToIdentity(tIdentity, tSlot.ItemId, tSlot.Quantity, tSlot.Metadata);
                                await WriteJson(ctx, new { ok = true, owner_id = tIdentity });
                            }
                            catch (Exception ex) when (ex.Message.Contains("WEIGHT_LIMIT"))
                            {
                                var parts = ex.Message.Split('|');
                                await WriteJson(ctx, new {
                                    ok         = false,
                                    error_code = "WEIGHT_LIMIT",
                                    actual_kg  = parts.Length > 1 ? parts[1] : "?",
                                    max_kg     = parts.Length > 2 ? parts[2] : "?",
                                });
                            }
                            catch (Exception ex)
                            {
                                Console.WriteLine($"[Sidecar] transfer_item_to_player error: {ex.Message}");
                                await WriteJson(ctx, new { ok = false, error_code = "REDUCER_ERROR", message = ex.Message });
                            }
                            return;
                        }

                    case "use_item":
                        _db.Reducers.UseItem(
                            args.GetProperty("slot_id").GetUInt64(),
                            args.GetProperty("net_id").GetUInt32()
                        );
                        break;

                    case "add_item":
                        {
                            string aiOwnerId   = args.GetProperty("owner_id").GetString()   ?? "";
                            string aiOwnerType = args.GetProperty("owner_type").GetString() ?? "player";
                            string aiItemId    = args.GetProperty("item_id").GetString()    ?? "";
                            uint   aiQty       = args.GetProperty("quantity").GetUInt32();
                            string aiMeta      = args.TryGetProperty("metadata", out var amEl) ? amEl.GetString() ?? "{}" : "{}";

                            if (aiMeta == "{}" || string.IsNullOrEmpty(aiMeta))
                            {
                                var aiDef = _db!.Db.ItemDefinition.Iter()
                                    .FirstOrDefault(d => d.ItemId == aiItemId);
                                if (aiDef != null && aiDef.Category == "weapon")
                                {
                                    var serial = $"WPN-{Guid.NewGuid().ToString("N")[..8].ToUpper()}";
                                    aiMeta = JsonSerializer.Serialize(new {
                                        serial          = serial,
                                        mag_ammo        = 0,
                                        stored_ammo     = 0,
                                        mag_capacity    = aiDef.MagCapacity,
                                        stored_capacity = aiDef.StoredCapacity,
                                        durability      = 100,
                                        ammo_type       = aiDef.AmmoType,
                                    });
                                }
                            }

                            _db!.Reducers.AddItem(aiOwnerId, aiOwnerType, aiItemId, aiQty, aiMeta);
                            await WriteJson(ctx, new { ok = true });
                            return;
                        }

                    case "remove_item":
                        _db.Reducers.RemoveItem(
                            args.GetProperty("owner_id").GetString() ?? "",
                            args.GetProperty("item_id").GetString()  ?? "",
                            args.GetProperty("quantity").GetUInt32()
                        );
                        break;

                    // ── Vehicle inventory ──────────────────────────────────────
                    case "create_vehicle_inventory":
                        // GTA model hashes are signed ints — cast to uint to avoid format errors
                        int rawHash = args.GetProperty("model_hash").GetInt32();
                        uint modelHash = (uint)rawHash;
                        _db.Reducers.CreateVehicleInventory(
                            args.GetProperty("plate").GetString()          ?? "",
                            modelHash,
                            args.GetProperty("trunk_type").GetString()     ?? "rear",
                            args.GetProperty("trunk_slots").GetUInt32(),
                            (float)args.GetProperty("trunk_max_weight").GetDouble()
                        );
                        break;

                    // ── Stashes ────────────────────────────────────────────────
                    case "create_stash":
                        _db.Reducers.CreateStash(
                            args.GetProperty("stash_id").GetString()   ?? "",
                            args.GetProperty("stash_type").GetString() ?? "world",
                            args.GetProperty("label").GetString()      ?? "",
                            args.GetProperty("max_slots").GetUInt32(),
                            (float)args.GetProperty("max_weight").GetDouble(),
                            args.GetProperty("owner_id").GetString()   ?? "",
                            (float)args.GetProperty("pos_x").GetDouble(),
                            (float)args.GetProperty("pos_y").GetDouble(),
                            (float)args.GetProperty("pos_z").GetDouble()
                        );
                        break;

                    case "delete_stash":
                        _db.Reducers.DeleteStash(
                            args.GetProperty("stash_id").GetString() ?? ""
                        );
                        break;

                    // ── Data queries (return JSON directly) ────────────────────
                    case "get_player_inventory":
                    {
                        uint   serverId      = args.GetProperty("server_id").GetUInt32();
                        var    slots         = new List<object>();
                        var    equippedSlots = new List<object>();
                        var    defs          = new Dictionary<string, object>();
                        string ownerId       = "";

                        try
                        {
                            var session = _db.Db.ActiveSession.Iter()
                                .FirstOrDefault(a => a.ServerId == serverId);

                            if (session != null)
                            {
                                 ownerId = session.SteamHex;

                                foreach (var s in _db!.Db.InventorySlot.Iter()
                                    .Where(s => s.OwnerId == ownerId && s.OwnerType == "player"))
                                {
                                    slots.Add(new {
                                        id         = s.Id,
                                        owner_id   = s.OwnerId,
                                        owner_type = s.OwnerType,
                                        item_id    = s.ItemId,
                                        quantity   = s.Quantity,
                                        metadata   = s.Metadata,
                                        slot_index = s.SlotIndex,
                                    });
                                }

                                foreach (var s in _db!.Db.InventorySlot.Iter()
                                    .Where(s => s.OwnerId.StartsWith(ownerId + "_equip_") && s.OwnerType == "equip"))
                                {
                                    equippedSlots.Add(new {
                                        id         = s.Id,
                                        owner_id   = s.OwnerId,
                                        owner_type = s.OwnerType,
                                        item_id    = s.ItemId,
                                        quantity   = s.Quantity,
                                        metadata   = s.Metadata,
                                        slot_index = s.SlotIndex,
                                        equip_key  = s.OwnerId.Replace(ownerId + "_equip_", ""),
                                    });
                                }
                            }

                            foreach (var d in _db.Db.ItemDefinition.Iter())
                            {
                                defs[d.ItemId] = new {
                                    item_id         = d.ItemId,
                                    label           = d.Label,
                                    weight          = d.Weight,
                                    stackable       = d.Stackable,
                                    usable          = d.Usable,
                                    max_stack       = d.MaxStack,
                                    category        = d.Category,
                                    prop_model      = d.PropModel,
                                    mag_capacity    = d.MagCapacity,
                                    stored_capacity = d.StoredCapacity,
                                    ammo_type       = d.AmmoType,
                                };
                            }
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine($"[Sidecar] get_player_inventory error: {ex.Message}");
                        }

                        object? backpackData = null;
                        try
                        {
                            var bpSlot = _db!.Db.InventorySlot.Iter()
                                .FirstOrDefault(s => s.OwnerId == ownerId + "_equip_backpack" && s.OwnerType == "equip");
                            if (bpSlot != null && !string.IsNullOrEmpty(bpSlot.OwnerId))
                            {
                                string bpStashId      = $"backpack_slot_{bpSlot.Id}";
                                string bpStashIdLegacy = $"backpack_{ownerId}";
                                string bpItemId   = bpSlot.ItemId;
                                uint   bpMaxSlots = bpItemId == "duffel_bag" ? 30u : 20u;
                                float  bpWeight   = bpItemId == "duffel_bag" ? 50f  : 30f;
                                string bpLabel    = bpItemId == "duffel_bag" ? "DUFFEL BAG" : "BACKPACK";
                                try { _db!.Reducers.CreateStash(bpStashId, "backpack", bpLabel, bpMaxSlots, bpWeight, ownerId, 0f, 0f, 0f); } catch { }

                                var bpSlotList = _db!.Db.InventorySlot.Iter()
                                    .Where(s => (s.OwnerId == bpStashId || s.OwnerId == bpStashIdLegacy) && s.OwnerType == "stash")
                                    .Select(s => (object)new {
                                        id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType,
                                        item_id = s.ItemId, quantity = s.Quantity,
                                        metadata = s.Metadata, slot_index = s.SlotIndex,
                                    }).ToList();

                                backpackData = new {
                                    stash_id   = bpStashId,
                                    label      = bpLabel,
                                    max_weight = bpWeight,
                                    max_slots  = (int)bpMaxSlots,
                                    slots      = bpSlotList,
                                };
                            }
                        }
                        catch (Exception ex) { Console.WriteLine($"[Sidecar] backpack inline error: {ex.Message}"); }

                        await WriteJson(ctx, new {
                            server_id      = serverId,
                            owner_id       = ownerId,
                            slots,
                            equipped_slots = equippedSlots,
                            backpack_data  = backpackData,
                            item_defs      = defs,
                            max_weight     = 85,
                        });
                        return;
                    }

                    case "get_vehicle_inventory":
                    {
                        string plate         = args.GetProperty("plate").GetString()          ?? "";
                        string inventoryType = args.GetProperty("inventory_type").GetString() ?? "glovebox";

                        var config   = _db.Db.VehicleInventory.Iter().FirstOrDefault(v => v.Plate == plate);
                        bool hasConfig = config != null;
                        float  maxWeight = inventoryType == "trunk" ? (hasConfig ? config.TrunkMaxWeight : 50f) : 10f;
                        uint   maxSlots  = inventoryType == "trunk" ? (hasConfig ? config.TrunkSlots : 20u)     : 5u;
                        string ownerType = inventoryType == "trunk"  ? "vehicle_trunk" : "vehicle_glovebox";

                        var vSlots = _db!.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == plate && s.OwnerType == ownerType)
                            .Select(s => new {
                                id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType,
                                item_id = s.ItemId, quantity = s.Quantity,
                                metadata = s.Metadata, slot_index = s.SlotIndex,
                            });

                        var vDefs = _db.Db.ItemDefinition.Iter()
                            .ToDictionary(d => d.ItemId, d => (object)new {
                                item_id = d.ItemId, label = d.Label, weight = d.Weight,
                                stackable = d.Stackable, usable = d.Usable, max_stack = d.MaxStack,
                                category = d.Category, prop_model = d.PropModel,
                                mag_capacity = d.MagCapacity, stored_capacity = d.StoredCapacity,
                                ammo_type = d.AmmoType,
                            });

                        await WriteJson(ctx, new {
                            plate, inventory_type = inventoryType,
                            trunk_type = hasConfig ? config.TrunkType : "none",
                            slots      = vSlots,
                            item_defs  = vDefs,
                            max_weight = maxWeight,
                            max_slots  = maxSlots,
                        });
                        return;
                    }

                    case "get_inventory_slots":
                    {
                        string gsOwnerType = args.GetProperty("owner_type").GetString() ?? "";
                        string gsOwnerId   = args.GetProperty("owner_id").GetString()   ?? "";
                        var gsSlots = _db!.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == gsOwnerId && s.OwnerType == gsOwnerType)
                            .Select(s => (object)new {
                                id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType,
                                item_id = s.ItemId, quantity = s.Quantity,
                                metadata = s.Metadata, slot_index = s.SlotIndex,
                            }).ToList();
                        await WriteJson(ctx, new { slots = gsSlots });
                        return;
                    }

                    case "merge_stacks":
                    {
                        ulong srcId = args.GetProperty("src_slot_id").GetUInt64();
                        ulong dstId = args.GetProperty("dst_slot_id").GetUInt64();
                        _db!.Reducers.MergeStacks(srcId, dstId);
                        await WriteJson(ctx, new { ok = true });
                        return;
                    }

                    case "split_stack":
                    {
                        ulong splitSlotId = args.GetProperty("slot_id").GetUInt64();
                        uint  splitAmount = args.GetProperty("amount").GetUInt32();
                        _db!.Reducers.SplitStack(splitSlotId, splitAmount);
                        await WriteJson(ctx, new { ok = true });
                        return;
                    }
                    case "move_item_partial":
                    {
                        ulong  mpSlotId     = args.GetProperty("slot_id").GetUInt64();
                        uint   mpQty        = args.GetProperty("quantity").GetUInt32();
                        string mpOwnerId    = args.TryGetProperty("new_owner_id",   out var mpOI) ? mpOI.GetString() ?? "" : "";
                        string mpOwnerType  = args.TryGetProperty("new_owner_type", out var mpOT) ? mpOT.GetString() ?? "" : "";
                        uint   mpSlotIndex  = args.TryGetProperty("new_slot_index", out var mpSI) ? mpSI.GetUInt32() : 0u;

                        var mpSrc = _db!.Db.InventorySlot.Iter().FirstOrDefault(s => s.Id == mpSlotId);
                        if (mpSrc == null) { await WriteJson(ctx, new { ok = false, error = "slot not found" }); return; }

                        if (mpQty >= mpSrc.Quantity)
                        {
                            // Full move — delegate to existing reducers
                            if (string.IsNullOrEmpty(mpOwnerId) || mpOwnerType == "player")
                                _db!.Reducers.MoveItem(mpSlotId, mpSlotIndex);
                            else
                                _db!.Reducers.TransferItem(mpSlotId, mpOwnerId, mpOwnerType, mpSlotIndex);
                        }
                        else
                        {
                            // Partial: split off mpQty, then transfer the split portion
                            _db!.Reducers.SplitStack(mpSlotId, mpQty);
                            await Task.Delay(80);

                            // Find the newly split slot (same owner, same item, quantity == mpQty, newest ID)
                            var mpSplit = _db!.Db.InventorySlot.Iter()
                                .Where(s => s.OwnerId  == mpSrc.OwnerId
                                        && s.OwnerType == mpSrc.OwnerType
                                        && s.ItemId   == mpSrc.ItemId
                                        && s.Quantity == mpQty
                                        && s.Id       != mpSlotId)
                                .OrderByDescending(s => s.Id)
                                .FirstOrDefault();

                            if (mpSplit != null)
                            {
                                if (string.IsNullOrEmpty(mpOwnerId) || mpOwnerType == "player")
                                    _db!.Reducers.MoveItem(mpSplit.Id, mpSlotIndex);
                                else
                                    _db!.Reducers.TransferItem(mpSplit.Id, mpOwnerId, mpOwnerType, mpSlotIndex);
                            }
                        }

                        await WriteJson(ctx, new { ok = true });
                        return;
                    }

                    case "open_backpack":
                    {
                        string bpOwnerId  = args.GetProperty("owner_identity").GetString() ?? "";
                        string bpItemId   = args.GetProperty("bag_item_id").GetString()    ?? "backpack";
                        ulong  bpSlotId   = args.TryGetProperty("bag_slot_id", out var bsid) ? bsid.GetUInt64() : 0;

                        string bpStashId = bpSlotId > 0
                            ? $"backpack_slot_{bpSlotId}"
                            : $"backpack_{bpOwnerId}";

                        uint   bpMaxSlots  = bpItemId == "duffel_bag" ? 30u  : 20u;
                        float  bpMaxWeight = bpItemId == "duffel_bag" ? 50f  : 30f;
                        string bpLabel     = bpItemId == "duffel_bag" ? "DUFFEL BAG" : "BACKPACK";

                        try
                        {
                            _db!.Reducers.CreateStash(
                                bpStashId, "backpack", bpLabel,
                                bpMaxSlots, bpMaxWeight,
                                bpOwnerId,
                                0f, 0f, 0f
                            );
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine($"[Sidecar] open_backpack CreateStash error: {ex.Message}");
                        }

                        string bpLegacyId = $"backpack_{bpOwnerId}";
                        var bpSlots = _db!.Db.InventorySlot.Iter()
                            .Where(s =>
                                (s.OwnerId == bpStashId || s.OwnerId == bpLegacyId)
                                && s.OwnerType == "stash")
                            .Select(s => (object)new {
                                id         = s.Id,
                                owner_id   = s.OwnerId,
                                owner_type = s.OwnerType,
                                item_id    = s.ItemId,
                                quantity   = s.Quantity,
                                metadata   = s.Metadata,
                                slot_index = s.SlotIndex,
                            }).ToList();

                        var bpDefs = _db!.Db.ItemDefinition.Iter()
                            .ToDictionary(
                                d => d.ItemId,
                                d => (object)new {
                                    item_id         = d.ItemId,
                                    label           = d.Label,
                                    weight          = d.Weight,
                                    stackable       = d.Stackable,
                                    usable          = d.Usable,
                                    max_stack       = d.MaxStack,
                                    category        = d.Category,
                                    prop_model      = d.PropModel,
                                    mag_capacity    = d.MagCapacity,
                                    stored_capacity = d.StoredCapacity,
                                    ammo_type       = d.AmmoType,
                                });

                        await WriteJson(ctx, new {
                            stash_id   = bpStashId,
                            label      = bpLabel,
                            max_weight = bpMaxWeight,
                            max_slots  = (int)bpMaxSlots,
                            slots      = bpSlots,
                            item_defs  = bpDefs,
                            ok         = true,
                        });
                        return;
                    }

                    case "drop_item_to_ground":
                    {
                        ulong dropSlotId = args.GetProperty("slot_id").GetUInt64();
                        uint  dropQty    = args.TryGetProperty("quantity", out var dqEl) ? dqEl.GetUInt32() : 0;
                        float dx = (float)args.GetProperty("x").GetDouble();
                        float dy = (float)args.GetProperty("y").GetDouble();
                        float dz = (float)args.GetProperty("z").GetDouble();
                        var preDrop = _db!.Db.InventorySlot.Iter().FirstOrDefault(s => s.Id == dropSlotId);
                        if (preDrop == null || string.IsNullOrEmpty(preDrop.OwnerId))
                        {
                            await WriteJson(ctx, new { ok = false, error = "slot not found" });
                            return;
                        }
                        try { _db!.Reducers.DropItemToGround(dropSlotId, dropQty, dx, dy, dz); }
                        catch (Exception ex)
                        {
                            await WriteJson(ctx, new { ok = false, error = ex.Message });
                            return;
                        }
                        await Task.Delay(80);
                        float srSq = 25f;
                        var resolvedStash = _db!.Db.StashDefinition.Iter()
                            .Where(s => s.StashType == "ground")
                            .Where(s => { float ex2 = s.PosX - dx, ey = s.PosY - dy; return ex2*ex2 + ey*ey <= srSq; })
                            .OrderBy(s => { float ex2 = s.PosX - dx, ey = s.PosY - dy; return ex2*ex2 + ey*ey; })
                            .FirstOrDefault();
                        if (resolvedStash == null) { await WriteJson(ctx, new { ok = false, error = "ground stash not found" }); return; }
                        var newSlot = _db!.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == resolvedStash.StashId && s.OwnerType == "stash" && s.ItemId == preDrop.ItemId)
                            .FirstOrDefault();
                        await WriteJson(ctx, new { ok = true, stash_id = resolvedStash.StashId, new_slot_id = newSlot?.Id ?? 0UL });
                        return;
                    }

                    case "find_or_create_ground_stash":
                    {
                        float gx = (float)args.GetProperty("x").GetDouble();
                        float gy = (float)args.GetProperty("y").GetDouble();
                        float gz = (float)args.GetProperty("z").GetDouble();
                        try { _db!.Reducers.FindOrCreateGroundStash(gx, gy, gz); }
                        catch (Exception ex) { await WriteJson(ctx, new { ok = false, error = ex.Message }); return; }
                        await Task.Delay(80);
                        float gsRSq = 25f;
                        var gsStash = _db!.Db.StashDefinition.Iter()
                            .Where(s => s.StashType == "ground")
                            .Where(s => { float ex2 = s.PosX - gx, ey = s.PosY - gy; return ex2*ex2 + ey*ey <= gsRSq; })
                            .OrderBy(s => { float ex2 = s.PosX - gx, ey = s.PosY - gy; return ex2*ex2 + ey*ey; })
                            .FirstOrDefault();
                        string gsStashId = gsStash?.StashId ?? "";
                        var gsSlots = _db!.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == gsStashId && s.OwnerType == "stash")
                            .Select(s => (object)new {
                                id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType,
                                item_id = s.ItemId, quantity = s.Quantity, metadata = s.Metadata, slot_index = s.SlotIndex,
                            }).ToList();
                        var gsDefs = _db!.Db.ItemDefinition.Iter()
                            .ToDictionary(d => d.ItemId, d => (object)new {
                                item_id = d.ItemId, label = d.Label, weight = d.Weight,
                                stackable = d.Stackable, usable = d.Usable, max_stack = d.MaxStack,
                                category = d.Category, prop_model = d.PropModel,
                            });
                        await WriteJson(ctx, new {
                            stash_id = gsStashId, label = "GROUND", max_weight = 999f, max_slots = 50,
                            slots = gsSlots, item_defs = gsDefs,
                        });
                        return;
                    }

                    case "get_stash_pos":
                    {
                        string spStashId = args.GetProperty("stash_id").GetString() ?? "";
                        var spDef = _db!.Db.StashDefinition.Iter().FirstOrDefault(s => s.StashId == spStashId);
                        await WriteJson(ctx, spDef != null
                            ? new { pos_x = spDef.PosX, pos_y = spDef.PosY, pos_z = spDef.PosZ }
                            : new { pos_x = 0f,         pos_y = 0f,         pos_z = 0f });
                        return;
                    }

                    case "get_stash_inventory":
                    {
                        string stashId  = args.GetProperty("stash_id").GetString() ?? "";
                        var def         = _db.Db.StashDefinition.Iter().FirstOrDefault(s => s.StashId == stashId);
                        bool hasConfig  = def != null;
                        var siSlots     = _db!.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == stashId && s.OwnerType == "stash")
                            .Select(s => new {
                                id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType,
                                item_id = s.ItemId, quantity = s.Quantity,
                                metadata = s.Metadata, slot_index = s.SlotIndex,
                            });
                        var siDefs      = _db.Db.ItemDefinition.Iter()
                            .ToDictionary(d => d.ItemId, d => (object)new {
                                item_id = d.ItemId, label = d.Label, weight = d.Weight,
                                stackable = d.Stackable, usable = d.Usable, max_stack = d.MaxStack,
                            });
                        await WriteJson(ctx, new {
                            stash_id   = stashId,
                            label      = hasConfig ? def.Label     : stashId,
                            max_weight = hasConfig ? def.MaxWeight : 100f,
                            max_slots  = hasConfig ? def.MaxSlots  : 20u,
                            slots      = siSlots,
                            item_defs  = siDefs,
                        });
                        return;
                    }

                    case "give_item_to_player":
                        {
                            uint   gServerId = args.GetProperty("server_id").GetUInt32();
                            string gItemId   = args.GetProperty("item_id").GetString()  ?? "";
                            uint   gQty      = args.TryGetProperty("quantity", out var gqEl) ? gqEl.GetUInt32() : 1;
                        
                            // ── Identity resolution — sidecar's sole responsibility here
                            var gSession = _db!.Db.ActiveSession.Iter()
                                .FirstOrDefault(a => a.ServerId == gServerId);
                                if (gSession == null) 
                                {
                                    await WriteJson(ctx, new { ok = false, error = "player not found" });
                                    return;
                                }
                        
                            var gIdentity = gSession.SteamHex;
                        
                            // ── Delegate everything else to Rust
                            // Passing "{}" signals give_item_to_identity to auto-generate weapon metadata.
                            // Slot-finding, weight gate, and stack merge all run inside the transaction.
                            try
                            {
                                _db!.Reducers.GiveItemToIdentity(gIdentity, gItemId, gQty, "{}");
                                await WriteJson(ctx, new { ok = true, owner_id = gIdentity });
                            }
                            catch (Exception ex) when (ex.Message.Contains("WEIGHT_LIMIT"))
                            {
                                var parts = ex.Message.Split('|');
                                await WriteJson(ctx, new {
                                    ok         = false,
                                    error_code = "WEIGHT_LIMIT",
                                    actual_kg  = parts.Length > 1 ? parts[1] : "?",
                                    max_kg     = parts.Length > 2 ? parts[2] : "?",
                                });
                            }
                            catch (Exception ex)
                            {
                                Console.WriteLine($"[Sidecar] give_item_to_player error: {ex.Message}");
                                await WriteJson(ctx, new { ok = false, error_code = "REDUCER_ERROR", message = ex.Message });
                            }
                            return;
                        }

                    default:
                        Console.WriteLine($"[Sidecar] Unknown reducer: {name}");
                        ctx.Response.StatusCode = 400;
                        ctx.Response.Close();
                        return;
                }

                ctx.Response.StatusCode = 200;
                ctx.Response.Close();
                return;
            }

            ctx.Response.StatusCode = 404;
            ctx.Response.Close();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[Sidecar] Request error: {ex.Message}");
            try { ctx.Response.StatusCode = 500; ctx.Response.Close(); } catch { }
        }
    }

        static async Task WriteJson(HttpListenerContext ctx, object data)
        {
            var json  = JsonSerializer.Serialize(data);
            var bytes = Encoding.UTF8.GetBytes(json);
            ctx.Response.ContentType = "application/json";
            ctx.Response.StatusCode  = 200;
            ctx.Response.Headers["X-HyprFM-Version"] = API_VERSION;   // ← add this line
            await ctx.Response.OutputStream.WriteAsync(bytes);
            ctx.Response.Close();
        }

  static async Task SeedItemsWhenReady()
    {
        await _syncGate.WaitAsync();
        Console.WriteLine("[Sidecar] Seeding item definitions...");
        SeedItems(); 
    }
}