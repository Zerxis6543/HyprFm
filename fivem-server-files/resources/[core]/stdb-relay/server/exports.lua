local SIDECAR_URL = "http://127.0.0.1:27200/"

-- ═════════════════════════════════════════════════════════════════════════════
-- BRIDGE 1: Commit — Zero-Trust Sovereign Path
-- ═════════════════════════════════════════════════════════════════════════════

--- Trigger a SpacetimeDB reducer via the C# sidecar.
--- All game state mutations MUST use this — never write state in Lua.
---
--- @param reducerName  string         Snake_case reducer name ("give_item_to_player")
--- @param args         table          Named argument table matching the reducer
--- @param cb           function|nil   cb(success: bool, result: table|nil)

local _hooks = { before = {}, after = {} }

local function _fireHooks(phase, name, args, result)
    local handlers = _hooks[phase] and _hooks[phase][name]
    if not handlers then return end
    for _, fn in ipairs(handlers) do
        local ok, err = pcall(fn, name, args, result)
        if not ok then
            print(("[hyprfm] OnReducer %s hook error '%s': %s"):format(phase, name, tostring(err)))
        end
    end
end

exports("RegisterItem", function(def)
    if type(def) ~= "table" or not def.item_id or not def.label then
        print("[hyprfm] RegisterItem: def must include item_id (string) and label (string)"); return
    end
    PerformHttpRequest(SIDECAR_URL .. "seed-item",
        function(status, _, _)
            if status ~= 200 then
                print(("[hyprfm] RegisterItem: failed to register '%s' — sidecar returned HTTP %d"):format(
                    tostring(def.item_id), status or 0))
            end
        end,
        "POST",
        json.encode({
            item_id         = def.item_id,
            label           = def.label,
            weight          = def.weight          or 0.1,
            stackable       = def.stackable        or false,
            usable          = def.usable           or false,
            max_stack       = def.max_stack        or 1,
            category        = def.category         or "misc",
            prop_model      = def.prop_model       or "prop_cs_cardbox_01",
            mag_capacity    = def.mag_capacity     or 0,
            stored_capacity = def.stored_capacity  or 0,
            ammo_type       = def.ammo_type        or "",
        }),
        { ["Content-Type"] = "application/json" }
    )
end)

exports("GetAPIVersion", function(cb)
    PerformHttpRequest(SIDECAR_URL .. "version",
        function(status, body, _)
            if status ~= 200 or not body then
                if cb then cb(nil, "sidecar unreachable") end; return
            end
            local ok, data = pcall(json.decode, body)
            if cb then cb(ok and data or nil, ok and nil or "parse error") end
        end,
        "GET", "", {}
    )
end)

exports("Commit", function(reducerName, args, cb)
    -- Guard: catch bad calls immediately with a descriptive error
    if type(reducerName) ~= "string" or #reducerName == 0 then
        local result = { ok = false, error_code = "BAD_CALL", message = "reducerName must be a non-empty string" }
        if cb then cb(false, result) end
        return
    end

    _fireHooks("before", reducerName, args or {}, nil)

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            -- HTTP-level failure (sidecar down, wrong port, etc.)
            if status ~= 200 then
                local result = {
                    ok         = false,
                    error_code = "HTTP_ERROR",
                    message    = ("sidecar returned HTTP %d for reducer '%s'"):format(status or 0, reducerName),
                }
                if cb then cb(false, result) end
                return
            end

            -- Parse the body
            local parseOk, parsed = pcall(json.decode, body or "")
            if not parseOk or type(parsed) ~= "table" then
                local result = {
                    ok         = false,
                    error_code = "PARSE_ERROR",
                    message    = ("sidecar returned non-JSON for reducer '%s'"):format(reducerName),
                }
                if cb then cb(false, result) end
                return
            end

            -- Reducers that return no body (e.g. move_item) have no ok field — treat as success
            if parsed.ok == nil then parsed.ok = true end

            -- success = true ONLY when the reducer logic itself confirmed success
            _fireHooks("after", reducerName, args or {}, parsed)
            if cb then cb(parsed.ok == true, parsed) end
        end,
        "POST",
        json.encode({ name = reducerName, args = args or {} }),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ═════════════════════════════════════════════════════════════════════════════
-- BRIDGE 2: InvokeNative — Volatile Express Path
-- ═════════════════════════════════════════════════════════════════════════════

--- Insert a volatile instruction directly into the poll loop's queue.
--- Processed at the next 100ms tick with ZERO HTTP round-trips.
--- Cosmetic / one-shot only. Not stored in SpacetimeDB. Not replayed.
---
--- @param opcode  integer   u16 opcode constant from constants.lua (Opcode.*)
--- @param netId   integer   GTA NetworkId of the target entity
--- @param args    table     Positional argument array for the opcode's payload schema
--- @return boolean          true if enqueued, false if validation failed
---
--- Example:
---   exports['stdb-relay']:InvokeNative(Opcode.Effect.Heal,            playerNetId, { 40 })
---   exports['stdb-relay']:InvokeNative(Opcode.Engine.CallLocalNative,  playerNetId,
---       { "PLAY_SOUND_FRONTEND", -1, "Beep_Red", "DLC_HEIST_HACKING_SNAKE_SOUNDS" })
exports("InvokeNative", function(opcode, netId, args)
    -- Guard: must be an integer in the u16 range
    if type(opcode) ~= "number" or opcode < 0 or opcode > 0xFFFF
       or math.floor(opcode) ~= opcode then
        print(("[hyprfm] InvokeNative: invalid opcode '%s'"):format(tostring(opcode)))
        return false
    end

    -- Guard: only recognised domains are accepted
    local domain = opcode & 0xF000
    if domain ~= 0x9000 and domain ~= 0x1000 and domain ~= 0x2000 then
        print(("[hyprfm] InvokeNative: opcode 0x%04X has an unrecognised domain"):format(opcode))
        return false
    end

    -- Append to the module-level volatile queue defined in main.lua.
    -- The poll loop drains this before the HTTP fetch on each 100ms tick.
    _volatileQueue[#_volatileQueue + 1] = {
        target_entity_net_id = netId,
        opcode               = opcode,
        payload              = json.encode(args or {}),
    }
    return true
end)

-- ═════════════════════════════════════════════════════════════════════════════
-- CONVENIENCE WRAPPERS  (thin facades — community dev "golden path")
-- ═════════════════════════════════════════════════════════════════════════════

--- Give an item to a connected player's inventory.
--- Internally calls give_item_to_identity via the sidecar's server_id lookup.
--- Weight limit errors are surfaced through the callback.
---
--- @param serverId  number
--- @param itemId    string   e.g. "weapon_pistol"
--- @param quantity  number
--- @param cb        function|nil  cb(success: bool, errorCode: string|nil)
exports("AddItemToPlayer", function(serverId, itemId, quantity, cb)
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            local success, result = false, nil
            if status == 200 and body then
                local ok, parsed = pcall(json.decode, body)
                if ok then success = (parsed.ok ~= false); result = parsed end
            end
            if cb then cb(success, result and result.error_code) end
        end,
        "POST",
        json.encode({ name = "give_item_to_player", args = {
            server_id = serverId,
            item_id   = itemId,
            quantity  = quantity,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

--- Remove an item from a connected player's inventory.
--- Resolves identity hex locally from the _identityToServerId map.
---
--- @param serverId  number
--- @param itemId    string
--- @param quantity  number
--- @param cb        function|nil  cb(success: bool)
exports("RemoveItemFromPlayer", function(serverId, itemId, quantity, cb)
    -- Phase 1: resolve the player's identity hex via the sidecar.
    -- This works even if the player has never opened their inventory,
    -- because it uses the ActiveSession table not the local _identityToServerId map.
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(pi_status, pi_body, _)
            if pi_status ~= 200 or not pi_body then
                print(("[hyprfm] RemoveItemFromPlayer: sidecar unreachable for server_id=%d"):format(serverId))
                if cb then cb(false, { ok = false, error_code = "SIDECAR_UNREACHABLE" }) end
                return
            end
            local pi_ok, pi = pcall(json.decode, pi_body)
            if not pi_ok or not pi or not pi.owner_id or pi.owner_id == "" then
                print(("[hyprfm] RemoveItemFromPlayer: no active session for server_id=%d. Is the player connected?"):format(serverId))
                if cb then cb(false, { ok = false, error_code = "PLAYER_NOT_ONLINE",
                    message = ("No active session for server_id=%d"):format(serverId) }) end
                return
            end

            -- Cache identity for future calls in this session
            _identityToServerId[pi.owner_id] = serverId

            -- Phase 2: remove the item using the resolved identity
            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function(rm_status, rm_body, _)
                    local rm_ok, rm_result = pcall(json.decode, rm_body or "")
                    if cb then cb(rm_status == 200, rm_ok and rm_result or { ok = rm_status == 200 }) end
                end,
                "POST",
                json.encode({ name = "remove_item", args = {
                    owner_id = pi.owner_id,
                    item_id  = itemId,
                    quantity = quantity,
                }}),
                { ["Content-Type"] = "application/json" }
            )
        end,
        "POST",
        json.encode({ name = "get_player_inventory", args = { server_id = serverId } }),
        { ["Content-Type"] = "application/json" }
    )
end)

--- Check if a player currently has at least `quantity` of an item.
---
--- @param serverId  number
--- @param itemId    string
--- @param quantity  number   Minimum required amount
--- @param cb        function  cb(hasItem: bool, actualCount: number)
exports("HasItem", function(serverId, itemId, quantity, cb)
    -- Resolve identity hex — use cache if available, otherwise look it up
    local identityHex = ""
    for identity, sid in pairs(_identityToServerId) do
        if sid == serverId then identityHex = identity; break end
    end

    local function doCheck(hex)
        PerformHttpRequest(
            ("%sitem-count?owner_id=%s&item_id=%s"):format(SIDECAR_URL, hex, itemId),
            function(status, body, _)
                if status ~= 200 or not body then
                    if cb then cb(false, 0) end; return
                end
                local ok, result = pcall(json.decode, body)
                if not ok or not result then
                    if cb then cb(false, 0) end; return
                end
                if cb then cb(result.count >= (quantity or 1), result.count) end
            end,
            "GET", "", {}
        )
    end

    if identityHex ~= "" then
        doCheck(identityHex)
    else
        -- Identity not yet cached — resolve via session lookup first
        PerformHttpRequest(SIDECAR_URL .. "reducer",
            function(status, body, _)
                if status ~= 200 or not body then if cb then cb(false, 0) end; return end
                local ok, pi = pcall(json.decode, body)
                if not ok or not pi or not pi.owner_id or pi.owner_id == "" then
                    if cb then cb(false, 0) end; return
                end
                _identityToServerId[pi.owner_id] = serverId
                doCheck(pi.owner_id)
            end,
            "POST",
            json.encode({ name = "get_player_inventory", args = { server_id = serverId } }),
            { ["Content-Type"] = "application/json" }
        )
    end
end)

--- @param stashId   string   Unique stash identifier
--- @param label     string   Display label shown in NUI
--- @param maxSlots  number
--- @param maxWeight number   kg
--- @param x         number   World position
--- @param y         number
--- @param z         number
exports("RegisterStash", function(stashId, label, maxSlots, maxWeight, x, y, z)
    PerformHttpRequest(SIDECAR_URL .. "reducer", function() end, "POST",
        json.encode({ name = "create_stash", args = {
            stash_id   = stashId,    stash_type = "world",
            label      = label,      max_slots  = maxSlots,
            max_weight = maxWeight,  owner_id   = "",
            pos_x      = x,          pos_y      = y,         pos_z = z,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ── OPCODE REGISTRATION ───────────────────────────────────────────────────────
exports("RegisterOpcode", function(label, handler, cb)
    if not _syncReady then
        table.insert(_pendingRegistrations, { label = label, handler = handler, cb = cb })
        return
    end

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then
                print(("[hyprfm] RegisterOpcode: sidecar unreachable for label '%s'"):format(label))
                return
            end
            local ok, data = pcall(json.decode, body)
            if not ok or not data or not data.ok then
                print(("[hyprfm] RegisterOpcode: allocation failed for '%s': %s"):format(
                    label, (ok and data and data.error) or "unknown"))
                return
            end

            local opcode = data.opcode

            -- Wire into the live Dispatcher — the poll loop routes here immediately
            Dispatcher[opcode] = function(netId, args)
                local ok2, err = pcall(handler, netId, args)
                if not ok2 then
                    print(("[hyprfm] RegisterOpcode handler error [%s / 0x%04X]: %s"):format(
                        label, opcode, tostring(err)))
                end
            end

            print(("[hyprfm] RegisterOpcode: '%s' → 0x%04X"):format(label, opcode))
            if cb then cb(opcode) end
        end,
        "POST",
        json.encode({ name = "allocate_opcode", args = {
            context     = label,   -- label is the context; Rust idempotency guards duplicates
            steam_hex   = "",      -- server-owned, not player-bound
            net_id      = 0,
            ttl_seconds = 0,       -- permanent — Reaper skips u64::MAX rows
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

-- Explicit deregistration — use when a resource is unloaded cleanly.
-- The Reaper never touches permanent rows, so this is the only way to free
-- a RegisterOpcode slot without restarting SpacetimeDB.
exports("DeregisterOpcode", function(label, cb)
    Dispatcher = Dispatcher or {}
    -- Remove from local Dispatcher (find by label via a reverse scan)
    -- We don't store label→opcode locally, so we let the sidecar/Rust handle it
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, _, _)
            if cb then cb(status == 200) end
        end,
        "POST",
        json.encode({ name = "deregister_opcode", args = { label = label } }),
        { ["Content-Type"] = "application/json" }
    )
end)