local SIDECAR_URL = "http://127.0.0.1:27200/"

--- ──────────────────────────────────────────────────────────────────────────
--- INVENTORY EXPORTS
--- ──────────────────────────────────────────────────────────────────────────

--- Add an item to a player's inventory.
--- @param serverId    number  FiveM server ID of the target player
--- @param itemId      string  Item definition ID (e.g. "weapon_pistol")
--- @param quantity    number  Amount to add
--- @param cb          function|nil  Optional callback: cb(success, errorCode)
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

--- Check if a player has a minimum quantity of an item.
--- This is a READ — it queries the sidecar, not the Rust state mirror.
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

--- ──────────────────────────────────────────────────────────────────────────
--- STASH EXPORTS (for job scripts, housing, etc.)
--- ──────────────────────────────────────────────────────────────────────────

--- Register a persistent stash in the world.
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

-- ── Usage example (how a Qbox job script would use this) ──────────────────
--
--  exports['stdb-relay']:AddItemToPlayer(source, 'handcuffs', 1, function(ok, err)
--      if ok then TriggerClientEvent('police:receivedHandcuffs', source)
--      else print('Inventory full or item unknown: ' .. tostring(err)) end
--  end)
--
--  exports['stdb-relay']:HasItem(source, 'lockpick', 1, function(has)
--      if not has then return DropPlayer(source, 'Missing item') end
--  end)