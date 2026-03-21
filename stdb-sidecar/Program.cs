// G:\FIVEMSTDBPROJECT\stdb-sidecar\Program.cs
// COMPLETE FILE — replace entire contents

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

    static async Task Main(string[] args)
    {
        string stdbUri = Environment.GetEnvironmentVariable("STDB_URI")  ?? "ws://127.0.0.1:3000";
        string stdbDb  = Environment.GetEnvironmentVariable("STDB_DB")   ?? "fivem-game";
        string token   = Environment.GetEnvironmentVariable("STDB_TOKEN") ?? "";

        Console.WriteLine($"[Sidecar] SpacetimeDB : {stdbUri}/{stdbDb}");
        Console.WriteLine($"[Sidecar] HTTP port   : {_sidecarPort}");

        _ = Task.Run(() => StartHttpListener());
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
        Console.WriteLine("[Sidecar] Subscription active. Seeding items...");
        _db!.Db.InstructionQueue.OnInsert += OnInstructionInserted;
        SeedItems();
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
                    item.Category, item.PropModel);
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
                            args.GetProperty("net_id").GetUInt32()
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
                        ulong tSlotId    = args.GetProperty("slot_id").GetUInt64();
                        uint  tServerId  = args.GetProperty("server_id").GetUInt32();
                        uint  tSlotIndex = args.GetProperty("new_slot_index").GetUInt32();
                        var   tSession   = _db.Db.ActiveSession.Iter()
                            .FirstOrDefault(a => a.ServerId == tServerId);
                        if (tSession.ServerId != 0)
                        {
                            var tIdentity = tSession.Identity.ToString().ToLower();
                            if (tIdentity.StartsWith("0x")) tIdentity = tIdentity.Substring(2);
                            // Find next free slot for target player
                            if (tSlotIndex == 0)
                            {
                                var usedTgt = _db.Db.InventorySlot.Iter()
                                    .Where(s => s.OwnerId == tIdentity && s.OwnerType == "player")
                                    .Select(s => s.SlotIndex).ToHashSet();
                                while (usedTgt.Contains(tSlotIndex)) tSlotIndex++;
                            }
                            _db.Reducers.TransferItem(tSlotId, tIdentity, "player", tSlotIndex);
                        }
                        break;
                    }

                    case "use_item":
                        _db.Reducers.UseItem(
                            args.GetProperty("slot_id").GetUInt64(),
                            args.GetProperty("net_id").GetUInt32()
                        );
                        break;

                    case "add_item":
                        _db.Reducers.AddItem(
                            args.GetProperty("owner_id").GetString()   ?? "",
                            args.GetProperty("owner_type").GetString() ?? "player",
                            args.GetProperty("item_id").GetString()    ?? "",
                            args.GetProperty("quantity").GetUInt32(),
                            args.GetProperty("metadata").GetString()   ?? "{}"
                        );
                        break;

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

                            if (session.ServerId != 0)
                            {
                                var identityStr = session.Identity.ToString().ToLower();
                                if (identityStr.StartsWith("0x")) identityStr = identityStr.Substring(2);
                                ownerId = identityStr;
                                Console.WriteLine($"[Sidecar] Looking for owner_id={identityStr}, slot count={_db.Db.InventorySlot.Iter().Count()}");

                                foreach (var s in _db.Db.InventorySlot.Iter()
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

                                foreach (var s in _db.Db.InventorySlot.Iter()
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
                                    category   = d.Category,
                                    prop_model = d.PropModel,
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
                                string bpStashId = $"backpack_slot_{bpSlot.Id}";
                                string bpItemId  = bpSlot.ItemId;
                                uint   bpMaxSlots = bpItemId == "duffel_bag" ? 30u : 20u;
                                float  bpWeight  = bpItemId == "duffel_bag" ? 50f  : 30f;
                                string bpLabel   = bpItemId == "duffel_bag" ? "DUFFEL BAG" : "BACKPACK";
                                try { _db!.Reducers.CreateStash(bpStashId, "backpack", bpLabel, bpMaxSlots, bpWeight, ownerId, 0f, 0f, 0f); } catch { }
                                var bpSlotList = _db!.Db.InventorySlot.Iter()
                                    .Where(s => s.OwnerId == bpStashId && s.OwnerType == "stash")
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
                        // inventory_type = "glovebox" | "trunk"

                        var config = _db.Db.VehicleInventory.Iter()
                            .FirstOrDefault(v => v.Plate == plate);

                        bool   hasConfig = config.Plate != null && config.Plate != "";
                        float  maxWeight = inventoryType == "trunk"
                            ? (hasConfig ? config.TrunkMaxWeight : 50f)
                            : 10f;
                        uint   maxSlots  = inventoryType == "trunk"
                            ? (hasConfig ? config.TrunkSlots : 20u)
                            : 5u;
                        string ownerType = inventoryType == "trunk" ? "vehicle_trunk" : "vehicle_glovebox";

                        var slots = _db.Db.InventorySlot.Iter()
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
                                item_id = d.ItemId, label = d.Label, weight = d.Weight,
                                stackable = d.Stackable, usable = d.Usable, max_stack = d.MaxStack,
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

                        var bpSlotList = _db!.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == bpStashId && s.OwnerType == "stash")
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

                        float searchRadius = 5f;
                        var nearbyDrop = _db!.Db.StashDefinition.Iter()
                            .Where(s => s.StashType == "ground")
                            .Where(s => {
                                float ddx = s.PosX - dx, ddy = s.PosY - dy;
                                return (ddx*ddx + ddy*ddy) <= (searchRadius * searchRadius);
                            })
                            .OrderBy(s => {
                                float ddx = s.PosX - dx, ddy = s.PosY - dy;
                                return ddx*ddx + ddy*ddy;
                            })
                            .FirstOrDefault();

                        string dropStashId;
                        if (nearbyDrop != null && !string.IsNullOrEmpty(nearbyDrop.StashId))
                        {
                            dropStashId = nearbyDrop.StashId;
                        }
                        else
                        {
                            dropStashId = $"ground_{Guid.NewGuid():N}";
                            try { _db!.Reducers.CreateStash(dropStashId, "ground", "GROUND", 50u, 999f, "", dx, dy, dz); } catch { }
                        }

                        var dropSlot = _db!.Db.InventorySlot.Iter().FirstOrDefault(s => s.Id == dropSlotId);
                        if (dropSlot == null || string.IsNullOrEmpty(dropSlot.OwnerId))
                        {
                            await WriteJson(ctx, new { ok = false, error = "slot not found" });
                            return;
                        }

                        var usedDropIndices = _db!.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == dropStashId)
                            .Select(s => s.SlotIndex).ToHashSet();
                        uint newDropIndex = 0;
                        while (usedDropIndices.Contains(newDropIndex)) newDropIndex++;

                        uint actualDropQty = (dropQty > 0 && dropQty < dropSlot.Quantity) ? dropQty : dropSlot.Quantity;

                        if (actualDropQty == dropSlot.Quantity)
                        {
                            _db!.Reducers.TransferItem(dropSlotId, dropStashId, "stash", newDropIndex);
                        }
                        else
                        {
                            _db!.Reducers.RemoveItem(dropSlot.OwnerId, dropSlot.ItemId, actualDropQty);
                            _db!.Reducers.AddItem(dropStashId, "stash", dropSlot.ItemId, actualDropQty, dropSlot.Metadata);
                        }

                        // Find the slot we just created/moved
                        var newSlot = _db!.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == dropStashId && s.OwnerType == "stash" && s.SlotIndex == newDropIndex)
                            .FirstOrDefault();
                        await WriteJson(ctx, new {
                            ok = true,
                            stash_id = dropStashId,
                            new_slot_id = newSlot?.Id ?? 0,
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

                        // Search for any existing ground stash within 5m
                        float searchRadius = 5f;
                        var nearby = _db.Db.StashDefinition.Iter()
                            .Where(s => s.StashType == "ground")
                            .Where(s => {
                                float dx = s.PosX - gx, dy = s.PosY - gy;
                                return (dx*dx + dy*dy) <= (searchRadius * searchRadius);
                            })
                            .OrderBy(s => {
                                float dx = s.PosX - gx, dy = s.PosY - gy;
                                return dx*dx + dy*dy;
                            })
                            .FirstOrDefault();

                        string gStashId;
                          if (nearby != null && !string.IsNullOrEmpty(nearby.StashId))
                          {
                              gStashId = nearby.StashId;
                              Console.WriteLine($"[Sidecar] Found nearby ground stash {gStashId}");
                          }
                          else
                          {
                              gStashId = $"ground_{Guid.NewGuid():N}";
                            Console.WriteLine($"[Sidecar] Creating new ground stash {gStashId} at {gx:F1},{gy:F1}");
                            try
                            {
                                _db.Reducers.CreateStash(
                                    gStashId, "ground", "GROUND", 50u, 999f, "",
                                    gx, gy, gz);
                            }
                            catch { /* race condition, ignore */ }
                        }

                        var gSlots = _db.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == gStashId && s.OwnerType == "stash")
                            .Select(s => (object)new {
                                id         = s.Id,
                                owner_id   = s.OwnerId,
                                owner_type = s.OwnerType,
                                item_id    = s.ItemId,
                                quantity   = s.Quantity,
                                metadata   = s.Metadata,
                                slot_index = s.SlotIndex,
                            }).ToList();

                        var gDefs = _db.Db.ItemDefinition.Iter()
                            .ToDictionary(d => d.ItemId, d => (object)new {
                                item_id   = d.ItemId, label     = d.Label,
                                weight    = d.Weight, stackable = d.Stackable,
                                usable    = d.Usable, max_stack = d.MaxStack,
                                category  = d.Category,
                                prop_model = d.PropModel,
                            });

                        Console.WriteLine($"[Sidecar] Ground stash {gStashId} has {gSlots.Count} slots");

                        await WriteJson(ctx, new {
                            stash_id   = gStashId,
                            label      = "GROUND",
                            max_weight = 999f,
                            max_slots  = 50,
                            slots      = gSlots,
                            item_defs  = gDefs,
                        });
                        return;
                    }

                    case "get_stash_inventory":
                    {
                        string stashId = args.GetProperty("stash_id").GetString() ?? "";

                        var def = _db.Db.StashDefinition.Iter()
                            .FirstOrDefault(s => s.StashId == stashId);

                        bool hasConfig = def.StashId != null;

                        var slots = _db.Db.InventorySlot.Iter()
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
}