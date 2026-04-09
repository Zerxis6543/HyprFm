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
    static readonly ConcurrentQueue<InstructionQueue> _pending   = new();
    static readonly ConcurrentQueue<object>           _deltaQueue = new();
    static readonly SemaphoreSlim                     _syncGate  = new(0, 1);

    static readonly ConcurrentDictionary<uint, string> _steamHexByServerId = new();

    // ── Diagnostics ───────────────────────────────────────────────────────────
    static long     _deltaFireCount  = 0;
    static DateTime _lastDeltaTime   = DateTime.MinValue;

    // ─────────────────────────────────────────────────────────────────────────
    // ENTRY POINT
    // ─────────────────────────────────────────────────────────────────────────

    static async Task Main(string[] args)
    {
        string stdbUri = Environment.GetEnvironmentVariable("STDB_URI")  ?? "ws://127.0.0.1:3000";
        string stdbDb  = Environment.GetEnvironmentVariable("STDB_DB")   ?? "fivem-game";
        string token   = Environment.GetEnvironmentVariable("STDB_TOKEN") ?? "";

        Console.WriteLine($"[Sidecar] SpacetimeDB : {stdbUri}/{stdbDb}");
        Console.WriteLine($"[Sidecar] HTTP port   : {_sidecarPort}");

        _ = Task.Run(StartHttpListener);
        _ = Task.Run(SeedItemsWhenReady);

        await Connect(stdbUri, stdbDb, token);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CONNECTION + FRAME LOOP
    // ─────────────────────────────────────────────────────────────────────────

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
                    .OnConnectError(ex => Console.WriteLine($"[Sidecar] Connect error: {ex.Message}"))
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

    // ─────────────────────────────────────────────────────────────────────────
    // SUBSCRIPTION CALLBACKS
    // ─────────────────────────────────────────────────────────────────────────

    static void OnSubscriptionReady(SubscriptionEventContext ctx)
    {
        Console.WriteLine("[Sidecar] Subscription active.");

        _db!.Db.InstructionQueue.OnInsert += OnInstructionInserted;

        // ── SlotShape: serialize as snake_case for the TypeScript NUI ─────────
        // The SDK generates PascalCase (OwnerId, OwnerType…). JsonSerializer
        // preserves those names. The NUI reads snake_case (owner_id, owner_type…).
        // Passing the raw SDK object produces JSON the NUI silently cannot use.
        static object SlotShape(InventorySlot s) => new
        {
            id         = s.Id,
            owner_id   = s.OwnerId,
            owner_type = s.OwnerType,
            item_id    = s.ItemId,
            quantity   = s.Quantity,
            metadata   = s.Metadata,
            slot_index = s.SlotIndex,
        };

        _db!.Db.InventorySlot.OnInsert += (evCtx, slot) =>
        {
            Interlocked.Increment(ref _deltaFireCount);
            _lastDeltaTime = DateTime.UtcNow;
            Console.WriteLine($"[Delta] ADDED  id={slot.Id} owner_id={slot.OwnerId} owner_type={slot.OwnerType} item={slot.ItemId}");
            _deltaQueue.Enqueue(new { type = "added", slot = SlotShape(slot), owner_id = slot.OwnerId });
        };

        _db!.Db.InventorySlot.OnUpdate += (evCtx, oldSlot, newSlot) =>
        {
            Interlocked.Increment(ref _deltaFireCount);
            _lastDeltaTime = DateTime.UtcNow;
            if (oldSlot.OwnerId != newSlot.OwnerId)
            {
                Console.WriteLine($"[Delta] OWNER CHANGE id={oldSlot.Id} {oldSlot.OwnerId}→{newSlot.OwnerId}");
                // Emit a deletion for the OLD owner so the source panel removes the slot
                _deltaQueue.Enqueue(new { type = "deleted", slot_id = oldSlot.Id, owner_id = oldSlot.OwnerId });
            }
            Console.WriteLine($"[Delta] UPDATED id={newSlot.Id} owner_id={newSlot.OwnerId} owner_type={newSlot.OwnerType}");
            _deltaQueue.Enqueue(new { type = "updated", slot = SlotShape(newSlot), owner_id = newSlot.OwnerId });
        };

        _db!.Db.InventorySlot.OnDelete += (evCtx, slot) =>
        {
            Interlocked.Increment(ref _deltaFireCount);
            _lastDeltaTime = DateTime.UtcNow;
            Console.WriteLine($"[Delta] DELETED id={slot.Id} owner_id={slot.OwnerId}");
            _deltaQueue.Enqueue(new { type = "deleted", slot_id = slot.Id, owner_id = slot.OwnerId });
        };

        // ── Report local cache state immediately after subscription hydrates ──
        // If slot_count == 0 here but SpacetimeDB has rows, the SELECT subscription
        // is not returning data — either a schema mismatch or SDK version issue.
        var slotCount   = _db!.Db.InventorySlot.Iter().Count();
        var playerCount = _db!.Db.Player.Iter().Count();
        var defCount    = _db!.Db.ItemDefinition.Iter().Count();
        Console.WriteLine($"[Sidecar] Subscription hydrated: players={playerCount} item_defs={defCount} inventory_slots={slotCount}");
        if (slotCount == 0 && playerCount > 0)
        {
            Console.WriteLine("[Sidecar] WARNING: players exist but inventory_slots=0. " +
                              "Check that the SpacetimeDB C# SDK version matches the server (spacetimedb = 2.0). " +
                              "Run: SELECT COUNT(*) FROM inventory_slot in the SpacetimeDB CLI to verify rows exist.");
        }

        _syncGate.Release();
    }

    static void OnInstructionInserted(EventContext ctx, InstructionQueue row)
    {
        if (row.Consumed) return;
        Console.WriteLine($"[Sidecar] Instruction #{row.Id}: opcode=0x{row.Opcode:X4}");
        _pending.Enqueue(row);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEEDING
    // ─────────────────────────────────────────────────────────────────────────

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

    static async Task SeedItemsWhenReady()
    {
        await _syncGate.WaitAsync();
        SeedItems();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HTTP LISTENER
    // ─────────────────────────────────────────────────────────────────────────

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

    // ─────────────────────────────────────────────────────────────────────────
    // REQUEST HANDLER
    // ─────────────────────────────────────────────────────────────────────────

    static async Task HandleRequest(HttpListenerContext ctx)
    {
        try
        {
            string path = ctx.Request.Url?.AbsolutePath ?? "";

            // ── GET /version ─────────────────────────────────────────────────
            if (ctx.Request.HttpMethod == "GET" && path == "/version")
            {
                await WriteJson(ctx, new { version = API_VERSION, status = "ok" });
                return;
            }

            // ── GET /diagnostics ─────────────────────────────────────────────
            if (ctx.Request.HttpMethod == "GET" && path == "/diagnostics")
            {
                int slotCount = _db == null ? -1 : _db.Db.InventorySlot.Iter().Count();
                await WriteJson(ctx, new
                {
                    db_connected        = _db != null,
                    delta_fire_count    = Interlocked.Read(ref _deltaFireCount),
                    delta_queue_pending = _deltaQueue.Count,
                    last_delta_utc      = _lastDeltaTime == DateTime.MinValue ? "never" : _lastDeltaTime.ToString("o"),
                    inventory_slot_count = slotCount,
                });
                return;
            }

            // ── GET /instructions ─────────────────────────────────────────────
            if (ctx.Request.HttpMethod == "GET" && path == "/instructions")
            {
                var batch = new List<object>();
                while (_pending.TryDequeue(out var instr))
                {
                    batch.Add(new
                    {
                        id                   = instr.Id,
                        target_entity_net_id = instr.TargetEntityNetId,
                        opcode               = instr.Opcode,
                        payload              = instr.Payload,
                    });
                }
                await WriteJson(ctx, batch);
                return;
            }

            // ── POST /seed-item ───────────────────────────────────────────────
            if (ctx.Request.HttpMethod == "POST" && path == "/seed-item")
            {
                using var sr = new System.IO.StreamReader(ctx.Request.InputStream);
                string body = await sr.ReadToEndAsync();
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
                        r.TryGetProperty("mag_capacity",    out var mc) ? mc.GetInt32()   : 0,
                        r.TryGetProperty("stored_capacity", out var sc) ? sc.GetInt32()   : 0,
                        r.TryGetProperty("ammo_type",       out var at) ? at.GetString()  ?? "" : "");
                    ctx.Response.StatusCode = 200;
                    ctx.Response.Close();
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"[Sidecar] /seed-item error: {ex.Message}");
                    ctx.Response.StatusCode = 400;
                    ctx.Response.Close();
                }
                return;
            }

            // ── GET /slot-deltas ──────────────────────────────────────────────
            if (ctx.Request.HttpMethod == "GET" && path == "/slot-deltas")
            {
                var deltas = new List<object>();
                while (_deltaQueue.TryDequeue(out var delta))
                    deltas.Add(delta);

                if (deltas.Count > 0)
                    Console.WriteLine($"[Delta] Sending {deltas.Count} delta(s): {JsonSerializer.Serialize(deltas)}");

                await WriteJson(ctx, deltas);
                return;
            }

            // ── GET /item-count ───────────────────────────────────────────────
            if (ctx.Request.HttpMethod == "GET" && path == "/item-count")
            {
                var qs    = System.Web.HttpUtility.ParseQueryString(ctx.Request.Url?.Query ?? "");
                string oi = qs["owner_id"] ?? "";
                string ii = qs["item_id"]  ?? "";
                if (string.IsNullOrEmpty(oi) || string.IsNullOrEmpty(ii))
                {
                    ctx.Response.StatusCode = 400; ctx.Response.Close(); return;
                }
                uint count = _db == null ? 0 : (uint)_db.Db.InventorySlot.Iter()
                    .Where(s => s.OwnerId == oi && s.ItemId == ii)
                    .Sum(s => (long)s.Quantity);
                await WriteJson(ctx, new { owner_id = oi, item_id = ii, count, has_item = count > 0 });
                return;
            }

            // ── POST /consumed ────────────────────────────────────────────────
            if (ctx.Request.HttpMethod == "POST" && path == "/consumed")
            {
                using var sr = new System.IO.StreamReader(ctx.Request.InputStream);
                string body = await sr.ReadToEndAsync();
                using var doc = JsonDocument.Parse(body);
                foreach (var item in doc.RootElement.EnumerateArray())
                    _db?.Reducers.MarkInstructionConsumed(item.GetUInt64());
                ctx.Response.StatusCode = 200;
                ctx.Response.Close();
                return;
            }

            // ── POST /reducer ─────────────────────────────────────────────────
            if (ctx.Request.HttpMethod == "POST" && path == "/reducer")
            {
                using var sr = new System.IO.StreamReader(ctx.Request.InputStream);
                string body = await sr.ReadToEndAsync();
                using var doc = JsonDocument.Parse(body);
                string name = doc.RootElement.GetProperty("name").GetString() ?? "";
                var    args = doc.RootElement.GetProperty("args");

                Console.WriteLine($"[Sidecar] Reducer: {name}");

                if (_db == null) { ctx.Response.StatusCode = 503; ctx.Response.Close(); return; }

                switch (name)
                {
                    // ── Player ────────────────────────────────────────────────

                    case "on_player_connect":
                    {
                        var serverId    = args.GetProperty("server_id").GetUInt32();
                        var steamHex    = args.GetProperty("steam_hex").GetString() ?? "";
                        _db.Reducers.OnPlayerConnect(
                            steamHex,
                            args.GetProperty("display_name").GetString() ?? "",
                            serverId,
                            args.GetProperty("net_id").GetUInt32(),
                            args.TryGetProperty("heading", out var h) ? h.GetSingle() : 0f);
                        if (!string.IsNullOrEmpty(steamHex))
                            _steamHexByServerId[serverId] = steamHex;
                        break;
                    }

                    case "on_player_disconnect":
                    {
                        uint sid = args.TryGetProperty("server_id", out var se) ? se.GetUInt32() : 0;
                        if (sid > 0 && _steamHexByServerId.TryRemove(sid, out var hex))
                            _db.Reducers.OnPlayerDisconnect(hex);
                        break;
                    }

                    case "request_spawn":
                    {
                        uint sid = args.GetProperty("server_id").GetUInt32();
                        if (!_steamHexByServerId.TryGetValue(sid, out var hex))
                        {
                            Console.WriteLine($"[Sidecar] request_spawn: no steam_hex for server_id={sid}");
                            ctx.Response.StatusCode = 400; ctx.Response.Close(); return;
                        }
                        _db.Reducers.RequestSpawn(hex,
                            args.GetProperty("spawn_x").GetSingle(),
                            args.GetProperty("spawn_y").GetSingle(),
                            args.GetProperty("spawn_z").GetSingle(),
                            args.GetProperty("heading").GetSingle());
                        break;
                    }

                    // ── Inventory ─────────────────────────────────────────────

                    case "move_item":
                        _db.Reducers.MoveItem(
                            args.GetProperty("slot_id").GetUInt64(),
                            args.GetProperty("new_slot_index").GetUInt32());
                        break;

                    case "transfer_item":
                        _db.Reducers.TransferItem(
                            args.GetProperty("slot_id").GetUInt64(),
                            args.GetProperty("new_owner_id").GetString()   ?? "",
                            args.GetProperty("new_owner_type").GetString() ?? "player",
                            args.GetProperty("new_slot_index").GetUInt32());
                        break;

                    case "transfer_item_to_player":
                    {
                        ulong tSlotId   = args.GetProperty("slot_id").GetUInt64();
                        uint  tServerId = args.GetProperty("server_id").GetUInt32();
                        var   tSession  = _db.Db.ActiveSession.Iter().FirstOrDefault(a => a.ServerId == tServerId);
                        if (tSession == null) { await WriteJson(ctx, new { ok = false, error = "player not online" }); return; }
                        var tSlot = _db.Db.InventorySlot.Iter().FirstOrDefault(s => s.Id == tSlotId);
                        if (tSlot == null) { await WriteJson(ctx, new { ok = false, error = "slot not found" }); return; }
                        try
                        {
                            _db.Reducers.RemoveItem(tSlot.OwnerId, tSlot.ItemId, tSlot.Quantity);
                            _db.Reducers.GiveItemToIdentity(tSession.SteamHex, tSlot.ItemId, tSlot.Quantity, tSlot.Metadata);
                            await WriteJson(ctx, new { ok = true, owner_id = tSession.SteamHex });
                        }
                        catch (Exception ex) when (ex.Message.Contains("WEIGHT_LIMIT"))
                        {
                            var p = ex.Message.Split('|');
                            await WriteJson(ctx, new { ok = false, error_code = "WEIGHT_LIMIT", actual_kg = p.Length > 1 ? p[1] : "?", max_kg = p.Length > 2 ? p[2] : "?" });
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
                            args.GetProperty("net_id").GetUInt32());
                        break;

                    case "add_item":
                    {
                        string aiOwner = args.GetProperty("owner_id").GetString()   ?? "";
                        string aiType  = args.GetProperty("owner_type").GetString() ?? "player";
                        string aiItem  = args.GetProperty("item_id").GetString()    ?? "";
                        uint   aiQty   = args.GetProperty("quantity").GetUInt32();
                        string aiMeta  = args.TryGetProperty("metadata", out var am) ? am.GetString() ?? "{}" : "{}";
                        if (aiMeta == "{}" || string.IsNullOrEmpty(aiMeta))
                        {
                            var def = _db.Db.ItemDefinition.Iter().FirstOrDefault(d => d.ItemId == aiItem);
                            if (def != null && def.Category == "weapon")
                            {
                                var serial = $"WPN-{Guid.NewGuid().ToString("N")[..8].ToUpper()}";
                                aiMeta = JsonSerializer.Serialize(new
                                {
                                    serial, mag_ammo = 0, stored_ammo = 0,
                                    mag_capacity    = def.MagCapacity,
                                    stored_capacity = def.StoredCapacity,
                                    durability      = 100,
                                    ammo_type       = def.AmmoType,
                                });
                            }
                        }
                        _db.Reducers.AddItem(aiOwner, aiType, aiItem, aiQty, aiMeta);
                        await WriteJson(ctx, new { ok = true });
                        return;
                    }

                    case "remove_item":
                        _db.Reducers.RemoveItem(
                            args.GetProperty("owner_id").GetString() ?? "",
                            args.GetProperty("item_id").GetString()  ?? "",
                            args.GetProperty("quantity").GetUInt32());
                        break;

                    case "merge_stacks":
                        _db.Reducers.MergeStacks(
                            args.GetProperty("src_slot_id").GetUInt64(),
                            args.GetProperty("dst_slot_id").GetUInt64());
                        await WriteJson(ctx, new { ok = true });
                        return;

                    case "split_stack":
                        _db.Reducers.SplitStack(
                            args.GetProperty("slot_id").GetUInt64(),
                            args.GetProperty("amount").GetUInt32());
                        await WriteJson(ctx, new { ok = true });
                        return;

                    case "move_item_partial":
                    {
                        ulong  mpId    = args.GetProperty("slot_id").GetUInt64();
                        uint   mpQty   = args.GetProperty("quantity").GetUInt32();
                        string mpOwner = args.TryGetProperty("new_owner_id",   out var mpOI) ? mpOI.GetString() ?? "" : "";
                        string mpType  = args.TryGetProperty("new_owner_type", out var mpOT) ? mpOT.GetString() ?? "" : "";
                        uint   mpIdx   = args.TryGetProperty("new_slot_index", out var mpSI) ? mpSI.GetUInt32() : 0u;
                        var mpSrc = _db.Db.InventorySlot.Iter().FirstOrDefault(s => s.Id == mpId);
                        if (mpSrc == null) { await WriteJson(ctx, new { ok = false, error = "slot not found" }); return; }
                        if (mpQty >= mpSrc.Quantity)
                        {
                            if (string.IsNullOrEmpty(mpOwner) || mpType == "player") _db.Reducers.MoveItem(mpId, mpIdx);
                            else _db.Reducers.TransferItem(mpId, mpOwner, mpType, mpIdx);
                        }
                        else
                        {
                            _db.Reducers.SplitStack(mpId, mpQty);
                            await Task.Delay(200);
                            var split = _db.Db.InventorySlot.Iter()
                                .Where(s => s.OwnerId == mpSrc.OwnerId && s.OwnerType == mpSrc.OwnerType
                                         && s.ItemId == mpSrc.ItemId   && s.Quantity == mpQty && s.Id != mpId)
                                .OrderByDescending(s => s.Id).FirstOrDefault();
                            if (split != null)
                            {
                                if (string.IsNullOrEmpty(mpOwner) || mpType == "player") _db.Reducers.MoveItem(split.Id, mpIdx);
                                else _db.Reducers.TransferItem(split.Id, mpOwner, mpType, mpIdx);
                            }
                        }
                        await WriteJson(ctx, new { ok = true });
                        return;
                    }

                    // ── Vehicle inventory ─────────────────────────────────────

                    case "create_vehicle_inventory":
                        _db.Reducers.CreateVehicleInventory(
                            args.GetProperty("plate").GetString()          ?? "",
                            (uint)args.GetProperty("model_hash").GetInt32(),
                            args.GetProperty("trunk_type").GetString()     ?? "rear",
                            args.GetProperty("trunk_slots").GetUInt32(),
                            (float)args.GetProperty("trunk_max_weight").GetDouble());
                        break;

                    // ── Stashes ───────────────────────────────────────────────

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
                            (float)args.GetProperty("pos_z").GetDouble());
                        break;

                    case "delete_stash":
                        _db.Reducers.DeleteStash(args.GetProperty("stash_id").GetString() ?? "");
                        break;

                    // ── Backpack ──────────────────────────────────────────────

                    case "open_backpack":
                    {
                        string bpOwner  = args.GetProperty("owner_identity").GetString() ?? "";
                        string bpItem   = args.GetProperty("bag_item_id").GetString()    ?? "backpack";
                        ulong  bpSlotId = args.TryGetProperty("bag_slot_id", out var bs) ? bs.GetUInt64() : 0;
                        string bpStash  = bpSlotId > 0 ? $"backpack_slot_{bpSlotId}" : $"backpack_{bpOwner}";
                        uint   bpSlots  = bpItem == "duffel_bag" ? 30u : 20u;
                        float  bpWt     = bpItem == "duffel_bag" ? 50f : 30f;
                        string bpLbl    = bpItem == "duffel_bag" ? "DUFFEL BAG" : "BACKPACK";
                        try { _db.Reducers.CreateStash(bpStash, "backpack", bpLbl, bpSlots, bpWt, bpOwner, 0f, 0f, 0f); } catch { }
                        var bpLegacy  = $"backpack_{bpOwner}";
                        var bpSlotList = _db.Db.InventorySlot.Iter()
                            .Where(s => (s.OwnerId == bpStash || s.OwnerId == bpLegacy) && s.OwnerType == "stash")
                            .Select(s => (object)new { id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType, item_id = s.ItemId, quantity = s.Quantity, metadata = s.Metadata, slot_index = s.SlotIndex })
                            .ToList();
                        var bpDefs = _db.Db.ItemDefinition.Iter()
                            .ToDictionary(d => d.ItemId, d => (object)new { item_id = d.ItemId, label = d.Label, weight = d.Weight, stackable = d.Stackable, usable = d.Usable, max_stack = d.MaxStack, category = d.Category });
                        await WriteJson(ctx, new { stash_id = bpStash, label = bpLbl, max_weight = bpWt, max_slots = (int)bpSlots, slots = bpSlotList, item_defs = bpDefs });
                        return;
                    }

                    // ── Drop/throw to ground ──────────────────────────────────
                    //
                    // After calling DropItemToGround we wait 200ms for SpacetimeDB's
                    // subscription update to propagate into the local SDK cache before
                    // reading back the stash. This replaces the previous 80ms guess.

                    case "drop_item_to_ground":
                    {
                        ulong dropId  = args.GetProperty("slot_id").GetUInt64();
                        uint  dropQty = args.TryGetProperty("quantity", out var dq) ? dq.GetUInt32() : 0;
                        float dx = (float)args.GetProperty("x").GetDouble();
                        float dy = (float)args.GetProperty("y").GetDouble();
                        float dz = (float)args.GetProperty("z").GetDouble();

                        var preDrop = _db.Db.InventorySlot.Iter().FirstOrDefault(s => s.Id == dropId);
                        if (preDrop == null)
                        {
                            await WriteJson(ctx, new { ok = false, error = "slot not found" });
                            return;
                        }

                        try { _db.Reducers.DropItemToGround(dropId, dropQty, dx, dy, dz); }
                        catch (Exception ex) { await WriteJson(ctx, new { ok = false, error = ex.Message }); return; }

                        // Wait for the local subscription cache to reflect the commit
                        await Task.Delay(200);

                        float rSq = 25f;
                        var stash = _db.Db.StashDefinition.Iter()
                            .Where(s => s.StashType == "ground")
                            .Where(s => { float ex2 = s.PosX - dx, ey = s.PosY - dy; return ex2*ex2 + ey*ey <= rSq; })
                            .OrderBy(s => { float ex2 = s.PosX - dx, ey = s.PosY - dy; return ex2*ex2 + ey*ey; })
                            .FirstOrDefault();

                        if (stash == null)
                        {
                            Console.WriteLine($"[Sidecar] drop_item_to_ground: no ground stash found near ({dx},{dy})");
                            await WriteJson(ctx, new { ok = false, error = "ground stash not found after drop" });
                            return;
                        }

                        var newSlot = _db.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == stash.StashId && s.OwnerType == "stash" && s.ItemId == preDrop.ItemId)
                            .FirstOrDefault();

                        Console.WriteLine($"[Sidecar] drop_item_to_ground: stash={stash.StashId} new_slot_id={newSlot?.Id}");
                        await WriteJson(ctx, new { ok = true, stash_id = stash.StashId, new_slot_id = newSlot?.Id ?? 0UL });
                        return;
                    }

                    case "find_or_create_ground_stash":
                    {
                        float gx = (float)args.GetProperty("x").GetDouble();
                        float gy = (float)args.GetProperty("y").GetDouble();
                        float gz = (float)args.GetProperty("z").GetDouble();
                        try { _db.Reducers.FindOrCreateGroundStash(gx, gy, gz); }
                        catch (Exception ex) { await WriteJson(ctx, new { ok = false, error = ex.Message }); return; }

                        await Task.Delay(200);

                        float gsRSq = 25f;
                        var gsStash = _db.Db.StashDefinition.Iter()
                            .Where(s => s.StashType == "ground")
                            .Where(s => { float ex2 = s.PosX - gx, ey = s.PosY - gy; return ex2*ex2 + ey*ey <= gsRSq; })
                            .OrderBy(s => { float ex2 = s.PosX - gx, ey = s.PosY - gy; return ex2*ex2 + ey*ey; })
                            .FirstOrDefault();

                        string gsId    = gsStash?.StashId ?? "";
                        var    gsSlots = _db.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == gsId && s.OwnerType == "stash")
                            .Select(s => (object)new { id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType, item_id = s.ItemId, quantity = s.Quantity, metadata = s.Metadata, slot_index = s.SlotIndex })
                            .ToList();
                        var gsDefs = _db.Db.ItemDefinition.Iter()
                            .ToDictionary(d => d.ItemId, d => (object)new { item_id = d.ItemId, label = d.Label, weight = d.Weight, stackable = d.Stackable, usable = d.Usable, max_stack = d.MaxStack, category = d.Category, prop_model = d.PropModel });

                        await WriteJson(ctx, new { stash_id = gsId, label = "GROUND", max_weight = 999f, max_slots = 50, slots = gsSlots, item_defs = gsDefs });
                        return;
                    }

                    // ── Data queries ──────────────────────────────────────────

                    case "get_player_inventory":
                    {
                        uint   serverId      = args.GetProperty("server_id").GetUInt32();
                        var    slots         = new List<object>();
                        var    equippedSlots = new List<object>();
                        var    defs          = new Dictionary<string, object>();
                        string ownerId       = "";
                        object? backpackData = null;

                        try
                        {
                            // ── Diagnostic: show all active sessions in cache ──────
                            var allSessions = _db.Db.ActiveSession.Iter().ToList();
                            Console.WriteLine($"[Inv] get_player_inventory: server_id={serverId} active_sessions_in_cache={allSessions.Count}");
                            foreach (var sess in allSessions)
                                Console.WriteLine($"[Inv]   session: server_id={sess.ServerId} steam_hex={sess.SteamHex}");

                            // ── Identity resolution — three levels ────────────────
                            // Level 1: _steamHexByServerId (in-memory, populated by the
                            //          real stdb:playerConnected event — always correct).
                            // Level 2: ActiveSession subscription cache (may have steam_hex=""
                            //          if on_player_connect was called before identifiers loaded).
                            // We NEVER use an empty steam_hex — that would return zero slots.
                            if (_steamHexByServerId.TryGetValue(serverId, out var mappedHex) && !string.IsNullOrEmpty(mappedHex))
                            {
                                ownerId = mappedHex;
                                Console.WriteLine($"[Inv] resolved via _steamHexByServerId: {ownerId}");
                            }
                            else
                            {
                                var session = allSessions.FirstOrDefault(a => a.ServerId == serverId && !string.IsNullOrEmpty(a.SteamHex));
                                if (session != null)
                                {
                                    ownerId = session.SteamHex;
                                    Console.WriteLine($"[Inv] resolved via ActiveSession cache: {ownerId}");
                                }
                            }

                                var allSlots = _db.Db.InventorySlot.Iter().ToList();
                                var playerSlots = allSlots.Where(s => s.OwnerId == ownerId && s.OwnerType == "player").ToList();
                                Console.WriteLine($"[Inv] owner_id={ownerId} total_slots_in_cache={allSlots.Count} player_slots={playerSlots.Count}");
                                var distinctOwners = allSlots.Select(s => $"{s.OwnerId}|{s.OwnerType}").Distinct().Take(10);
                                foreach (var o in distinctOwners)
                                    Console.WriteLine($"[Inv]   slot owner: {o}");

                            if (!string.IsNullOrEmpty(ownerId))
                            {
                                foreach (var s in playerSlots)
                                    slots.Add(new { id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType, item_id = s.ItemId, quantity = s.Quantity, metadata = s.Metadata, slot_index = s.SlotIndex });

                                foreach (var s in allSlots.Where(s => s.OwnerId.StartsWith(ownerId + "_equip_") && s.OwnerType == "equip"))
                                    equippedSlots.Add(new { id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType, item_id = s.ItemId, quantity = s.Quantity, metadata = s.Metadata, slot_index = s.SlotIndex, equip_key = s.OwnerId.Replace(ownerId + "_equip_", "") });

                                var bpSlot = allSlots.FirstOrDefault(s => s.OwnerId == ownerId + "_equip_backpack" && s.OwnerType == "equip");
                                if (bpSlot != null)
                                {
                                    string bpStash  = $"backpack_slot_{bpSlot.Id}";
                                    string bpLegacy = $"backpack_{ownerId}";
                                    uint   bpSlots2 = bpSlot.ItemId == "duffel_bag" ? 30u : 20u;
                                    float  bpWt     = bpSlot.ItemId == "duffel_bag" ? 50f : 30f;
                                    string bpLbl    = bpSlot.ItemId == "duffel_bag" ? "DUFFEL BAG" : "BACKPACK";
                                    try { _db.Reducers.CreateStash(bpStash, "backpack", bpLbl, bpSlots2, bpWt, ownerId, 0f, 0f, 0f); } catch { }
                                    var bpSlotList = allSlots
                                        .Where(s => (s.OwnerId == bpStash || s.OwnerId == bpLegacy) && s.OwnerType == "stash")
                                        .Select(s => (object)new { id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType, item_id = s.ItemId, quantity = s.Quantity, metadata = s.Metadata, slot_index = s.SlotIndex })
                                        .ToList();
                                    backpackData = new { stash_id = bpStash, label = bpLbl, max_weight = bpWt, max_slots = (int)bpSlots2, slots = bpSlotList };
                                }
                            }
                            else
                            {
                                Console.WriteLine($"[Inv] WARNING: could not resolve owner_id for server_id={serverId}");
                            }

                            foreach (var d in _db.Db.ItemDefinition.Iter())
                                defs[d.ItemId] = new { item_id = d.ItemId, label = d.Label, weight = d.Weight, stackable = d.Stackable, usable = d.Usable, max_stack = d.MaxStack, category = d.Category, prop_model = d.PropModel, mag_capacity = d.MagCapacity, stored_capacity = d.StoredCapacity, ammo_type = d.AmmoType };
                        }
                        catch (Exception ex) { Console.WriteLine($"[Sidecar] get_player_inventory error: {ex.Message}\n{ex.StackTrace}"); }

                        Console.WriteLine($"[Inv] Returning: owner_id={ownerId} slots={slots.Count} equip={equippedSlots.Count}");
                        await WriteJson(ctx, new { server_id = serverId, owner_id = ownerId, slots, equipped_slots = equippedSlots, backpack_data = backpackData, item_defs = defs, max_weight = 85 });
                        return;
                    }

                    case "get_vehicle_inventory":
                    {
                        string plate    = args.GetProperty("plate").GetString()          ?? "";
                        string invType  = args.GetProperty("inventory_type").GetString() ?? "glovebox";
                        var    config   = _db.Db.VehicleInventory.Iter().FirstOrDefault(v => v.Plate == plate);
                        bool   hasCfg   = config != null;
                        float  maxWt    = invType == "trunk" ? (hasCfg ? config!.TrunkMaxWeight : 50f) : 10f;
                        uint   maxSl    = invType == "trunk" ? (hasCfg ? config!.TrunkSlots : 20u)     : 5u;
                        string ownerTy  = invType == "trunk" ? "vehicle_trunk" : "vehicle_glovebox";
                        var    vSlots   = _db.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == plate && s.OwnerType == ownerTy)
                            .Select(s => (object)new { id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType, item_id = s.ItemId, quantity = s.Quantity, metadata = s.Metadata, slot_index = s.SlotIndex })
                            .ToList();
                        var vDefs = _db.Db.ItemDefinition.Iter()
                            .ToDictionary(d => d.ItemId, d => (object)new { item_id = d.ItemId, label = d.Label, weight = d.Weight, stackable = d.Stackable, usable = d.Usable, max_stack = d.MaxStack, category = d.Category, prop_model = d.PropModel, mag_capacity = d.MagCapacity, stored_capacity = d.StoredCapacity, ammo_type = d.AmmoType });
                        await WriteJson(ctx, new { plate, inventory_type = invType, trunk_type = hasCfg ? config!.TrunkType : "none", slots = vSlots, item_defs = vDefs, max_weight = maxWt, max_slots = maxSl });
                        return;
                    }

                    case "get_inventory_slots":
                    {
                        string gsType  = args.GetProperty("owner_type").GetString() ?? "";
                        string gsOwner = args.GetProperty("owner_id").GetString()   ?? "";
                        var    gsSlots = _db.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == gsOwner && s.OwnerType == gsType)
                            .Select(s => (object)new { id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType, item_id = s.ItemId, quantity = s.Quantity, metadata = s.Metadata, slot_index = s.SlotIndex })
                            .ToList();
                        await WriteJson(ctx, new { slots = gsSlots });
                        return;
                    }

                    case "get_stash_pos":
                    {
                        string spId = args.GetProperty("stash_id").GetString() ?? "";
                        var    spDef = _db.Db.StashDefinition.Iter().FirstOrDefault(s => s.StashId == spId);
                        await WriteJson(ctx, spDef != null
                            ? new { pos_x = spDef.PosX, pos_y = spDef.PosY, pos_z = spDef.PosZ }
                            : new { pos_x = 0f, pos_y = 0f, pos_z = 0f });
                        return;
                    }

                    case "get_stash_inventory":
                    {
                        string siId    = args.GetProperty("stash_id").GetString() ?? "";
                        var    siDef   = _db.Db.StashDefinition.Iter().FirstOrDefault(s => s.StashId == siId);
                        var    siSlots = _db.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == siId && s.OwnerType == "stash")
                            .Select(s => (object)new { id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType, item_id = s.ItemId, quantity = s.Quantity, metadata = s.Metadata, slot_index = s.SlotIndex })
                            .ToList();
                        var siDefs = _db.Db.ItemDefinition.Iter()
                            .ToDictionary(d => d.ItemId, d => (object)new { item_id = d.ItemId, label = d.Label, weight = d.Weight, stackable = d.Stackable, usable = d.Usable, max_stack = d.MaxStack });
                        await WriteJson(ctx, new { stash_id = siId, label = siDef?.Label ?? siId, max_weight = siDef?.MaxWeight ?? 100f, max_slots = siDef?.MaxSlots ?? 20u, slots = siSlots, item_defs = siDefs });
                        return;
                    }

                    case "give_item_to_player":
                    {
                        uint   gSid  = args.GetProperty("server_id").GetUInt32();
                        string gItem = args.GetProperty("item_id").GetString()  ?? "";
                        uint   gQty  = args.TryGetProperty("quantity", out var gq) ? gq.GetUInt32() : 1;
                        var    gSess = _db.Db.ActiveSession.Iter().FirstOrDefault(a => a.ServerId == gSid);
                        if (gSess == null) { await WriteJson(ctx, new { ok = false, error = "player not found" }); return; }
                        try
                        {
                            _db.Reducers.GiveItemToIdentity(gSess.SteamHex, gItem, gQty, "{}");
                            await WriteJson(ctx, new { ok = true, owner_id = gSess.SteamHex });
                        }
                        catch (Exception ex) when (ex.Message.Contains("WEIGHT_LIMIT"))
                        {
                            var p = ex.Message.Split('|');
                            await WriteJson(ctx, new { ok = false, error_code = "WEIGHT_LIMIT", actual_kg = p.Length > 1 ? p[1] : "?", max_kg = p.Length > 2 ? p[2] : "?" });
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine($"[Sidecar] give_item_to_player error: {ex.Message}");
                            await WriteJson(ctx, new { ok = false, error_code = "REDUCER_ERROR", message = ex.Message });
                        }
                        return;
                    }

                    case "reset_player_inventory":
                    {
                        // Resolve steam_hex — three fallback levels:
                        //   1. Explicit steam_hex in args (sent by Lua when it can resolve locally)
                        //   2. _steamHexByServerId in-memory map (populated on on_player_connect)
                        //   3. ActiveSession subscription cache (last resort, may be empty)
                        string resetHex = "";

                        if (args.TryGetProperty("steam_hex", out var shEl))
                        {
                            resetHex = shEl.GetString() ?? "";
                        }
                        else if (args.TryGetProperty("server_id", out var sidEl2))
                        {
                            uint resetSid = sidEl2.GetUInt32();

                            // Level 2: in-memory map — always populated when player connects
                            if (_steamHexByServerId.TryGetValue(resetSid, out var mappedHex))
                            {
                                resetHex = mappedHex;
                            }
                            else
                            {
                                // Level 3: subscription cache fallback
                                var resetSess = _db.Db.ActiveSession.Iter().FirstOrDefault(a => a.ServerId == resetSid);
                                if (resetSess != null)
                                    resetHex = resetSess.SteamHex;
                            }

                            if (string.IsNullOrEmpty(resetHex))
                            {
                                await WriteJson(ctx, new { ok = false, error = $"no active session for server_id={resetSid}" });
                                return;
                            }
                        }

                        if (string.IsNullOrEmpty(resetHex))
                        {
                            await WriteJson(ctx, new { ok = false, error = "steam_hex or server_id required" });
                            return;
                        }

                        Console.WriteLine($"[Sidecar] reset_player_inventory for {resetHex}");

                        // 1. Delete all pocket slots and equip slots.
                        //    Use RemoveItem per-slot (it looks up by owner+itemId, not by slot ID).
                        //    Log each result so we can see if any fail.
                        var slotsToRemove = _db.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == resetHex && s.OwnerType == "player")
                            .ToList();
                        var equipToRemove = _db.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId.StartsWith(resetHex + "_equip_") && s.OwnerType == "equip")
                            .ToList();

                        Console.WriteLine($"[Sidecar] reset: found {slotsToRemove.Count} pocket + {equipToRemove.Count} equip slots to remove");

                        int removedCount = 0;
                        foreach (var slot in slotsToRemove.Concat(equipToRemove))
                        {
                            try
                            {
                                _db.Reducers.RemoveItem(slot.OwnerId, slot.ItemId, slot.Quantity);
                                Console.WriteLine($"[Sidecar] reset: removed slot id={slot.Id} item={slot.ItemId} qty={slot.Quantity}");
                                removedCount++;
                            }
                            catch (Exception ex)
                            {
                                Console.WriteLine($"[Sidecar] reset: RemoveItem slot {slot.Id} ({slot.ItemId}) failed: {ex.Message}");
                            }
                        }

                        Console.WriteLine($"[Sidecar] reset_player_inventory: removed {removedCount} slot(s) for {resetHex}");

                        // 3. Re-seed using AddItem — simpler reducer with no weight gate.
                        //    GiveItemToIdentity returns Err() silently on the C# fire-and-forget
                        //    path; AddItem is the direct insert used by the original starter kit.
                        //    Weapons get explicit metadata generated here so they have a serial.
                        var starterKit = new (string itemId, uint qty)[]
                        {
                            ("phone",         1), ("id_card",       1), ("water_bottle",  2),
                            ("food_burger",   1), ("bandage",       5), ("cash",        500),
                            ("backpack",      1), ("weapon_pistol", 1), ("ammo_pistol",  50),
                            ("parachute",     1), ("body_armour",   1),
                        };

                        int givenCount = 0;
                        uint slotIndex = 0;
                        foreach (var (itemId, qty) in starterKit)
                        {
                            try
                            {
                                // Build weapon metadata the same way reducers.rs does it
                                string meta = "{}";
                                var def = _db.Db.ItemDefinition.Iter().FirstOrDefault(d => d.ItemId == itemId);
                                if (def != null && def.Category == "weapon")
                                {
                                    var serial = $"WPN-{Guid.NewGuid().ToString("N")[..8].ToUpper()}";
                                    meta = JsonSerializer.Serialize(new
                                    {
                                        serial,
                                        mag_ammo        = 0,
                                        stored_ammo     = 0,
                                        mag_capacity    = def.MagCapacity,
                                        stored_capacity = def.StoredCapacity,
                                        durability      = 100,
                                        ammo_type       = def.AmmoType,
                                    });
                                }
                                _db.Reducers.AddItem(resetHex, "player", itemId, qty, meta);
                                Console.WriteLine($"[Sidecar] reset: gave {qty}x {itemId} to {resetHex}");
                                givenCount++;
                                slotIndex++;
                            }
                            catch (Exception ex)
                            {
                                Console.WriteLine($"[Sidecar] reset: AddItem {itemId} failed: {ex.Message}");
                            }
                        }

                        Console.WriteLine($"[Sidecar] reset_player_inventory: gave {givenCount} starter item(s) to {resetHex}");
                        await WriteJson(ctx, new { ok = true, steam_hex = resetHex, removed = removedCount, given = givenCount });
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

    // ─────────────────────────────────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    static async Task WriteJson(HttpListenerContext ctx, object data)
    {
        var json  = JsonSerializer.Serialize(data);
        var bytes = Encoding.UTF8.GetBytes(json);
        ctx.Response.ContentType = "application/json";
        ctx.Response.StatusCode  = 200;
        ctx.Response.Headers["X-HyprFM-Version"] = API_VERSION;
        await ctx.Response.OutputStream.WriteAsync(bytes);
        ctx.Response.Close();
    }
}