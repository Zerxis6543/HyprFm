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
    static readonly ConcurrentQueue<InstructionQueue> _pending = new();
    static readonly SemaphoreSlim _syncGate = new SemaphoreSlim(0, 1);

    static readonly ConcurrentQueue<object> _deltaQueue = new();

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
        Console.WriteLine($"[Sidecar] Queued instruction #{row.Id}: {row.NativeKey}");
        _pending.Enqueue(row);
    }

    static void SeedItems()
    {
        Console.WriteLine("[Sidecar] Seeding item definitions...");
        foreach (var item in ItemSeed.Items)
        {
            try
            {
                _db!.Reducers.SeedItem(
                    item.Id, item.Label, item.Weight,
                    item.Stackable, item.Usable, item.MaxStack,
                    item.Category, item.PropModel,
                    item.MagCapacity, item.StoredCapacity, item.AmmoType);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[Sidecar] Seed error for {item.Id}: {ex.Message}");
            }
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

            // ── GET /instructions — Lua polls for pending native instructions ──
            if (ctx.Request.HttpMethod == "GET" && path == "/instructions")
            {
                var batch = new List<object>();
                while (_pending.TryDequeue(out var instr))
                {
                    batch.Add(new {
                        id                   = instr.Id,
                        target_entity_net_id = instr.TargetEntityNetId,
                        native_key           = instr.NativeKey,
                        payload              = instr.Payload
                    });
                }
                await WriteJson(ctx, batch);
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
                        _db.Reducers.OnPlayerConnect(
                            args.GetProperty("steam_hex").GetString()    ?? "",
                            args.GetProperty("display_name").GetString() ?? "",
                            args.GetProperty("server_id").GetUInt32(),
                            args.GetProperty("net_id").GetUInt32(),
                            args.TryGetProperty("heading", out var h) ? h.GetSingle() : 0.0f
                        );
                        break;

                    case "on_player_disconnect":
                        _db.Reducers.OnPlayerDisconnect();
                        break;

                    case "request_spawn":
                        _db.Reducers.RequestSpawn(
                            args.GetProperty("spawn_x").GetSingle(),
                            args.GetProperty("spawn_y").GetSingle(),
                            args.GetProperty("spawn_z").GetSingle(),
                            args.GetProperty("heading").GetSingle()
                        );
                        break;

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
                        
                            // ── Identity resolution stays in C# — only ActiveSession has this mapping
                            var tSession = _db!.Db.ActiveSession.Iter()
                                .FirstOrDefault(a => a.ServerId == tServerId);
                        
                            if (tSession == null)
                            {
                                await WriteJson(ctx, new { ok = false, error = "player not online" });
                                return;
                            }
                        
                            var tIdentity = tSession.Identity.ToString().ToLower();
                            if (tIdentity.StartsWith("0x")) tIdentity = tIdentity.Substring(2);
                        
                            // ── Resolve the item being transferred so we can pass it to give_item_to_identity
                            var tSlot = _db!.Db.InventorySlot.Iter().FirstOrDefault(s => s.Id == tSlotId);
                            if (tSlot == null || string.IsNullOrEmpty(tSlot.OwnerId))
                            {
                                await WriteJson(ctx, new { ok = false, error = "slot not found" });
                                return;
                            }
                        
                            try
                            {
                                // ── Remove from source first, then give to target
                                // This two-step approach lets each Rust transaction stay focused.
                                // give_item_to_identity handles: weight gate + stack merge + slot-finding
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
                                    var identityStr = session.Identity.ToString().ToLower();
                                    if (identityStr.StartsWith("0x")) identityStr = identityStr.Substring(2);
                                    ownerId = identityStr;
                                    Console.WriteLine($"[Sidecar] Looking for owner_id={identityStr}, slot count={_db!.Db.InventorySlot.Iter().Count()}");

                                    foreach (var s in _db!.Db.InventorySlot.Iter()
                                        .Where(s => s.OwnerId == identityStr && s.OwnerType == "player"))
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
                                        .Where(s => s.OwnerId.StartsWith(identityStr + "_equip_") && s.OwnerType == "equip"))
                                    {
                                        equippedSlots.Add(new {
                                            id         = s.Id,
                                            owner_id   = s.OwnerId,
                                            owner_type = s.OwnerType,
                                            item_id    = s.ItemId,
                                            quantity   = s.Quantity,
                                            metadata   = s.Metadata,
                                            slot_index = s.SlotIndex,
                                            equip_key  = s.OwnerId.Replace(identityStr + "_equip_", ""),
                                        });
                                    }
                                }

                                foreach (var d in _db.Db.ItemDefinition.Iter())
                                {
                                    defs[d.ItemId] = new {
                                        item_id   = d.ItemId,
                                        label     = d.Label,
                                        weight    = d.Weight,
                                        stackable = d.Stackable,
                                        usable    = d.Usable,
                                        max_stack = d.MaxStack,
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

                            // If backpack is equipped, include its inventory data inline
                            object? backpackData = null;
                            try
                            {
                                var bpSlot = _db!.Db.InventorySlot.Iter()
                                    .FirstOrDefault(s => s.OwnerId == ownerId + "_equip_backpack" && s.OwnerType == "equip");
                                if (bpSlot != null && !string.IsNullOrEmpty(bpSlot.OwnerId))
                                {
                                    string bpStashId     = $"backpack_slot_{bpSlot.Id}";
                                    string bpStashIdLegacy = $"backpack_{ownerId}";
                                    string bpItemId  = bpSlot.ItemId;
                                    uint   bpMaxSlots = bpItemId == "duffel_bag" ? 30u : 20u;
                                    float  bpWeight  = bpItemId == "duffel_bag" ? 50f  : 30f;
                                    string bpLabel   = bpItemId == "duffel_bag" ? "DUFFEL BAG" : "BACKPACK";
                                    try { _db!.Reducers.CreateStash(bpStashId, "backpack", bpLabel, bpMaxSlots, bpWeight, ownerId, 0f, 0f, 0f); } catch { }
                                // Check both new (slot-based) and legacy (identity-based) stash IDs
                                    var bpSlotList = _db!.Db.InventorySlot.Iter()
                                        .Where(s => (s.OwnerId == bpStashId || s.OwnerId == bpStashIdLegacy) && s.OwnerType == "stash")
                                        .Select(s => (object)new {
                                            id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType,
                                            item_id = s.ItemId, quantity = s.Quantity,
                                            metadata = s.Metadata, slot_index = s.SlotIndex,
                                        }).ToList();

                                    // Migrate legacy items to new stash ID
                                    bool hasLegacy = _db!.Db.InventorySlot.Iter()
                                        .Any(s => s.OwnerId == bpStashIdLegacy && s.OwnerType == "stash");
                                    if (hasLegacy)
                                    {
                                        Console.WriteLine($"[Sidecar] Migrating backpack items from {bpStashIdLegacy} to {bpStashId}");
                                        try { _db!.Reducers.CreateStash(bpStashId, "backpack", bpLabel, bpMaxSlots, bpWeight, ownerId, 0f, 0f, 0f); } catch { }
                                        foreach (var legacySlot in _db!.Db.InventorySlot.Iter()
                                            .Where(s => s.OwnerId == bpStashIdLegacy && s.OwnerType == "stash").ToList())
                                        {
                                            try { _db!.Reducers.TransferItem(legacySlot.Id, bpStashId, "stash", legacySlot.SlotIndex); } catch { }
                                        }
                                    }

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
                            // inventory_type = "glovebox" | "trunk"

                            var config = _db.Db.VehicleInventory.Iter()
                                .FirstOrDefault(v => v.Plate == plate);

                            bool   hasConfig = config != null; 
                            float  maxWeight = inventoryType == "trunk"
                                ? (hasConfig ? config.TrunkMaxWeight : 50f)
                                : 10f;
                            uint   maxSlots  = inventoryType == "trunk"
                                ? (hasConfig ? config.TrunkSlots : 20u)
                                : 5u;
                            string ownerType = inventoryType == "trunk" ? "vehicle_trunk" : "vehicle_glovebox";

                            var slots = _db!.Db.InventorySlot.Iter()
                                .Where(s => s.OwnerId == plate && s.OwnerType == ownerType)
                                .Select(s => new {
                                    id         = s.Id,
                                    owner_id   = s.OwnerId,
                                    owner_type = s.OwnerType,
                                    item_id    = s.ItemId,
                                    quantity   = s.Quantity,
                                    metadata   = s.Metadata,
                                    slot_index = s.SlotIndex,
                                });

                            var defs = _db.Db.ItemDefinition.Iter()
                                .ToDictionary(d => d.ItemId, d => (object)new {
                                    item_id         = d.ItemId,   label     = d.Label,
                                    weight          = d.Weight,   stackable = d.Stackable,
                                    usable          = d.Usable,   max_stack = d.MaxStack,
                                    category        = d.Category, prop_model = d.PropModel,
                                    mag_capacity    = d.MagCapacity,
                                    stored_capacity = d.StoredCapacity,
                                    ammo_type       = d.AmmoType,
                                });

                            await WriteJson(ctx, new {
                                plate,
                                inventory_type = inventoryType,
                                trunk_type     = hasConfig ? config.TrunkType : "none",
                                slots,
                                item_defs      = defs,
                                max_weight     = maxWeight,
                                max_slots      = maxSlots,
                            });
                            return;
                        }

                    case "get_inventory_slots":
                        {
                            string gsOwnerType = args.GetProperty("owner_type").GetString() ?? "";
                            string gsOwnerId   = args.GetProperty("owner_id").GetString() ?? "";
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

                    case "open_backpack":
                        {
                            string bpIdentity = args.GetProperty("owner_identity").GetString() ?? "";
                            string bagItemId  = args.GetProperty("bag_item_id").GetString() ?? "backpack";
                            ulong  bagSlotId  = args.TryGetProperty("bag_slot_id", out var bsid) ? bsid.GetUInt64() : 0;
                            // Use slot ID as stable stash key — survives ownership transfers
                            string bpStashId  = bagSlotId > 0 ? $"backpack_slot_{bagSlotId}" : $"backpack_{bpIdentity}";

                            uint   bpSlots  = bagItemId == "duffel_bag" ? 30u : 20u;
                            float  bpWeight = bagItemId == "duffel_bag" ? 50f  : 30f;
                            string bpLabel  = bagItemId == "duffel_bag" ? "DUFFEL BAG" : "BACKPACK";

                            try
                            {
                                _db!.Reducers.CreateStash(
                                    bpStashId, "backpack", bpLabel,
                                    bpSlots, bpWeight, bpIdentity, 0f, 0f, 0f);
                            }
                            catch { /* already exists */ }

                            string bpStashIdLegacyOb = $"backpack_{bpIdentity}";
                            // Migrate legacy items if needed
                            bool hasLegacyOb = _db!.Db.InventorySlot.Iter()
                                .Any(s => s.OwnerId == bpStashIdLegacyOb && s.OwnerType == "stash");
                            if (hasLegacyOb)
                            {
                                Console.WriteLine($"[Sidecar] open_backpack: migrating {bpStashIdLegacyOb} -> {bpStashId}");
                                try { _db!.Reducers.CreateStash(bpStashId, "backpack", bpLabel, bpSlots, bpWeight, bpIdentity, 0f, 0f, 0f); } catch { }
                                foreach (var ls in _db!.Db.InventorySlot.Iter()
                                    .Where(s => s.OwnerId == bpStashIdLegacyOb && s.OwnerType == "stash").ToList())
                                {
                                    try { _db!.Reducers.TransferItem(ls.Id, bpStashId, "stash", ls.SlotIndex); } catch { }
                                }
                            }
                            var bpSlotList = _db!.Db.InventorySlot.Iter()
                                .Where(s => (s.OwnerId == bpStashId || s.OwnerId == bpStashIdLegacyOb) && s.OwnerType == "stash")
                                .Select(s => (object)new {
                                    id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType,
                                    item_id = s.ItemId, quantity = s.Quantity,
                                    metadata = s.Metadata, slot_index = s.SlotIndex,
                                }).ToList();

                            var bpDefs = _db!.Db.ItemDefinition.Iter()
                                .ToDictionary(d => d.ItemId, d => (object)new {
                                    item_id = d.ItemId, label = d.Label, weight = d.Weight,
                                    stackable = d.Stackable, usable = d.Usable,
                                    max_stack = d.MaxStack, category = d.Category,
                                });

                            await WriteJson(ctx, new {
                                stash_id   = bpStashId,
                                label      = bpLabel,
                                max_weight = bpWeight,
                                max_slots  = (int)bpSlots,
                                slots      = bpSlotList,
                                item_defs  = bpDefs,
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
                        
                            // ── Snapshot the slot before the reducer consumes it
                            var preDrop = _db!.Db.InventorySlot.Iter().FirstOrDefault(s => s.Id == dropSlotId);
                            if (preDrop == null || string.IsNullOrEmpty(preDrop.OwnerId))
                            {
                                await WriteJson(ctx, new { ok = false, error = "slot not found" });
                                return;
                            }
                        
                            try
                            {
                                // ── Rust does: spatial search → stash create → slot-find → transfer/split
                                _db!.Reducers.DropItemToGround(dropSlotId, dropQty, dx, dy, dz);
                            }
                            catch (Exception ex)
                            {
                                Console.WriteLine($"[Sidecar] drop_item_to_ground error: {ex.Message}");
                                await WriteJson(ctx, new { ok = false, error = ex.Message });
                                return;
                            }
                        
                            // ── Brief yield — lets SpacetimeDB commit before we query the result
                            // The frame tick (50ms) handles subscription updates; this 80ms gap
                            // ensures our read sees the committed state.
                            await Task.Delay(80);
                        
                            // ── Query: find the ground stash Rust resolved/created near (dx, dy)
                            float searchRadiusSq = 25f; // 5m radius
                            var resolvedStash = _db!.Db.StashDefinition.Iter()
                                .Where(s => s.StashType == "ground")
                                .Where(s => {
                                    float ex2 = s.PosX - dx, ey = s.PosY - dy;
                                    return ex2*ex2 + ey*ey <= searchRadiusSq;
                                })
                                .OrderBy(s => {
                                    float ex2 = s.PosX - dx, ey = s.PosY - dy;
                                    return ex2*ex2 + ey*ey;
                                })
                                .FirstOrDefault();
                        
                            if (resolvedStash == null || string.IsNullOrEmpty(resolvedStash.StashId))
                            {
                                await WriteJson(ctx, new { ok = false, error = "ground stash not found after drop" });
                                return;
                            }
                        
                            // ── Find the new slot in the stash (the item Rust just moved/created)
                            var newSlot = _db!.Db.InventorySlot.Iter()
                                .Where(s => s.OwnerId == resolvedStash.StashId && s.OwnerType == "stash"
                                        && s.ItemId  == preDrop.ItemId)
                                .FirstOrDefault();
                        
                            await WriteJson(ctx, new {
                                ok          = true,
                                stash_id    = resolvedStash.StashId,
                                new_slot_id = newSlot?.Id ?? 0UL,
                            });
                            return;
                        }

                    case "split_stack":
                        {
                            ulong splitId  = args.GetProperty("slot_id").GetUInt64();
                            uint  splitAmt = args.GetProperty("amount").GetUInt32();
                            _db!.Reducers.SplitStack(splitId, splitAmt);
                            await WriteJson(ctx, new { ok = true });
                            return;
                        }

                    case "get_stash_pos":
                        {
                            string spStashId = args.GetProperty("stash_id").GetString() ?? "";
                            var spDef = _db!.Db.StashDefinition.Iter()
                                .FirstOrDefault(s => s.StashId == spStashId);
                            if (spDef != null)
                            {
                                await WriteJson(ctx, new {
                                    pos_x = spDef.PosX,
                                    pos_y = spDef.PosY,
                                    pos_z = spDef.PosZ,
                                });
                            }
                            else
                            {
                                await WriteJson(ctx, new { pos_x = 0f, pos_y = 0f, pos_z = 0f });
                            }
                            return;
                        }

                    case "find_or_create_ground_stash":
                        {
                            float gx = (float)args.GetProperty("x").GetDouble();
                            float gy = (float)args.GetProperty("y").GetDouble();
                            float gz = (float)args.GetProperty("z").GetDouble();
                        
                            // ── Rust does: spatial search → create if missing (all in one transaction)
                            try
                            {
                                _db!.Reducers.FindOrCreateGroundStash(gx, gy, gz);
                            }
                            catch (Exception ex)
                            {
                                Console.WriteLine($"[Sidecar] find_or_create_ground_stash error: {ex.Message}");
                                await WriteJson(ctx, new { ok = false, error = ex.Message });
                                return;
                            }
                        
                            // ── Brief yield — SpacetimeDB needs one frame tick to commit
                            await Task.Delay(80);
                        
                            // ── Query: find the stash Rust resolved/created
                            float gsRadiusSq = 25f;
                            var gsStash = _db!.Db.StashDefinition.Iter()
                                .Where(s => s.StashType == "ground")
                                .Where(s => {
                                    float ex2 = s.PosX - gx, ey = s.PosY - gy;
                                    return ex2*ex2 + ey*ey <= gsRadiusSq;
                                })
                                .OrderBy(s => {
                                    float ex2 = s.PosX - gx, ey = s.PosY - gy;
                                    return ex2*ex2 + ey*ey;
                                })
                                .FirstOrDefault();
                        
                            string gsStashId = gsStash?.StashId ?? "";
                            Console.WriteLine($"[Sidecar] Ground stash resolved: {gsStashId} at ({gx:F1},{gy:F1})");
                        
                            // ── Assemble the stash payload: contents + item definitions
                            var gsSlots = _db!.Db.InventorySlot.Iter()
                                .Where(s => s.OwnerId == gsStashId && s.OwnerType == "stash")
                                .Select(s => (object)new {
                                    id         = s.Id,
                                    owner_id   = s.OwnerId,
                                    owner_type = s.OwnerType,
                                    item_id    = s.ItemId,
                                    quantity   = s.Quantity,
                                    metadata   = s.Metadata,
                                    slot_index = s.SlotIndex,
                                }).ToList();
                        
                            var gsDefs = _db!.Db.ItemDefinition.Iter()
                                .ToDictionary(d => d.ItemId, d => (object)new {
                                    item_id    = d.ItemId,   label      = d.Label,
                                    weight     = d.Weight,   stackable  = d.Stackable,
                                    usable     = d.Usable,   max_stack  = d.MaxStack,
                                    category   = d.Category, prop_model = d.PropModel,
                                });
                        
                            await WriteJson(ctx, new {
                                stash_id   = gsStashId,
                                label      = "GROUND",
                                max_weight = 999f,
                                max_slots  = 50,
                                slots      = gsSlots,
                                item_defs  = gsDefs,
                            });
                            return;
                        }

                    case "get_stash_inventory":
                        {
                            string stashId = args.GetProperty("stash_id").GetString() ?? "";

                            var def = _db.Db.StashDefinition.Iter()
                                .FirstOrDefault(s => s.StashId == stashId);

                            bool hasConfig = def != null;

                            var slots = _db!.Db.InventorySlot.Iter()
                                .Where(s => s.OwnerId == stashId && s.OwnerType == "stash")
                                .Select(s => new {
                                    id         = s.Id,
                                    owner_id   = s.OwnerId,
                                    owner_type = s.OwnerType,
                                    item_id    = s.ItemId,
                                    quantity   = s.Quantity,
                                    metadata   = s.Metadata,
                                    slot_index = s.SlotIndex,
                                });

                            var defs = _db.Db.ItemDefinition.Iter()
                                .ToDictionary(d => d.ItemId, d => (object)new {
                                    item_id = d.ItemId, label = d.Label, weight = d.Weight,
                                    stackable = d.Stackable, usable = d.Usable, max_stack = d.MaxStack,
                                });

                            await WriteJson(ctx, new {
                                stash_id   = stashId,
                                label      = hasConfig ? def.Label     : stashId,
                                max_weight = hasConfig ? def.MaxWeight : 100f,
                                max_slots  = hasConfig ? def.MaxSlots  : 20u,
                                slots,
                                item_defs  = defs,
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
                        
                            var gIdentity = gSession.Identity.ToString().ToLower();
                            if (gIdentity.StartsWith("0x")) gIdentity = gIdentity.Substring(2);
                        
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
        await ctx.Response.OutputStream.WriteAsync(bytes);
        ctx.Response.Close();
    }

    static async Task SeedItemsWhenReady()
    {
        await _syncGate.WaitAsync();
        Console.WriteLine("[Sidecar] Seeding item definitions...");
        
        // Assuming your existing SeedItems() call
        SeedItems(); 
    }
}