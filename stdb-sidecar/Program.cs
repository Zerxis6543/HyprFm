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

    // Default spawn used as fallback when Character row has zero coords
    const float DEFAULT_SPAWN_X = -269.0f;
    const float DEFAULT_SPAWN_Y = -955.0f;
    const float DEFAULT_SPAWN_Z =   31.0f;
    const float DEFAULT_HEADING =  205.0f;

    static readonly ConcurrentQueue<InstructionQueue> _pending    = new();
    static readonly ConcurrentQueue<object>           _deltaQueue = new();
    static readonly SemaphoreSlim                     _syncGate   = new(0, 1);

    // ── Connection health ─────────────────────────────────────────────────────
    static volatile bool _connected  = false;          // set true in OnConnected, false on disconnect
    static string        _stdbDb     = "";              // captured from env var at startup
    static readonly DateTime _processStart = DateTime.UtcNow;

    // Tables subscribed in OnConnected — mirrored here so /health can report them
    // without re-parsing the SQL strings at request time.
    static readonly string[] _subscribedTables = new[]
    {
        "instruction_queue", "char_session", "account", "character",
        "character_appearance", "inventory_slot", "item_definition",
        "vehicle_inventory", "stash_definition", "dynamic_opcode",
    };

    // ── Diagnostics ───────────────────────────────────────────────────────────
    static long     _deltaFireCount = 0;
    static DateTime _lastDeltaTime  = DateTime.MinValue;


    // ─────────────────────────────────────────────────────────────────────────────
    // HYPR ERROR PARSING
    // This is the ONLY place in the sidecar that reads raw SpacetimeDB exception
    // text. All other code consumes the structured HyprParsedError record.
    // ─────────────────────────────────────────────────────────────────────────────

    /// Structured representation of a parsed HyprError from the wire.
    /// Wire format: "ERROR_CODE|message"  (message may contain additional '|')
    record HyprParsedError(
        string Code,      // e.g. "NOT_FOUND", "INVENTORY_FULL"
        string Message,   // everything after the first pipe
        // Weight-limit extras — only populated when Code == "INVENTORY_FULL"
        // and the message matches "actual|max" (two float segments)
        string? ActualKg = null,
        string? MaxKg    = null
    );

    static HyprParsedError ParseHyprError(string raw)
    {
        // ── Split on first pipe only — message may itself contain pipes
        var idx = raw.IndexOf('|');
        if (idx < 0)
            return new HyprParsedError(raw, string.Empty);

        var code    = raw[..idx];
        var message = raw[(idx + 1)..];

        // ── INVENTORY_FULL special case: "actual|max" weight sub-format
        // Produced by HyprError::weight_exceeded() in Rust.
        if (code == "INVENTORY_FULL")
        {
            var parts = message.Split('|');
            if (parts.Length == 2 &&
                float.TryParse(parts[0], out _) &&
                float.TryParse(parts[1], out _))
            {
                return new HyprParsedError(code, message, ActualKg: parts[0], MaxKg: parts[1]);
            }
        }

        return new HyprParsedError(code, message);
    }

    /// Writes a standardised error JSON response from a parsed HyprError.
    /// This is what Lua receives — the public API contract.
    static async Task WriteHyprError(HttpListenerContext ctx, HyprParsedError err)
    {
        // Build base object
        object response = err.Code switch
        {
            // ── Weight limit: surface actual/max as top-level fields for Lua math
            "INVENTORY_FULL" when err.ActualKg is not null => new
            {
                ok         = false,
                error_code = err.Code,
                message    = err.Message,
                actual_kg  = err.ActualKg,
                max_kg     = err.MaxKg,
            },
            // ── Ban: preserved as BANNED for backward compat with Lua kick flow
            "UNAUTHORISED" when err.Message.StartsWith("BANNED: ") => new
            {
                ok         = false,
                error_code = "BANNED",
                reason     = err.Message[8..], // strip "BANNED: " prefix
            },
            // ── All other errors: generic envelope
            _ => new
            {
                ok         = false,
                error_code = err.Code,
                message    = err.Message,
            },
        };
        await WriteJson(ctx, response);
    }

    // ── DYNAMIC OPCODE CACHE ──────────────────────────────────────────────────────

    record DynamicOpcodeEntry(
        string Context,
        string OwnerSteamHex,
        uint   NetId,
        ulong  ExpiresAtMicros
    );

    static readonly ConcurrentDictionary<ushort, DynamicOpcodeEntry>
        _dynamicOpcodes = new();

    static readonly ConcurrentDictionary<string, TaskCompletionSource<ushort>>
        _pendingAllocations = new();


    // ─────────────────────────────────────────────────────────────────────────────
    // MODULE REGISTRY
    // ─────────────────────────────────────────────────────────────────────────────

    record RegisteredModule(
        string   Name,
        string   WasmPath,
        string   ResourceName,
        string[] Tables,
        string   Database,
        string   Version,
        DateTime RegisteredAt,
        string?   PublishError    = null,
        string?   LiveVersion     = null,
        DateTime? LastPublishedAt = null
    );

    static readonly ConcurrentDictionary<string, RegisteredModule> _moduleRegistry = new();

    // ─────────────────────────────────────────────────────────────────────────
    // IDENTITY REGISTRY
    // ─────────────────────────────────────────────────────────────────────────

    record SessionIdentity(string SteamHex, ulong CharacterId);

    static readonly ConcurrentDictionary<string, SemaphoreSlim> _publishLocks = new();
    static readonly ConcurrentDictionary<uint,   SessionIdentity> _serverIdToSession = new();
    static readonly ConcurrentDictionary<string, uint>            _hexToServerId      = new();

    static string?   _spacetimeIdentity = null;
    static bool      _cliAvailable      = false;
    static readonly  HttpClient _stdbHttpClient    = new()
    { Timeout = TimeSpan.FromSeconds(10) };

    static void RegisterSession(string steamHex, ulong characterId, uint serverId)
    {
        if (string.IsNullOrEmpty(steamHex) || serverId == 0) return;
        _serverIdToSession[serverId] = new SessionIdentity(steamHex, characterId);
        _hexToServerId[steamHex]     = serverId;
    }

    static void ClearSession(uint serverId)
    {
        if (_serverIdToSession.TryRemove(serverId, out var id) && id != null)
            _hexToServerId.TryRemove(id.SteamHex, out _);
    }

    static SessionIdentity? ResolveSession(uint serverId)
        => _serverIdToSession.TryGetValue(serverId, out var id) ? id : null;

    /// Canonical owner_id string for a character's inventory.
    static string CharOwnerString(ulong characterId) => characterId.ToString();

    // ─────────────────────────────────────────────────────────────────────────
    // ENTRY POINT
    // ─────────────────────────────────────────────────────────────────────────

    static async Task Main(string[] args)
    {
        string stdbUri = Environment.GetEnvironmentVariable("STDB_URI")  ?? "ws://127.0.0.1:3000";
        string stdbDb  = Environment.GetEnvironmentVariable("STDB_DB")   ?? "fivem-game";
        string token   = Environment.GetEnvironmentVariable("STDB_TOKEN") ?? "";

        _stdbDb = stdbDb;   // stored so /health can report it without closing over the local

        Console.WriteLine($"[Sidecar] SpacetimeDB : {stdbUri}/{stdbDb}");
        Console.WriteLine($"[Sidecar] HTTP port   : {_sidecarPort}");

        await CheckCliAvailableAsync();
        await LoadSpacetimeIdentityAsync();
        // existing lines follow:
        _ = Task.Run(StartHttpListener);
        _ = Task.Run(SeedItemsWhenReady);

        await Connect(stdbUri, stdbDb, token);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CONNECTION + FRAME LOOP
    // ─────────────────────────────────────────────────────────────────────────

    static async Task Connect(string uri, string dbName, string token = "")
    {
        // Backoff state: 1 s → 2 s → 4 s → 8 s → 16 s → 30 s (ceiling), ±10 % jitter.
        const int InitialBackoffMs = 1_000;
        const int MaxBackoffMs     = 30_000;
        var rng = new Random();
        int backoffMs = InitialBackoffMs;

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
                    .OnDisconnect((conn, ex) =>
                    {
                        _connected = false;
                        Console.WriteLine($"[Sidecar] Disconnected: {ex?.Message ?? "clean close"}");
                    })
                    .Build();

                while (true) { _db.FrameTick(); await Task.Delay(50); }
            }
            catch (Exception ex)
            {
                _connected = false;
                _db        = null;

                // ── Jitter: ±10 % of current backoff ────────────────────────
                int jitter = (int)(backoffMs * 0.10 * (rng.NextDouble() * 2 - 1));
                int delay  = Math.Clamp(backoffMs + jitter, 1, MaxBackoffMs);

                Console.WriteLine($"[Sidecar] Fatal: {ex.Message} — retrying in {delay / 1_000.0:F1}s");
                await Task.Delay(delay);

                // ── Advance backoff, capped at ceiling ───────────────────────
                backoffMs = Math.Min(backoffMs * 2, MaxBackoffMs);
            }
        }
    }

        static void OnConnected(DbConnection conn, Identity identity, string token)
        {
            Console.WriteLine($"[Sidecar] Connected. Identity: {identity}");
            _connected = true;
            conn.SubscriptionBuilder()
                .OnApplied(OnSubscriptionReady)
                .Subscribe(new[]
                {
                    "SELECT * FROM instruction_queue WHERE consumed = false",
                    "SELECT * FROM char_session",
                    "SELECT * FROM account",
                    "SELECT * FROM character",
                    "SELECT * FROM character_appearance",
                    "SELECT * FROM inventory_slot",
                    "SELECT * FROM item_definition",
                    "SELECT * FROM vehicle_inventory",
                    "SELECT * FROM stash_definition",
                    "SELECT * FROM dynamic_opcode",
                });
        }

    // ─────────────────────────────────────────────────────────────────────────
    // SUBSCRIPTION CALLBACKS
    // ─────────────────────────────────────────────────────────────────────────

    static void OnSubscriptionReady(SubscriptionEventContext ctx)
    {
        Console.WriteLine("[Sidecar] Subscription active — hydrating identity registry...");

        // Hydrate session registry from live CharSession rows.
        // This handles sidecar restarts while players are already connected.
        foreach (var session in _db!.Db.CharSession.Iter())
        {
            if (!string.IsNullOrEmpty(session.SteamHex) && session.ServerId > 0)
            {
                RegisterSession(session.SteamHex, session.CharacterId, session.ServerId);
                Console.WriteLine($"[Sidecar] Hydrated: {session.SteamHex} → char_id={session.CharacterId} server_id={session.ServerId}");
            }
        }

        _db!.Db.InstructionQueue.OnInsert += OnInstructionInserted;

        // owner_id in deltas is now a character_id string ("42") not a steam_hex
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
            Console.WriteLine($"[Delta] ADDED  id={slot.Id} owner_id={slot.OwnerId} item={slot.ItemId}");
            _deltaQueue.Enqueue(new { type = "added", slot = SlotShape(slot), owner_id = slot.OwnerId });
        };

        _db!.Db.InventorySlot.OnUpdate += (evCtx, oldSlot, newSlot) =>
        {
            Interlocked.Increment(ref _deltaFireCount);
            _lastDeltaTime = DateTime.UtcNow;
            if (oldSlot.OwnerId != newSlot.OwnerId)
            {
                Console.WriteLine($"[Delta] OWNER CHANGE id={oldSlot.Id} {oldSlot.OwnerId}→{newSlot.OwnerId}");
                _deltaQueue.Enqueue(new { type = "deleted", slot_id = oldSlot.Id, owner_id = oldSlot.OwnerId });
            }
            Console.WriteLine($"[Delta] UPDATED id={newSlot.Id} owner_id={newSlot.OwnerId}");
            _deltaQueue.Enqueue(new { type = "updated", slot = SlotShape(newSlot), owner_id = newSlot.OwnerId });
        };

        _db!.Db.InventorySlot.OnDelete += (evCtx, slot) =>
        {
            Interlocked.Increment(ref _deltaFireCount);
            _lastDeltaTime = DateTime.UtcNow;
            Console.WriteLine($"[Delta] DELETED id={slot.Id} owner_id={slot.OwnerId}");
            _deltaQueue.Enqueue(new { type = "deleted", slot_id = slot.Id, owner_id = slot.OwnerId });
        };

        var slotCount   = _db!.Db.InventorySlot.Iter().Count();
        var charCount   = _db!.Db.Character.Iter().Count();
        var sessionCount = _db!.Db.CharSession.Iter().Count();
        Console.WriteLine($"[Sidecar] Hydrated: chars={charCount} sessions={sessionCount} slots={slotCount}");

        WireDynamicOpcodeDeltas();
                _syncGate.Release();
            }

    static void WireDynamicOpcodeDeltas()
    {
        _db!.Db.DynamicOpcode.OnInsert += (evCtx, row) =>
        {
            _dynamicOpcodes[(ushort)row.Opcode] = new DynamicOpcodeEntry(
                row.Context, row.OwnerSteamHex, row.NetId, row.ExpiresAtMicros);
            Console.WriteLine($"[Opcode] ALLOCATED 0x{row.Opcode:X4} ctx='{row.Context}' permanent={row.ExpiresAtMicros == ulong.MaxValue}");
            if (_pendingAllocations.TryRemove(row.Context, out var tcs))
                tcs.TrySetResult((ushort)row.Opcode);
        };

        _db!.Db.DynamicOpcode.OnUpdate += (evCtx, oldRow, newRow) =>
        {
            if (newRow.IsConsumed)
            {
                _dynamicOpcodes.TryRemove((ushort)newRow.Opcode, out _);
                Console.WriteLine($"[Opcode] CONSUMED  0x{newRow.Opcode:X4} — evicted");
            }
            else
            {
                _dynamicOpcodes[(ushort)newRow.Opcode] = new DynamicOpcodeEntry(
                    newRow.Context, newRow.OwnerSteamHex, newRow.NetId, newRow.ExpiresAtMicros);
            }
        };

        _db!.Db.DynamicOpcode.OnDelete += (evCtx, row) =>
        {
            _dynamicOpcodes.TryRemove((ushort)row.Opcode, out _);
            Console.WriteLine($"[Opcode] RECYCLED  0x{row.Opcode:X4} ctx='{row.Context}'");
        };

        foreach (var row in _db!.Db.DynamicOpcode.Iter())
            _dynamicOpcodes[(ushort)row.Opcode] = new DynamicOpcodeEntry(
                row.Context, row.OwnerSteamHex, row.NetId, row.ExpiresAtMicros);

        Console.WriteLine($"[Opcode] Cache hydrated — {_dynamicOpcodes.Count} active opcodes");
    }

    static bool ValidateDynamicOpcode(ushort opcode, out DynamicOpcodeEntry? entry)
    {
        if (!_dynamicOpcodes.TryGetValue(opcode, out entry)) return false;
        if (entry.ExpiresAtMicros == ulong.MaxValue) return true;
        var nowMicros = (ulong)(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1_000L);
        if (entry.ExpiresAtMicros <= nowMicros + 500_000UL)
        {
            _dynamicOpcodes.TryRemove(opcode, out _);
            return false;
        }
        return true;
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
            catch (Exception ex) { Console.WriteLine($"[Sidecar] Seed error for {item.Id}: {ex.Message}"); }
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
            catch (Exception ex) { Console.WriteLine($"[Sidecar] Listener error: {ex.Message}"); }
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

            // ── GET /version ──────────────────────────────────────────────────
            if (ctx.Request.HttpMethod == "GET" && path == "/version")
            {
                await WriteJson(ctx, new { version = API_VERSION, status = "ok" });
                return;
            }

            // ── GET /health ───────────────────────────────────────────────────
            // 200 = connected and subscription active (readiness probe passes).
            // 503 = disconnected / reconnecting (readiness probe fails).
            if (ctx.Request.HttpMethod == "GET" && path == "/health")
            {
                bool isConnected = _connected;
                ctx.Response.StatusCode = isConnected ? 200 : 503;
                await WriteJson(ctx, new
                {
                    connected          = isConnected,
                    database           = _stdbDb,
                    subscribed_modules = _subscribedTables,
                    uptime_seconds     = (int)(DateTime.UtcNow - _processStart).TotalSeconds,
                });
                return;
            }


            // ── GET /diagnostics ──────────────────────────────────────────────
            if (ctx.Request.HttpMethod == "GET" && path == "/diagnostics")
            {
                await WriteJson(ctx, new
                {
                    db_connected         = _db != null,
                    delta_fire_count     = Interlocked.Read(ref _deltaFireCount),
                    delta_queue_pending  = _deltaQueue.Count,
                    last_delta_utc       = _lastDeltaTime == DateTime.MinValue ? "never" : _lastDeltaTime.ToString("o"),
                    inventory_slot_count = _db == null ? -1 : _db.Db.InventorySlot.Iter().Count(),
                    active_sessions      = _serverIdToSession.Count,
                    registered_modules   = _moduleRegistry.Count,
                });
                return;
            }

            // ── GET /instructions ─────────────────────────────────────────────
            if (ctx.Request.HttpMethod == "GET" && path == "/instructions")
            {
                var batch = new List<object>();
                while (_pending.TryDequeue(out var instr))
                    batch.Add(new { id = instr.Id, target_entity_net_id = instr.TargetEntityNetId, opcode = instr.Opcode, payload = instr.Payload });
                await WriteJson(ctx, batch);
                return;
            }

            // ── GET /slot-deltas ──────────────────────────────────────────────
            if (ctx.Request.HttpMethod == "GET" && path == "/slot-deltas")
            {
                var deltas = new List<object>();
                while (_deltaQueue.TryDequeue(out var delta)) deltas.Add(delta);
                if (deltas.Count > 0)
                    Console.WriteLine($"[Delta] Sending {deltas.Count} delta(s)");
                await WriteJson(ctx, deltas);
                return;
            }

            // ── GET /characters?server_id=X ───────────────────────────────────
            // Returns the full character list for the account tied to this server_id.
            // Called by Lua after session_open, before character selection.
            if (ctx.Request.HttpMethod == "GET" && path == "/characters")
            {
                var qs  = System.Web.HttpUtility.ParseQueryString(ctx.Request.Url?.Query ?? "");
                uint sid = uint.TryParse(qs["server_id"], out var s) ? s : 0u;

                // Resolve steam_hex — may have character_id = 0 (pending selection)
                string steamHex = ResolveSession(sid)?.SteamHex ?? "";
                if (string.IsNullOrEmpty(steamHex))
                    steamHex = _hexToServerId.FirstOrDefault(kv => kv.Value == sid).Key ?? "";

                if (string.IsNullOrEmpty(steamHex)) { ctx.Response.StatusCode = 404; ctx.Response.Close(); return; }

                var account    = _db!.Db.Account.Iter().FirstOrDefault(a => a.SteamHex == steamHex);
                var characters = _db!.Db.Character.Iter()
                    .Where(c => c.SteamHex == steamHex && !c.IsDeleted)
                    .OrderBy(c => c.SlotIndex)
                    .Select(c =>
                    {
                        var appearance = _db!.Db.CharacterAppearance.Iter()
                            .FirstOrDefault(a => a.CharacterId == c.Id);
                        return (object)new {
                            id              = c.Id,
                            slot_index      = c.SlotIndex,
                            name            = c.Name,
                            gender          = c.Gender,
                            job             = c.Job,
                            money_cash      = c.MoneyCash,
                            health          = c.Health,
                            last_seen       = c.UpdatedAt.ToString(),
                            components_json = appearance?.ComponentsJson ?? "{}",
                        };
                    })
                    .ToList();

                await WriteJson(ctx, new {
                    steam_hex      = steamHex,
                    max_characters = account?.MaxCharacters ?? 3u,
                    characters,
                });
                return;
            }

            // ── GET /character?server_id=X ────────────────────────────────────
            // Returns the active character's vitals and spawn position.
            if (ctx.Request.HttpMethod == "GET" && path == "/character")
            {
                var qs  = System.Web.HttpUtility.ParseQueryString(ctx.Request.Url?.Query ?? "");
                uint sid = uint.TryParse(qs["server_id"], out var sv) ? sv : 0u;
                var session = ResolveSession(sid);
                if (session == null || session.CharacterId == 0) { ctx.Response.StatusCode = 404; ctx.Response.Close(); return; }

                var character = _db!.Db.Character.Iter().FirstOrDefault(c => c.Id == session.CharacterId);
                if (character == null) { ctx.Response.StatusCode = 404; ctx.Response.Close(); return; }

                await WriteJson(ctx, new {
                    steam_hex    = session.SteamHex,
                    character_id = session.CharacterId,
                    owner_id     = CharOwnerString(session.CharacterId),
                    pos_x        = character.PosX,   pos_y    = character.PosY,
                    pos_z        = character.PosZ,   heading  = character.Heading,
                    health       = character.Health,
                    hunger       = character.Hunger,
                    thirst       = character.Thirst,
                    money_cash   = character.MoneyCash,
                    job          = character.Job,    job_grade = character.JobGrade,
                    name         = character.Name,
                });
                return;
            }

            // ── GET /item-count ───────────────────────────────────────────────
            if (ctx.Request.HttpMethod == "GET" && path == "/item-count")
            {
                var qs = System.Web.HttpUtility.ParseQueryString(ctx.Request.Url?.Query ?? "");
                string oi = qs["owner_id"] ?? "";
                string ii = qs["item_id"]  ?? "";
                if (string.IsNullOrEmpty(oi) || string.IsNullOrEmpty(ii)) { ctx.Response.StatusCode = 400; ctx.Response.Close(); return; }
                uint count = _db == null ? 0 : (uint)_db.Db.InventorySlot.Iter()
                    .Where(s => s.OwnerId == oi && s.ItemId == ii).Sum(s => (long)s.Quantity);
                await WriteJson(ctx, new { owner_id = oi, item_id = ii, count, has_item = count > 0 });
                return;
            }

            // ── POST /checkpoint ──────────────────────────────────────────────
            if (ctx.Request.HttpMethod == "POST" && path == "/checkpoint")
            {
                using var sr = new System.IO.StreamReader(ctx.Request.InputStream);
                string body  = await sr.ReadToEndAsync();
                using var doc = JsonDocument.Parse(body);
                var r = doc.RootElement;
                string hex = r.TryGetProperty("steam_hex", out var shEl) ? shEl.GetString() ?? "" : "";
                if (!string.IsNullOrEmpty(hex))
                {
                    _db!.Reducers.CheckpointVitals(hex,
                        (float)r.GetProperty("pos_x").GetDouble(),
                        (float)r.GetProperty("pos_y").GetDouble(),
                        (float)r.GetProperty("pos_z").GetDouble(),
                        (float)r.GetProperty("heading").GetDouble(),
                        r.GetProperty("health").GetUInt32(),
                        r.GetProperty("hunger").GetUInt32(),
                        r.GetProperty("thirst").GetUInt32());
                }
                ctx.Response.StatusCode = 200; ctx.Response.Close();
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
                        r.TryGetProperty("prop_model",      out var pm) ? pm.GetString() ?? "prop_cs_cardbox_01" : "prop_cs_cardbox_01",
                        r.TryGetProperty("mag_capacity",    out var mc) ? mc.GetInt32()  : 0,
                        r.TryGetProperty("stored_capacity", out var sc) ? sc.GetInt32()  : 0,
                        r.TryGetProperty("ammo_type",       out var at) ? at.GetString() ?? "" : "");
                    ctx.Response.StatusCode = 200; ctx.Response.Close();
                }
                catch (Exception ex) { Console.WriteLine($"[Sidecar] /seed-item error: {ex.Message}"); ctx.Response.StatusCode = 400; ctx.Response.Close(); }
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
                ctx.Response.StatusCode = 200; ctx.Response.Close();
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
                    // ── ACCOUNT / SESSION ─────────────────────────────────────

                    // Phase 1: Account auth (ban check, display name update).
                    // Does NOT open a CharSession — that is select_character (phase 2).
                    case "on_player_connect":
                    {
                        var serverId    = args.GetProperty("server_id").GetUInt32();
                        var steamHex    = args.GetProperty("steam_hex").GetString()    ?? "";
                        var displayName = args.GetProperty("display_name").GetString() ?? "";
                        var netId       = args.GetProperty("net_id").GetUInt32();

                        if (!string.IsNullOrEmpty(steamHex))
                            RegisterSession(steamHex, 0, serverId);

                        try
                        {
                            _db.Reducers.SessionOpen(steamHex, displayName);
                            await WriteJson(ctx, new { ok = true, steam_hex = steamHex });
                        }
                        catch (Exception ex)
                        {
                            var err = ParseHyprError(ex.Message);
                            // If the account is banned, clear the pending session before responding
                            if (err.Code == "UNAUTHORISED" && err.Message.StartsWith("BANNED: "))
                                ClearSession(serverId);
                            await WriteHyprError(ctx, err);
                        }
                        return;
                    }

                    // Phase 2: Character confirmed in NUI → open CharSession.
                    case "select_character":
                    {
                        var serverId    = args.GetProperty("server_id").GetUInt32();
                        var characterId = args.GetProperty("character_id").GetUInt64();
                        var netId       = args.GetProperty("net_id").GetUInt32();
                        var steamHex    = ResolveSession(serverId)?.SteamHex ?? "";

                        if (string.IsNullOrEmpty(steamHex))
                        { await WriteJson(ctx, new { ok = false, error_code = "NOT_FOUND", message = "session_not_found" }); return; }

                        try
                        {
                            _db.Reducers.SelectCharacter(steamHex, characterId, serverId, netId);
                            RegisterSession(steamHex, characterId, serverId);
                            var character = _db.Db.Character.Iter().FirstOrDefault(c => c.Id == characterId);
                            await WriteJson(ctx, new {
                                ok           = true,
                                character_id = characterId,
                                owner_id     = CharOwnerString(characterId),
                                pos_x        = character?.PosX    ?? DEFAULT_SPAWN_X,
                                pos_y        = character?.PosY    ?? DEFAULT_SPAWN_Y,
                                pos_z        = character?.PosZ    ?? DEFAULT_SPAWN_Z,
                                heading      = character?.Heading ?? DEFAULT_HEADING,
                                health       = character?.Health  ?? 200u,
                                hunger       = character?.Hunger  ?? 100u,
                                thirst       = character?.Thirst  ?? 100u,
                                name         = character?.Name    ?? "",
                                job          = character?.Job     ?? "unemployed",
                            });
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine($"[Sidecar] select_character error: {ex.Message}");
                            await WriteHyprError(ctx, ParseHyprError(ex.Message));
                        }
                        return;
                    }

                    case "create_character":
                    {
                        var steamHex  = args.GetProperty("steam_hex").GetString()  ?? "";
                        var slotIndex = args.GetProperty("slot_index").GetUInt32();
                        var charName  = args.GetProperty("name").GetString()       ?? "";
                        var gender    = args.GetProperty("gender").GetString()     ?? "male";
                        try
                        {
                            _db.Reducers.CreateCharacter(steamHex, slotIndex, charName, gender);
                            await WriteJson(ctx, new { ok = true });
                        }
                        catch (Exception ex)
                        {
                            await WriteHyprError(ctx, ParseHyprError(ex.Message));
                        }
                        return;
                    }

                    case "delete_character":
                    {
                        var steamHex    = args.GetProperty("steam_hex").GetString()    ?? "";
                        var characterId = args.GetProperty("character_id").GetUInt64();
                        try
                        {
                            _db.Reducers.DeleteCharacter(steamHex, characterId);
                            await WriteJson(ctx, new { ok = true });
                        }
                        catch (Exception ex)
                        {
                            await WriteJson(ctx, new { ok = false, error = ex.Message });
                        }
                        return;
                    }

                    case "save_appearance":
                    {
                        var steamHex       = args.GetProperty("steam_hex").GetString()       ?? "";
                        var characterId    = args.GetProperty("character_id").GetUInt64();
                        var componentsJson = args.GetProperty("components_json").GetString()  ?? "{}";
                        var overlaysJson   = args.GetProperty("overlays_json").GetString()    ?? "{}";
                        _db.Reducers.SaveAppearance(steamHex, characterId, componentsJson, overlaysJson);
                        ctx.Response.StatusCode = 200; ctx.Response.Close();
                        return;
                    }

                    case "on_player_disconnect":
                    {
                        uint sid = args.TryGetProperty("server_id", out var sidEl) ? sidEl.GetUInt32() : 0;
                        var hex  = args.TryGetProperty("steam_hex", out var shEl) ? shEl.GetString() ?? "" : "";
                        if (string.IsNullOrEmpty(hex) && sid > 0)
                            hex = ResolveSession(sid)?.SteamHex ?? "";

                        float px = args.TryGetProperty("pos_x",   out var pxEl) ? pxEl.GetSingle()  : 0f;
                        float py = args.TryGetProperty("pos_y",   out var pyEl) ? pyEl.GetSingle()  : 0f;
                        float pz = args.TryGetProperty("pos_z",   out var pzEl) ? pzEl.GetSingle()  : 0f;
                        float ph = args.TryGetProperty("heading", out var phEl) ? phEl.GetSingle()  : 0f;
                        uint  hp = args.TryGetProperty("health",  out var hpEl) ? hpEl.GetUInt32()  : 200u;
                        uint  hu = args.TryGetProperty("hunger",  out var huEl) ? huEl.GetUInt32()  : 100u;
                        uint  th = args.TryGetProperty("thirst",  out var thEl) ? thEl.GetUInt32()  : 100u;

                        if (!string.IsNullOrEmpty(hex))
                        {
                            _db.Reducers.SessionClose(hex, px, py, pz, ph, hp, hu, th);
                            if (sid > 0) ClearSession(sid);
                        }
                        else Console.WriteLine($"[Sidecar] WARNING: disconnect for server_id={sid} — hex not found");

                        ctx.Response.StatusCode = 200; ctx.Response.Close();
                        return;
                    }

                    case "request_spawn":
                    {
                        uint sid = args.GetProperty("server_id").GetUInt32();
                        var hex  = ResolveSession(sid)?.SteamHex ?? "";
                        if (string.IsNullOrEmpty(hex))
                        { Console.WriteLine($"[Sidecar] request_spawn: no session for server_id={sid}"); ctx.Response.StatusCode = 400; ctx.Response.Close(); return; }
                        _db.Reducers.RequestSpawn(hex,
                            args.GetProperty("spawn_x").GetSingle(),
                            args.GetProperty("spawn_y").GetSingle(),
                            args.GetProperty("spawn_z").GetSingle(),
                            args.GetProperty("heading").GetSingle());
                        break;
                    }

                    // ── INVENTORY ─────────────────────────────────────────────

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
                                aiMeta = JsonSerializer.Serialize(new {
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

                    case "give_item_to_player":
                    {
                        uint   gSid  = args.GetProperty("server_id").GetUInt32();
                        string gItem = args.GetProperty("item_id").GetString()  ?? "";
                        uint   gQty  = args.TryGetProperty("quantity", out var gq) ? gq.GetUInt32() : 1;
                        var    gSess = ResolveSession(gSid);
                        if (gSess == null || gSess.CharacterId == 0)
                        { await WriteJson(ctx, new { ok = false, error_code = "NOT_FOUND", message = "player not found or no character selected" }); return; }
                        try
                        {
                            _db.Reducers.GiveItemToCharacter(gSess.CharacterId, gItem, gQty, "{}");
                            await WriteJson(ctx, new { ok = true, owner_id = CharOwnerString(gSess.CharacterId) });
                        }
                        catch (Exception ex)
                        {
                            // ParseHyprError + WriteHyprError handles INVENTORY_FULL weight data automatically
                            await WriteHyprError(ctx, ParseHyprError(ex.Message));
                        }
                        return;
                    }

                    case "transfer_item_to_player":
                    {
                        ulong  tSlotId   = args.GetProperty("slot_id").GetUInt64();
                        uint   tServerId = args.GetProperty("server_id").GetUInt32();
                        var    tTarget   = ResolveSession(tServerId);
                        if (tTarget == null || tTarget.CharacterId == 0)
                        { await WriteJson(ctx, new { ok = false, error = "player not online" }); return; }
                        var tSlot = _db.Db.InventorySlot.Iter().FirstOrDefault(s => s.Id == tSlotId);
                        if (tSlot == null) { await WriteJson(ctx, new { ok = false, error = "slot not found" }); return; }
                        try
                        {
                            _db.Reducers.RemoveItem(tSlot.OwnerId, tSlot.ItemId, tSlot.Quantity);
                            _db.Reducers.GiveItemToCharacter(tTarget.CharacterId, tSlot.ItemId, tSlot.Quantity, tSlot.Metadata);
                            await WriteJson(ctx, new { ok = true, owner_id = CharOwnerString(tTarget.CharacterId) });
                        }
                        catch (Exception ex) when (ex.Message.Contains("WEIGHT_LIMIT"))
                        { var p = ex.Message.Split('|'); await WriteJson(ctx, new { ok = false, error_code = "WEIGHT_LIMIT", actual_kg = p.Length > 1 ? p[1] : "?", max_kg = p.Length > 2 ? p[2] : "?" }); }
                        catch (Exception ex)
                        { await WriteJson(ctx, new { ok = false, error_code = "REDUCER_ERROR", message = ex.Message }); }
                        return;
                    }

                    case "merge_stacks":
                        _db.Reducers.MergeStacks(args.GetProperty("src_slot_id").GetUInt64(), args.GetProperty("dst_slot_id").GetUInt64());
                        await WriteJson(ctx, new { ok = true }); return;

                    case "split_stack":
                        _db.Reducers.SplitStack(args.GetProperty("slot_id").GetUInt64(), args.GetProperty("amount").GetUInt32());
                        await WriteJson(ctx, new { ok = true }); return;

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
                        await WriteJson(ctx, new { ok = true }); return;
                    }

                    // ── GET PLAYER INVENTORY ──────────────────────────────────
                    // owner_id is now the character_id string, not steam_hex.
                    case "get_player_inventory":
                    {
                        uint serverId = args.GetProperty("server_id").GetUInt32();
                        var  session  = ResolveSession(serverId);

                        if (session == null || session.CharacterId == 0)
                        {
                            Console.WriteLine($"[Inv] get_player_inventory: no active character for server_id={serverId}");
                            await WriteJson(ctx, new { slots = Array.Empty<object>(), equipped_slots = Array.Empty<object>(), item_defs = new { }, max_weight = 85, owner_id = "" });
                            return;
                        }

                        string ownerId    = CharOwnerString(session.CharacterId);
                        string equipPrefix = ownerId + "_equip_";
                        var    allSlots   = _db.Db.InventorySlot.Iter().ToList();

                        var playerSlots = allSlots
                            .Where(s => s.OwnerId == ownerId && s.OwnerType == "player")
                            .Select(s => (object)new { id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType, item_id = s.ItemId, quantity = s.Quantity, metadata = s.Metadata, slot_index = s.SlotIndex })
                            .ToList();

                        var equippedSlots = allSlots
                            .Where(s => s.OwnerId.StartsWith(equipPrefix) && s.OwnerType == "equip")
                            .Select(s => (object)new { id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType, item_id = s.ItemId, quantity = s.Quantity, metadata = s.Metadata, slot_index = s.SlotIndex, equip_key = s.OwnerId.Replace(equipPrefix, "") })
                            .ToList();

                        // Backpack
                        object? backpackData = null;
                        var bpSlot = allSlots.FirstOrDefault(s => s.OwnerId == ownerId + "_equip_backpack" && s.OwnerType == "equip");
                        if (bpSlot != null)
                        {
                            string bpStash   = $"backpack_slot_{bpSlot.Id}";
                            string bpLegacy  = $"backpack_{session.SteamHex}";
                            uint   bpSlots2  = bpSlot.ItemId == "duffel_bag" ? 30u : 20u;
                            float  bpWt      = bpSlot.ItemId == "duffel_bag" ? 50f : 30f;
                            string bpLbl     = bpSlot.ItemId == "duffel_bag" ? "DUFFEL BAG" : "BACKPACK";
                            try { _db.Reducers.CreateStash(bpStash, "backpack", bpLbl, bpSlots2, bpWt, ownerId, 0f, 0f, 0f); } catch { }
                            var bpSlotList = allSlots
                                .Where(s => (s.OwnerId == bpStash || s.OwnerId == bpLegacy) && s.OwnerType == "stash")
                                .Select(s => (object)new { id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType, item_id = s.ItemId, quantity = s.Quantity, metadata = s.Metadata, slot_index = s.SlotIndex })
                                .ToList();
                            backpackData = new { stash_id = bpStash, label = bpLbl, max_weight = bpWt, max_slots = (int)bpSlots2, slots = bpSlotList };
                        }

                        var defs = _db.Db.ItemDefinition.Iter()
                            .ToDictionary(d => d.ItemId, d => (object)new { item_id = d.ItemId, label = d.Label, weight = d.Weight, stackable = d.Stackable, usable = d.Usable, max_stack = d.MaxStack, category = d.Category, prop_model = d.PropModel, mag_capacity = d.MagCapacity, stored_capacity = d.StoredCapacity, ammo_type = d.AmmoType });

                        Console.WriteLine($"[Inv] server_id={serverId} owner_id={ownerId} slots={playerSlots.Count} equip={equippedSlots.Count}");
                        await WriteJson(ctx, new { server_id = serverId, owner_id = ownerId, steam_hex = session.SteamHex, slots = playerSlots, equipped_slots = equippedSlots, backpack_data = backpackData, item_defs = defs, max_weight = 85 });

                        // ACK triggers starter kit for brand-new characters
                        _db.Reducers.SessionInventoryAck(session.SteamHex);
                        return;
                    }

                    // ── VEHICLE INVENTORY ─────────────────────────────────────

                    case "create_vehicle_inventory":
                        _db.Reducers.CreateVehicleInventory(
                            args.GetProperty("plate").GetString()          ?? "",
                            (uint)args.GetProperty("model_hash").GetInt32(),
                            args.GetProperty("trunk_type").GetString()     ?? "rear",
                            args.GetProperty("trunk_slots").GetUInt32(),
                            (float)args.GetProperty("trunk_max_weight").GetDouble());
                        break;

                    case "get_vehicle_inventory":
                    {
                        string plate   = args.GetProperty("plate").GetString()          ?? "";
                        string invType = args.GetProperty("inventory_type").GetString() ?? "glovebox";
                        var    config  = _db.Db.VehicleInventory.Iter().FirstOrDefault(v => v.Plate == plate);
                        bool   hasCfg  = config != null;
                        float  maxWt   = invType == "trunk" ? (hasCfg ? config!.TrunkMaxWeight : 50f) : 10f;
                        uint   maxSl   = invType == "trunk" ? (hasCfg ? config!.TrunkSlots : 20u)     : 5u;
                        string ownerTy = invType == "trunk" ? "vehicle_trunk" : "vehicle_glovebox";
                        var    vSlots  = _db.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == plate && s.OwnerType == ownerTy)
                            .Select(s => (object)new { id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType, item_id = s.ItemId, quantity = s.Quantity, metadata = s.Metadata, slot_index = s.SlotIndex })
                            .ToList();
                        var vDefs = _db.Db.ItemDefinition.Iter()
                            .ToDictionary(d => d.ItemId, d => (object)new { item_id = d.ItemId, label = d.Label, weight = d.Weight, stackable = d.Stackable, usable = d.Usable, max_stack = d.MaxStack, category = d.Category, prop_model = d.PropModel, mag_capacity = d.MagCapacity, stored_capacity = d.StoredCapacity, ammo_type = d.AmmoType });
                        await WriteJson(ctx, new { plate, inventory_type = invType, trunk_type = hasCfg ? config!.TrunkType : "none", slots = vSlots, item_defs = vDefs, max_weight = maxWt, max_slots = maxSl });
                        return;
                    }

                    // ── STASHES ───────────────────────────────────────────────

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
                        string spId  = args.GetProperty("stash_id").GetString() ?? "";
                        var    spDef = _db.Db.StashDefinition.Iter().FirstOrDefault(s => s.StashId == spId);
                        await WriteJson(ctx, spDef != null
                            ? new { pos_x = spDef.PosX, pos_y = spDef.PosY, pos_z = spDef.PosZ }
                            : new { pos_x = 0f, pos_y = 0f, pos_z = 0f });
                        return;
                    }

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
                        var allSlots = _db.Db.InventorySlot.Iter().ToList();
                        var bpSlotList = allSlots
                            .Where(s => (s.OwnerId == bpStash || s.OwnerId == $"backpack_{bpOwner}") && s.OwnerType == "stash")
                            .Select(s => (object)new { id = s.Id, owner_id = s.OwnerId, owner_type = s.OwnerType, item_id = s.ItemId, quantity = s.Quantity, metadata = s.Metadata, slot_index = s.SlotIndex })
                            .ToList();
                        var bpDefs = _db.Db.ItemDefinition.Iter()
                            .ToDictionary(d => d.ItemId, d => (object)new { item_id = d.ItemId, label = d.Label, weight = d.Weight, stackable = d.Stackable, usable = d.Usable, max_stack = d.MaxStack, category = d.Category });
                        await WriteJson(ctx, new { stash_id = bpStash, label = bpLbl, max_weight = bpWt, max_slots = (int)bpSlots, slots = bpSlotList, item_defs = bpDefs });
                        return;
                    }

                    case "drop_item_to_ground":
                    {
                        ulong dropId  = args.GetProperty("slot_id").GetUInt64();
                        uint  dropQty = args.TryGetProperty("quantity", out var dq) ? dq.GetUInt32() : 0;
                        float dx = (float)args.GetProperty("x").GetDouble();
                        float dy = (float)args.GetProperty("y").GetDouble();
                        float dz = (float)args.GetProperty("z").GetDouble();
                        var preDrop = _db.Db.InventorySlot.Iter().FirstOrDefault(s => s.Id == dropId);
                        if (preDrop == null) { await WriteJson(ctx, new { ok = false, error = "slot not found" }); return; }
                        try { _db.Reducers.DropItemToGround(dropId, dropQty, dx, dy, dz); }
                        catch (Exception ex) { await WriteJson(ctx, new { ok = false, error = ex.Message }); return; }
                        await Task.Delay(200);
                        float rSq = 25f;
                        var stash = _db.Db.StashDefinition.Iter()
                            .Where(s => s.StashType == "ground")
                            .Where(s => { float ex2 = s.PosX - dx, ey = s.PosY - dy; return ex2*ex2 + ey*ey <= rSq; })
                            .OrderBy(s => { float ex2 = s.PosX - dx, ey = s.PosY - dy; return ex2*ex2 + ey*ey; })
                            .FirstOrDefault();
                        if (stash == null) { await WriteJson(ctx, new { ok = false, error = "ground stash not found after drop" }); return; }
                        var newSlot = _db.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == stash.StashId && s.OwnerType == "stash" && s.ItemId == preDrop.ItemId)
                            .FirstOrDefault();
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

                    case "reset_player_inventory":
                    {
                        string resetHex = "";
                        if (args.TryGetProperty("steam_hex", out var shEl2))
                            resetHex = shEl2.GetString() ?? "";
                        else if (args.TryGetProperty("server_id", out var sidEl2))
                        {
                            uint resetSid = sidEl2.GetUInt32();
                            resetHex = ResolveSession(resetSid)?.SteamHex ?? "";
                            if (string.IsNullOrEmpty(resetHex))
                            { await WriteJson(ctx, new { ok = false, error = $"no session for server_id={resetSid}" }); return; }
                        }
                        if (string.IsNullOrEmpty(resetHex))
                        { await WriteJson(ctx, new { ok = false, error = "steam_hex or server_id required" }); return; }

                        // Resolve active character_id for this account
                        var activeSession = _db.Db.CharSession.Iter().FirstOrDefault(s => s.SteamHex == resetHex);
                        if (activeSession == null)
                        { await WriteJson(ctx, new { ok = false, error = "player has no active session" }); return; }
                        string ownerId = CharOwnerString(activeSession.CharacterId);

                        var slotsToRemove = _db.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId == ownerId && s.OwnerType == "player").ToList();
                        var equipToRemove = _db.Db.InventorySlot.Iter()
                            .Where(s => s.OwnerId.StartsWith(ownerId + "_equip_") && s.OwnerType == "equip").ToList();

                        int removedCount = 0;
                        foreach (var slot in slotsToRemove.Concat(equipToRemove))
                        {
                            try { _db.Reducers.RemoveItem(slot.OwnerId, slot.ItemId, slot.Quantity); removedCount++; }
                            catch (Exception ex) { Console.WriteLine($"[Sidecar] reset: RemoveItem slot {slot.Id} failed: {ex.Message}"); }
                        }

                        var starterKit = new (string itemId, uint qty)[]
                        {
                            ("phone",1),("id_card",1),("water_bottle",2),("food_burger",1),
                            ("bandage",5),("cash",500),("backpack",1),("weapon_pistol",1),
                            ("ammo_pistol",50),("parachute",1),("body_armour",1),
                        };
                        int givenCount = 0;
                        foreach (var (itemId, qty) in starterKit)
                        {
                            try
                            {
                                var def = _db.Db.ItemDefinition.Iter().FirstOrDefault(d => d.ItemId == itemId);
                                if (def == null) continue;
                                string meta = "{}";
                                if (def.Category == "weapon")
                                {
                                    var serial = $"WPN-{Guid.NewGuid().ToString("N")[..8].ToUpper()}";
                                    meta = JsonSerializer.Serialize(new { serial, mag_ammo = 0, stored_ammo = 0, mag_capacity = def.MagCapacity, stored_capacity = def.StoredCapacity, durability = 100, ammo_type = def.AmmoType });
                                }
                                _db.Reducers.AddItem(ownerId, "player", itemId, qty, meta);
                                givenCount++;
                            }
                            catch (Exception ex) { Console.WriteLine($"[Sidecar] reset: AddItem {itemId} failed: {ex.Message}"); }
                        }
                        await WriteJson(ctx, new { ok = true, steam_hex = resetHex, owner_id = ownerId, removed = removedCount, given = givenCount });
                        return;
                    }

                    case "allocate_opcode":
                    {
                        var steamHex = args.TryGetProperty("steam_hex", out var sh) ? sh.GetString() ?? "" : "";
                        if (string.IsNullOrEmpty(steamHex) && args.TryGetProperty("server_id", out var sidEl2))
                            steamHex = ResolveSession(sidEl2.GetUInt32())?.SteamHex ?? "";

                        uint   netId      = args.TryGetProperty("net_id",      out var ni) ? ni.GetUInt32() : 0;
                        ulong  ttlSeconds = args.TryGetProperty("ttl_seconds", out var ts) ? ts.GetUInt64() : 3600;
                        string label      = args.TryGetProperty("context",     out var cl) ? cl.GetString() ?? "unnamed" : "unnamed";

                        string context = ttlSeconds == 0
                            ? label
                            : $"{Guid.NewGuid().ToString("N")[..12]}:{label}";

                        if (ttlSeconds == 0)
                        {
                            var cached = _dynamicOpcodes.FirstOrDefault(kv => kv.Value.Context == context);
                            if (cached.Value != null)
                            {
                                await WriteJson(ctx, new
                                {
                                    ok                 = true,
                                    opcode             = cached.Key,
                                    context            = context,
                                    permanent          = true,
                                    expires_in_seconds = 0UL,
                                });
                                return;
                            }
                        }

                        var tcs = new TaskCompletionSource<ushort>(TaskCreationOptions.RunContinuationsAsynchronously);
                        _pendingAllocations[context] = tcs;

                        try
                        {
                            _db!.Reducers.AllocateOpcode(context, steamHex, netId, ttlSeconds);
                        }
                        catch (Exception ex)
                        {
                            _pendingAllocations.TryRemove(context, out _);
                            await WriteJson(ctx, new { ok = false, error = ex.Message });
                            return;
                        }

                        var winner = await Task.WhenAny(tcs.Task, Task.Delay(2000));
                        if (winner == tcs.Task && tcs.Task.IsCompleted)
                        {
                            await WriteJson(ctx, new
                            {
                                ok                 = true,
                                opcode             = tcs.Task.Result,
                                context,
                                permanent          = ttlSeconds == 0,
                                expires_in_seconds = ttlSeconds,
                            });
                        }
                        else
                        {

                            var existing = _dynamicOpcodes.FirstOrDefault(kv => kv.Value.Context == context);
                            _pendingAllocations.TryRemove(context, out _);
                            if (existing.Value != null)
                            {
                                await WriteJson(ctx, new
                                {
                                    ok                 = true,
                                    opcode             = existing.Key,
                                    context,
                                    permanent          = ttlSeconds == 0,
                                    expires_in_seconds = ttlSeconds,
                                });
                            }
                            else
                            {
                                await WriteJson(ctx, new { ok = false, error = "allocation_timeout" });
                            }
                        }
                        return;
                    }

                    case "consume_opcode":
                    {
                        var rawOpcode = (ushort)args.GetProperty("opcode").GetUInt16();
                        if (!ValidateDynamicOpcode(rawOpcode, out _))
                        {
                            await WriteJson(ctx, new { ok = false, error = "OPCODE_INVALID_OR_EXPIRED" });
                            return;
                        }
                        try
                        {
                            _db!.Reducers.ConsumeOpcode(rawOpcode);
                            await WriteJson(ctx, new { ok = true });
                        }
                        catch (Exception ex)
                        {
                            await WriteJson(ctx, new { ok = false, error = ex.Message });
                        }
                        return;
                    }

                    case "release_opcode":
                    {
                        var rawOpcode = (ushort)args.GetProperty("opcode").GetUInt16();
                        _db!.Reducers.ReleaseOpcode(rawOpcode);
                        await WriteJson(ctx, new { ok = true });
                        return;
                    }

                    case "deregister_opcode":
                    {
                        var label2 = args.GetProperty("label").GetString() ?? "";
                        _db!.Reducers.DeregisterOpcode(label2);
                        await WriteJson(ctx, new { ok = true });
                        return;
                    }

                    default:
                        Console.WriteLine($"[Sidecar] Unknown reducer: {name}");
                        ctx.Response.StatusCode = 400; ctx.Response.Close(); return;
                }

                ctx.Response.StatusCode = 200; ctx.Response.Close();
                return;
            }

            // ── GET /validate-opcode
            if (ctx.Request.HttpMethod == "GET" && path == "/validate-opcode")
            {
                var qs = System.Web.HttpUtility.ParseQueryString(ctx.Request.Url?.Query ?? "");
                if (!ushort.TryParse(qs["opcode"], out var op))
                { ctx.Response.StatusCode = 400; ctx.Response.Close(); return; }
                var valid = ValidateDynamicOpcode(op, out var entry);
                await WriteJson(ctx, new
                {
                    valid,
                    opcode    = op,
                    context   = entry?.Context,
                    owner     = entry?.OwnerSteamHex,
                    net_id    = entry?.NetId,
                    permanent = entry?.ExpiresAtMicros == ulong.MaxValue,
                });
                return;
            }

            if (ctx.Request.HttpMethod == "POST" && path == "/modules/register")
        {
            using var sr = new System.IO.StreamReader(ctx.Request.InputStream);
            string body  = await sr.ReadToEndAsync();
            try
            {
                using var doc    = JsonDocument.Parse(body);
                var r            = doc.RootElement;
                string name      = r.GetProperty("name").GetString()           ?? "";
                string wasmPath  = r.GetProperty("wasm_path").GetString()      ?? "";
                string resource  = r.GetProperty("resource_name").GetString()  ?? "";
                string database  = r.TryGetProperty("database", out var dbEl)  ? dbEl.GetString()  ?? "fivem-game" : "fivem-game";
                string version   = r.TryGetProperty("version",  out var verEl) ? verEl.GetString() ?? "0.0.0"      : "0.0.0";
                string[] tables = r.TryGetProperty("tables", out var tablesEl)
                    ? tablesEl.EnumerateArray()
                            .Select(t => t.GetString() ?? "")
                            .Where(t => t != "")
                            .ToArray()
                    : Array.Empty<string>();

                if (string.IsNullOrEmpty(name) || string.IsNullOrEmpty(wasmPath))
                {
                    await WriteJson(ctx, new { ok = false, error = "name and wasm_path are required" });
                    return;
                }

                // ── Validate WASM on disk ─────────────────────────────────────────────
                if (!File.Exists(wasmPath))
                {
                    Console.WriteLine($"[Modules] MISSING WASM: module='{name}' resource='{resource}'");
                    Console.WriteLine($"[Modules]   Expected : {wasmPath}");
                    Console.WriteLine($"[Modules]   Fix      : Run your Rust build (`cargo build --release`) before starting the server.");
                    await WriteJson(ctx, new {
                        ok        = false,
                        error     = "wasm_not_found",
                        message   = $"WASM file not found. Run your build step before starting the server. Expected: {wasmPath}",
                        wasm_path = wasmPath,
                        resource,
                    });
                    return;
                }

                var module = new RegisteredModule(
                    name, wasmPath, resource, tables, database, version, DateTime.UtcNow);
                _moduleRegistry[name] = module;

                Console.WriteLine($"[Modules] ✓ Registered: '{name}' from '{resource}'");
                Console.WriteLine($"[Modules]   WASM    : {wasmPath}");
                Console.WriteLine($"[Modules]   Tables  : {(tables.Length > 0 ? string.Join(", ", tables) : "(none declared)")}");
                Console.WriteLine($"[Modules]   DB      : {database}  Version: {version}");

                await WriteJson(ctx, new {
                    ok             = true,
                    name,
                    resource,
                    tables,
                    database,
                    registered_at  = module.RegisteredAt.ToString("o"),
                });
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[Modules] /modules/register error: {ex.Message}");
                await WriteJson(ctx, new { ok = false, error = ex.Message });
            }
            return;
        }

        // ── GET /modules ──────────────────────────────────────────────────────────────
        if (ctx.Request.HttpMethod == "GET" && path == "/modules")
        {
            var snapshot = _moduleRegistry.Values.Select(m => (object)new {
                name          = m.Name,
                resource      = m.ResourceName,
                wasm_path     = m.WasmPath,
                tables        = m.Tables,
                database      = m.Database,
                version       = m.Version,
                registered_at = m.RegisteredAt.ToString("o"),
            }).ToList();
            await WriteJson(ctx, snapshot);
            return;
        }

            ctx.Response.StatusCode = 404; ctx.Response.Close();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[Sidecar] Request error: {ex.Message}");
            try { ctx.Response.StatusCode = 500; ctx.Response.Close(); } catch { }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CLI + IDENTITY HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    /// Spawns an external process and captures stdout + stderr on concurrent
    /// tasks. Never read either stream synchronously while the other may fill
    /// its OS pipe buffer — that is the classic redirect deadlock.
    static async Task<(int ExitCode, string Stdout, string Stderr)> RunProcessAsync(
        string fileName, string arguments, TimeSpan timeout)
    {
        using var proc = new System.Diagnostics.Process
        {
            StartInfo = new System.Diagnostics.ProcessStartInfo
            {
                FileName               = fileName,
                Arguments              = arguments,
                RedirectStandardOutput = true,
                RedirectStandardError  = true,
                UseShellExecute        = false,
                CreateNoWindow         = true,
                WorkingDirectory       = AppContext.BaseDirectory,
            }
        };

        try { proc.Start(); }
        catch (Exception ex)
        { return (-1, string.Empty, $"Failed to start '{fileName}': {ex.Message}"); }

        // Start both reads before waiting — the OS buffers are fixed-size and
        // will deadlock if one fills while we block synchronously on the other.
        var stdoutTask = proc.StandardOutput.ReadToEndAsync();
        var stderrTask = proc.StandardError.ReadToEndAsync();

        using var cts = new CancellationTokenSource(timeout);
        try
        {
            await proc.WaitForExitAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            try { proc.Kill(entireProcessTree: true); } catch { }
            return (-1, string.Empty, "Process timed out");
        }

        await Task.WhenAll(stdoutTask, stderrTask);
        return (proc.ExitCode, stdoutTask.Result, stderrTask.Result);
    }

    static async Task CheckCliAvailableAsync()
    {
        var (exit, stdout, _) = await RunProcessAsync(
            "spacetime", "--version", TimeSpan.FromSeconds(3));

        if (exit == 0 && !string.IsNullOrWhiteSpace(stdout))
        {
            _cliAvailable = true;
            Console.WriteLine($"[HyprFM AutoPublisher] spacetime CLI ready: {stdout.Trim()}");
        }
        else
        {
            _cliAvailable = false;
            Console.WriteLine("[HyprFM AutoPublisher] WARNING: spacetime CLI not found on PATH — auto-publish disabled");
            Console.WriteLine("[HyprFM AutoPublisher]   Install: https://spacetimedb.com/install");
        }
    }

    static async Task LoadSpacetimeIdentityAsync()
    {
        // Fast path: reuse STDB_TOKEN already present in the environment.
        // This is the same token passed to DbConnection in Main(), so no
        // subprocess is needed on a correctly configured server.
        var envToken = Environment.GetEnvironmentVariable("STDB_TOKEN");
        if (!string.IsNullOrEmpty(envToken))
        {
            _spacetimeIdentity = envToken;
            Console.WriteLine("[HyprFM Identity] Loaded identity from STDB_TOKEN env var.");
            return;
        }

        if (!_cliAvailable) return;

        // Slow path: ask the CLI. --json available in spacetime CLI 0.12+.
        var (exit, stdout, _) = await RunProcessAsync(
            "spacetime", "identity list --json", TimeSpan.FromSeconds(5));

        if (exit != 0 || string.IsNullOrWhiteSpace(stdout))
        {
            Console.WriteLine("[HyprFM Identity] WARNING: no identity found — auto-publish disabled");
            Console.WriteLine("[HyprFM Identity]   Run: spacetime identity new");
            return;
        }

        try
        {
            using var doc  = JsonDocument.Parse(stdout.Trim());
            var root       = doc.RootElement;
            var first = root.ValueKind == JsonValueKind.Array
                ? (root.GetArrayLength() > 0 ? (JsonElement?)root[0] : null)
                : (JsonElement?)root;

            if (first is null)
            {
                Console.WriteLine("[HyprFM Identity] WARNING: identity list is empty — auto-publish disabled");
                return;
            }

            string? token = null;
            foreach (var field in new[] { "token", "identity_token", "auth_token", "credential" })
            {
                if (first.Value.TryGetProperty(field, out var el) &&
                    el.ValueKind == JsonValueKind.String)
                { token = el.GetString(); break; }
            }

            _spacetimeIdentity = token;
            if (string.IsNullOrEmpty(_spacetimeIdentity))
            {
                Console.WriteLine("[HyprFM Identity] WARNING: no token field found — auto-publish disabled");
                return;
            }

            var shortId = _spacetimeIdentity.Length > 12
                ? _spacetimeIdentity[..8] + "..."
                : "****";
            Console.WriteLine($"[HyprFM Identity] Loaded identity: {shortId}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[HyprFM Identity] WARNING: failed to parse identity ({ex.Message}) — auto-publish disabled");
        }
    }

    static async Task WriteJson(HttpListenerContext ctx, object data)
    {
        var json  = JsonSerializer.Serialize(data);
        var bytes = Encoding.UTF8.GetBytes(json);
        ctx.Response.ContentType = "application/json";
        // Only default to 200 when the caller hasn't already set a status code
        // (e.g. /health sets 503 before calling WriteJson).
        if (ctx.Response.StatusCode == 200 || ctx.Response.StatusCode == 0)
            ctx.Response.StatusCode = 200;
        ctx.Response.Headers["X-HyprFM-Version"] = API_VERSION;
        await ctx.Response.OutputStream.WriteAsync(bytes);
        ctx.Response.Close();
    }
}