-- ─────────────────────────────────────────────────────────────────────────────
-- HyprFM Public API — The "Golden Path" for third-party resource developers.
--
-- LOADED AFTER main.lua within the same resource (see fxmanifest.lua).
-- References _volatileQueue and _identityToServerId defined in main.lua.
--
-- Two bridges, one principle: the Lua relay NEVER decides state.
--
--  Commit(reducerName, args, cb)
--    State mutations — always routed through SpacetimeDB.
--    Every change is atomic, ordered, and auditable.
--
--  InvokeNative(opcode, netId, args)
--    Cosmetic effects only — zero HTTP cost, not persisted, not replayed.
--    NEVER use for health, inventory, money, or any game-state mutation.
-- ─────────────────────────────────────────────────────────────────────────────

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
exports("Commit", function(reducerName, args, cb)
    if type(reducerName) ~= "string" or #reducerName == 0 then
        print("[hyprfm] Commit: reducerName must be a non-empty string")
        if cb then cb(false, nil) end
        return
    end

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            local success = (status == 200)
            local result  = nil
            if success and body and body ~= "" then
                local ok, parsed = pcall(json.decode, body)
                if ok then result = parsed end
            end
            if cb then cb(success, result) end
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
    -- Resolve identity hex from the local map (populated on inventory open)
    local identityHex = ""
    for identity, sid in pairs(_identityToServerId) do
        if sid == serverId then identityHex = identity; break end
    end

    if identityHex == "" then
        print(("[hyprfm] RemoveItemFromPlayer: no identity mapping for server_id %d"):format(serverId))
        if cb then cb(false) end
        return
    end

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, _, _)
            if cb then cb(status == 200) end
        end,
        "POST",
        json.encode({ name = "remove_item", args = {
            owner_id = identityHex,
            item_id  = itemId,
            quantity = quantity,
        }}),
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
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then cb(false, 0); return end
            local ok, result = pcall(json.decode, body)
            if not ok or not result then cb(false, 0); return end
            local count = 0
            for _, slot in ipairs(result.slots or {}) do
                if slot.item_id == itemId then count = count + slot.quantity end
            end
            cb(count >= quantity, count)
        end,
        "POST",
        json.encode({ name = "get_player_inventory", args = { server_id = serverId } }),
        { ["Content-Type"] = "application/json" }
    )
end)

--- Register a persistent world stash. Idempotent — safe to call on restart.
--- The Rust reducer skips insertion if stash_id already exists.
---
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

-- ─────────────────────────────────────────────────────────────────────────────
-- USAGE SUMMARY FOR THIRD-PARTY RESOURCE DEVELOPERS:
--
--  State mutations (always Commit):
--    exports['stdb-relay']:Commit("give_item_to_player",
--        { server_id = src, item_id = "medkit", quantity = 1 },
--        function(ok, result) end)
--
--    exports['stdb-relay']:Commit("use_item",
--        { slot_id = slotId, net_id = netId })
--
--  Cosmetic / volatile (InvokeNative, ENGINE domain only):
--    exports['stdb-relay']:InvokeNative(Opcode.Effect.Heal, netId, { 40 })
--    exports['stdb-relay']:InvokeNative(Opcode.Engine.CallLocalNative, netId,
--        { "PLAY_SOUND_FRONTEND", -1, "Beep_Red", "DLC_HEIST_HACKING_SNAKE_SOUNDS" })
--
--  Convenience shortcuts:
--    exports['stdb-relay']:AddItemToPlayer(src, "lockpick", 1, cb)
--    exports['stdb-relay']:HasItem(src, "lockpick", 1, function(has, count) end)
-- ─────────────────────────────────────────────────────────────────────────────