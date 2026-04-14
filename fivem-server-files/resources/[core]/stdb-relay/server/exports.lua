local SIDECAR_URL = "http://127.0.0.1:27200/"

local _hooks         = { before = {}, after = {} }
local _registeredItems = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- INTERNAL HELPERS
-- ─────────────────────────────────────────────────────────────────────────────

local function _fireHooks(phase, name, args, result)
    local handlers = _hooks[phase] and _hooks[phase][name]
    if not handlers then return end
    for _, fn in ipairs(handlers) do
        local ok, err = pcall(fn, name, args, result)
        if not ok then
            print(("[hyprfm] hook error [%s/%s]: %s"):format(phase, name, tostring(err)))
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- OPCODE REGISTRATION
-- RegisterOpcode: the public API for third-party resources to claim a label.
-- Core opcodes use _registerCoreOpcodes (in main.lua) which bypasses this gate.
--
-- Usage:
--   exports['stdb-relay']:RegisterOpcode("robbery_begin",
--       function(netId, args)
--           local pid = NetworkGetEntityOwner(NetworkGetEntityFromNetworkId(netId))
--           TriggerClientEvent("robbery:start", pid, args[1])
--       end,
--       function(opcode)
--           print("robbery_begin -> " .. Opcode.Format(opcode))
--       end)
-- ─────────────────────────────────────────────────────────────────────────────

exports("RegisterOpcode", function(label, handler, cb)
    if not _syncReady then
        table.insert(_pendingRegistrations, { label = label, handler = handler, cb = cb })
        return
    end

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then
                print(("[hyprfm] RegisterOpcode: sidecar unreachable for '%s'"):format(label))
                return
            end
            local ok, data = pcall(json.decode, body)
            if not ok or not data or not data.ok then
                print(("[hyprfm] RegisterOpcode: failed for '%s': %s"):format(
                    label, (ok and data and data.error) or "unknown"))
                return
            end

            local opcode = data.opcode

            -- Wire into the live Dispatcher
            if handler then
                Dispatcher[opcode] = function(netId, args)
                    local ok2, err = pcall(handler, netId, args)
                    if not ok2 then
                        print(("[hyprfm] RegisterOpcode handler error ['%s' %s]: %s"):format(
                            label, Opcode.Format(opcode), tostring(err)))
                    end
                end
            end

            -- Reverse map for logging
            _opcodeToLabel[opcode] = label

            print(("[hyprfm] RegisterOpcode: '%s' -> %s"):format(label, Opcode.Format(opcode)))
            if cb then cb(opcode) end
        end,
        "POST",
        json.encode({ name = "allocate_opcode", args = {
            context     = label,
            steam_hex   = "",
            net_id      = 0,
            ttl_seconds = 0,   -- permanent
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

-- Deregister a label — use only when a resource is unloaded cleanly.
exports("DeregisterOpcode", function(label, cb)
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, _, _)
            if cb then cb(status == 200) end
        end,
        "POST",
        json.encode({ name = "deregister_opcode", args = { label = label } }),
        { ["Content-Type"] = "application/json" }
    )
end)

-- Returns the live Opcode table. Values are populated after resource start.
-- Use this when you need to pass the registry to another resource at runtime.
exports("GetOpcodeRegistry", function()
    return Opcode
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- USABLE ITEM REGISTRATION
-- Mirrors ESX.RegisterUsableItem / QBCore.Functions.CreateUseableItem.
-- Registered items bypass the Rust use_item reducer entirely.
-- ─────────────────────────────────────────────────────────────────────────────

exports("RegisterItem", function(def)
    if type(def) ~= "table" or not def.item_id or not def.label then
        print("[hyprfm] RegisterItem: def must include item_id and label"); return
    end
    PerformHttpRequest(SIDECAR_URL .. "seed-item",
        function(status, _, _)
            if status ~= 200 then
                print(("[hyprfm] RegisterItem: failed for '%s' — HTTP %d"):format(
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

exports("RegisterUsableItem", function(itemId, cb)
    _registeredItems[itemId] = cb
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- COMMIT — state mutation path
-- ─────────────────────────────────────────────────────────────────────────────

exports("Commit", function(reducerName, args, cb)
    if type(reducerName) ~= "string" or #reducerName == 0 then
        local result = { ok = false, error_code = "BAD_CALL",
            message = "reducerName must be a non-empty string" }
        if cb then cb(false, result) end
        return
    end
    _fireHooks("before", reducerName, args or {}, nil)
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 then
                local result = { ok = false, error_code = "HTTP_ERROR",
                    message = ("sidecar returned HTTP %d for '%s'"):format(status or 0, reducerName) }
                if cb then cb(false, result) end
                return
            end
            local parseOk, parsed = pcall(json.decode, body or "")
            if not parseOk or type(parsed) ~= "table" then
                local result = { ok = false, error_code = "PARSE_ERROR",
                    message = ("non-JSON for '%s'"):format(reducerName) }
                if cb then cb(false, result) end
                return
            end
            if parsed.ok == nil then parsed.ok = true end
            _fireHooks("after", reducerName, args or {}, parsed)
            if cb then cb(parsed.ok == true, parsed) end
        end,
        "POST",
        json.encode({ name = reducerName, args = args or {} }),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- INVOKE NATIVE — volatile express path (no SpacetimeDB round-trip)
-- Validates opcode is in range AND registered before enqueuing.
-- ─────────────────────────────────────────────────────────────────────────────

exports("InvokeNative", function(opcode, netId, args)
    if type(opcode) ~= "number" or opcode < 0x1000 or opcode > 0x8FFF
       or math.floor(opcode) ~= opcode then
        print(("[hyprfm] InvokeNative: invalid opcode '%s'"):format(tostring(opcode)))
        return false
    end
    if not _opcodeToLabel[opcode] then
        print(("[hyprfm] InvokeNative: %s is not a registered opcode"):format(Opcode.Format(opcode)))
        return false
    end
    _volatileQueue[#_volatileQueue + 1] = {
        target_entity_net_id = netId,
        opcode               = opcode,
        payload              = json.encode(args or {}),
    }
    return true
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

-- ─────────────────────────────────────────────────────────────────────────────
-- CONVENIENCE WRAPPERS
-- ─────────────────────────────────────────────────────────────────────────────

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
            server_id = serverId, item_id = itemId, quantity = quantity,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

exports("RemoveItemFromPlayer", function(serverId, itemId, quantity, cb)
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(pi_status, pi_body, _)
            if pi_status ~= 200 or not pi_body then
                if cb then cb(false, { ok = false, error_code = "SIDECAR_UNREACHABLE" }) end
                return
            end
            local pi_ok, pi = pcall(json.decode, pi_body)
            if not pi_ok or not pi or not pi.owner_id or pi.owner_id == "" then
                if cb then cb(false, { ok = false, error_code = "PLAYER_NOT_ONLINE" }) end
                return
            end
            _identityToServerId[pi.owner_id] = serverId
            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function(rm_status, rm_body, _)
                    local rm_ok, rm_result = pcall(json.decode, rm_body or "")
                    if cb then cb(rm_status == 200, rm_ok and rm_result or { ok = rm_status == 200 }) end
                end,
                "POST",
                json.encode({ name = "remove_item", args = {
                    owner_id = pi.owner_id, item_id = itemId, quantity = quantity,
                }}),
                { ["Content-Type"] = "application/json" }
            )
        end,
        "POST",
        json.encode({ name = "get_player_inventory", args = { server_id = serverId } }),
        { ["Content-Type"] = "application/json" }
    )
end)

exports("HasItem", function(serverId, itemId, quantity, cb)
    local identityHex = ""
    for identity, sid in pairs(_identityToServerId) do
        if sid == serverId then identityHex = identity; break end
    end
    local function doCheck(hex)
        PerformHttpRequest(
            ("%sitem-count?owner_id=%s&item_id=%s"):format(SIDECAR_URL, hex, itemId),
            function(status, body, _)
                if status ~= 200 or not body then if cb then cb(false, 0) end; return end
                local ok, result = pcall(json.decode, body)
                if not ok or not result then if cb then cb(false, 0) end; return end
                if cb then cb(result.count >= (quantity or 1), result.count) end
            end,
            "GET", "", {}
        )
    end
    if identityHex ~= "" then
        doCheck(identityHex)
    else
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

exports("RegisterStash", function(stashId, label, maxSlots, maxWeight, x, y, z)
    PerformHttpRequest(SIDECAR_URL .. "reducer", function() end, "POST",
        json.encode({ name = "create_stash", args = {
            stash_id = stashId, stash_type = "world", label = label,
            max_slots = maxSlots, max_weight = maxWeight, owner_id = "",
            pos_x = x, pos_y = y, pos_z = z,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

exports("ResetInventory", function(serverId, cb)
    if type(serverId) ~= "number" or serverId <= 0 then
        if cb then cb(false, "invalid server_id") end; return
    end
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            local ok, data = pcall(json.decode, body or "")
            local success   = status == 200 and ok and data and data.ok == true
            if cb then cb(success, success and data or (data and data.error or "error")) end
        end,
        "POST",
        json.encode({ name = "reset_player_inventory", args = { server_id = serverId } }),
        { ["Content-Type"] = "application/json" }
    )
end)