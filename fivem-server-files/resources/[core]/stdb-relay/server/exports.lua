-- server/exports.lua
-- ── HyprFM Public API — The "Golden Path" for third-party developers ──────────
--
-- Two bridges, one principle: the Lua relay never decides state.
--
--  Commit(reducerName, args, cb)
--  ─────────────────────────────
--  Use for ANYTHING that changes game state.
--  Routes through the sidecar → SpacetimeDB → Rust reducer.
--  All state changes are atomic, ordered, and auditable.
--  This is the Zero-Trust Sovereign path.
--
--  InvokeNative(opcode, netId, args)
--  ──────────────────────────────────
--  Use for cosmetic effects that must NOT be persisted or replayed.
--  Inserts directly into the local volatile queue — zero HTTP round-trip.
--  This is the Volatile Express path.
--  Never use this for health, inventory, money, or any game-state mutation.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- _volatileQueue is defined in main.lua (same resource, shared Lua state).
-- Ensure main.lua is listed BEFORE exports.lua in fxmanifest.lua.
-- ─────────────────────────────────────────────────────────────────────────────

local SIDECAR_URL = "http://127.0.0.1:27200/"

-- ═════════════════════════════════════════════════════════════════════════════
-- BRIDGE 1: Commit — Zero-Trust Sovereign Path
-- All state mutations MUST go through this channel.
-- ═════════════════════════════════════════════════════════════════════════════

--- Trigger a Rust reducer via the SpacetimeDB sidecar.
--- All game state changes (give item, set job, heal, fine, etc.) use this.
---
--- @param reducerName string  Snake_case Rust reducer name (e.g. "give_item_to_player")
--- @param args        table   Named argument table matching the reducer's parameter list
--- @param cb          function|nil  Optional callback: cb(success: bool, result: table|nil)
---
--- Security: The sidecar validates reducer names and the Rust layer enforces
--- all ownership rules, weight limits, and permission checks.
--- A scripter CANNOT bypass these by calling Commit with bad args — Rust will reject.
exports("Commit", function(reducerName, args, cb)
    -- Guard: reducerName must be a non-empty string
    if type(reducerName) ~= "string" or #reducerName == 0 then
        print("[hyprfm] Commit: invalid reducerName — must be a non-empty string")
        if cb then cb(false, nil) end
        return
    end

    PerformHttpRequest(
        SIDECAR_URL .. "reducer",
        function(status, body, _)
            local success = status == 200
            local result  = nil
            if success and body and body ~= "" then
                local ok, parsed = pcall(json.decode, body)
                if ok then result = parsed end
            end
            -- Surface structured errors to the caller (e.g. WEIGHT_LIMIT)
            if cb then cb(success, result) end
        end,
        "POST",
        json.encode({ name = reducerName, args = args or {} }),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ═════════════════════════════════════════════════════════════════════════════
-- BRIDGE 2: InvokeNative — Volatile Express Path
-- Cosmetic effects only. Zero HTTP cost. Not persisted.
-- ═════════════════════════════════════════════════════════════════════════════

--- Insert a volatile instruction directly into the local dispatch queue.
--- Processed at the next 100ms poll tick with ZERO HTTP round-trips.
---
--- @param opcode  integer  u16 opcode from Opcode.* constants in constants.lua
--- @param netId   integer  GTA NetworkId of the target entity
--- @param args    table    Positional argument array (matches the opcode's payload schema)
--- @return boolean  true if enqueued, false if validation failed
---
--- Example:
---   exports['stdb-relay']:InvokeNative(Opcode.Effect.Heal, playerNetId, { 40 })
---   exports['stdb-relay']:InvokeNative(Opcode.Engine.CallLocalNative, playerNetId,
---       { "PLAY_SOUND_FRONTEND", -1, "Beep_Red", "DLC_HEIST_HACKING_SNAKE_SOUNDS" })
exports("InvokeNative", function(opcode, netId, args)
    -- Validate opcode range: must be a u16 integer
    if type(opcode) ~= "number" or opcode < 0 or opcode > 0xFFFF or math.floor(opcode) ~= opcode then
        print(("[hyprfm] InvokeNative: invalid opcode %s"):format(tostring(opcode)))
        return false
    end

    -- Safety guard: ENGINE domain only.
    -- Entity and Effect opcodes carry state significance and MUST go through
    -- Commit → SpacetimeDB to maintain the Sovereign State guarantee.
    -- If you need to apply a heal cosmetically (animation without state change),
    -- you still want the state recorded — use Commit("use_item", ...) instead.
    local domain = opcode & 0xF000
    if domain ~= 0x9000 and domain ~= 0x1000 and domain ~= 0x2000 then
        print(("[hyprfm] InvokeNative: unknown domain for opcode %s"):format(Opcode.Format(opcode)))
        return false
    end

    -- Enqueue into the volatile queue defined in main.lua.
    -- The poll loop drains this before the HTTP fetch each tick (Phase 1).
    _volatileQueue[#_volatileQueue + 1] = {
        target_entity_net_id = netId,
        opcode               = opcode,
        payload              = json.encode(args or {}),
    }
    return true
end)

-- ═════════════════════════════════════════════════════════════════════════════
-- LEGACY INVENTORY BRIDGES (unchanged, kept for community compatibility)
-- ═════════════════════════════════════════════════════════════════════════════

--- Add an item to a player's inventory.
--- @param serverId  number  FiveM server ID
--- @param itemId    string  Item definition ID (e.g. "weapon_pistol")
--- @param quantity  number
--- @param cb        function|nil  cb(success, errorCode)
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
            server_id = serverId, item_id = itemId, quantity = quantity
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

--- Remove an item from a player's inventory.
--- @param serverId  number
--- @param itemId    string
--- @param quantity  number
--- @param cb        function|nil  cb(success)
exports("RemoveItemFromPlayer", function(serverId, itemId, quantity, cb)
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if cb then cb(status == 200) end
        end,
        "POST",
        json.encode({ name = "remove_item_from_player", args = {
            server_id = serverId, item_id = itemId, quantity = quantity
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

--- Check if a player has at least `quantity` of an item.
--- @param serverId  number
--- @param itemId    string
--- @param quantity  number  Minimum required
--- @param cb        function  cb(hasItem: boolean, actualCount: number)
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

--- Register a persistent world stash.
--- Idempotent — safe to call on resource restart.
exports("RegisterStash", function(stashId, label, maxSlots, maxWeight, x, y, z)
    PerformHttpRequest(SIDECAR_URL .. "reducer", function() end, "POST",
        json.encode({ name = "create_stash", args = {
            stash_id = stashId, stash_type = "world",
            label = label, max_slots = maxSlots, max_weight = maxWeight,
            owner_id = "", pos_x = x, pos_y = y, pos_z = z,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- USAGE SUMMARY FOR THIRD-PARTY SCRIPTERS:
--
--  State-changing (use Commit):
--    exports['stdb-relay']:Commit("give_item_to_player", { server_id=src, item_id="medkit", quantity=1 })
--    exports['stdb-relay']:Commit("use_item", { slot_id=slotId, net_id=netId }, function(ok) end)
--
--  Cosmetic/volatile (use InvokeNative):
--    exports['stdb-relay']:InvokeNative(Opcode.Effect.Heal, netId, { 40 })
--    exports['stdb-relay']:InvokeNative(Opcode.Engine.CallLocalNative, netId, { "PLAY_SOUND_FRONTEND", -1, "Beep_Red", "" })
--
--  Shorthand wrappers (convenience):
--    exports['stdb-relay']:AddItemToPlayer(src, "weapon_pistol", 1, cb)
--    exports['stdb-relay']:HasItem(src, "lockpick", 1, function(has) end)
-- ─────────────────────────────────────────────────────────────────────────────