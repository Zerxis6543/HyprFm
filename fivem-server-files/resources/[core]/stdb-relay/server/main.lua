print("[stdb-relay] SERVER MAIN LOADED")

local SIDECAR_URL = "http://127.0.0.1:27200/"

-- ─────────────────────────────────────────────────────────────────────────────
-- MODULE-LEVEL GLOBALS
-- ─────────────────────────────────────────────────────────────────────────────

Dispatcher            = {}
_volatileQueue        = {}
_identityToServerId   = {}
_openStashToServerId  = {}
_propOwnerServerId    = {}

_opcodeToLabel        = {}
_syncReady            = false
_pendingRegistrations = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- CORE OPCODE HANDLERS
-- ─────────────────────────────────────────────────────────────────────────────

local function netToPlayer(netId)
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 then return nil end
    return NetworkGetEntityOwner(entity)
end

_coreHandlers = {
    ["entity:set_coords"] = function(netId, args)
        local pid = netToPlayer(netId)
        if pid then TriggerClientEvent("stdb:executeOpcode", pid, "entity:set_coords", args) end
    end,
    ["entity:set_frozen"] = function(netId, args)
        local pid = netToPlayer(netId)
        if pid then TriggerClientEvent("stdb:executeOpcode", pid, "entity:set_frozen", args) end
    end,
    ["entity:set_model"] = function(netId, args)
        local pid = netToPlayer(netId)
        if pid then TriggerClientEvent("stdb:executeOpcode", pid, "entity:set_model", args) end
    end,
    ["entity:set_health"] = function(netId, args)
        local pid = netToPlayer(netId)
        if pid then TriggerClientEvent("stdb:executeOpcode", pid, "entity:set_health", args) end
    end,
    ["entity:give_weapon"] = function(netId, args)
        local pid = netToPlayer(netId)
        if pid then TriggerClientEvent("stdb:executeOpcode", pid, "entity:give_weapon", args) end
    end,
    ["effect:heal"] = function(netId, args)
        local pid = netToPlayer(netId)
        if pid then TriggerClientEvent("stdb:applyEffect", pid, { effect = "heal",   amount = args[1] or 40  }) end
    end,
    ["effect:hunger"] = function(netId, args)
        local pid = netToPlayer(netId)
        if pid then TriggerClientEvent("stdb:applyEffect", pid, { effect = "hunger", amount = args[1] or 30  }) end
    end,
    ["effect:thirst"] = function(netId, args)
        local pid = netToPlayer(netId)
        if pid then TriggerClientEvent("stdb:applyEffect", pid, { effect = "thirst", amount = args[1] or 30  }) end
    end,
    ["engine:call_local_native"] = function(netId, args)
        local pid = netToPlayer(netId)
        if pid then TriggerClientEvent("stdb:executeOpcode", pid, "engine:call_local_native", args) end
    end,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- CONSTANTS TABLE SETTERS
-- ─────────────────────────────────────────────────────────────────────────────

local _labelToConstantSetter = {
    ["entity:set_coords"]       = function(n) Opcode.Entity.SetCoords       = n end,
    ["entity:set_frozen"]       = function(n) Opcode.Entity.SetFrozen       = n end,
    ["entity:set_model"]        = function(n) Opcode.Entity.SetModel        = n end,
    ["entity:set_health"]       = function(n) Opcode.Entity.SetHealth       = n end,
    ["entity:give_weapon"]      = function(n) Opcode.Entity.GiveWeapon      = n end,
    ["effect:heal"]             = function(n) Opcode.Effect.Heal            = n end,
    ["effect:hunger"]           = function(n) Opcode.Effect.Hunger          = n end,
    ["effect:thirst"]           = function(n) Opcode.Effect.Thirst          = n end,
    ["engine:call_local_native"]= function(n) Opcode.Engine.CallLocalNative = n end,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- CORE OPCODE REGISTRATION
-- ─────────────────────────────────────────────────────────────────────────────

local _coreOpcodeLabels = {
    "entity:set_coords",
    "entity:set_frozen",
    "entity:set_model",
    "entity:set_health",
    "entity:give_weapon",
    "effect:heal",
    "effect:hunger",
    "effect:thirst",
    "engine:call_local_native",
}

local function _registerCoreOpcodes(onAllDone)
    local total    = #_coreOpcodeLabels
    local resolved = 0

    for _, label in ipairs(_coreOpcodeLabels) do
        local capturedLabel = label
        PerformHttpRequest(SIDECAR_URL .. "reducer",
            function(status, body, _)
                if status ~= 200 or not body then
                    print(("[stdb-relay] Core opcode registration failed for '%s' (HTTP %d)"):format(
                        capturedLabel, status or 0))
                    resolved = resolved + 1
                    if resolved >= total and onAllDone then onAllDone() end
                    return
                end
                local ok, data = pcall(json.decode, body)
                if not ok or not data or not data.ok then
                    print(("[stdb-relay] Core opcode allocation error for '%s': %s"):format(
                        capturedLabel, (ok and data and data.error) or "parse error"))
                    resolved = resolved + 1
                    if resolved >= total and onAllDone then onAllDone() end
                    return
                end

                local opcode = data.opcode

                -- Wire Dispatcher
                if _coreHandlers[capturedLabel] then
                    Dispatcher[opcode] = _coreHandlers[capturedLabel]
                end

                -- Populate reverse label map
                _opcodeToLabel[opcode] = capturedLabel

                -- Populate constants.lua Opcode table
                local setter = _labelToConstantSetter[capturedLabel]
                if setter then setter(opcode) end

                print(("[stdb-relay] Core opcode ready: '%s' -> %s"):format(
                    capturedLabel, Opcode.Format(opcode)))

                resolved = resolved + 1
                if resolved >= total and onAllDone then onAllDone() end
            end,
            "POST",
            json.encode({ name = "allocate_opcode", args = {
                context     = capturedLabel,
                steam_hex   = "",
                net_id      = 0,
                ttl_seconds = 0,
            }}),
            { ["Content-Type"] = "application/json" }
        )
    end
end

local function _flushPendingRegistrations()
    _syncReady = true
    print(("[stdb-relay] Core opcodes ready — flushing %d pending registration(s)"):format(
        #_pendingRegistrations))
    for _, reg in ipairs(_pendingRegistrations) do
        exports['stdb-relay']:RegisterOpcode(reg.label, reg.handler, reg.cb)
    end
    _pendingRegistrations = {}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- INSTRUCTION DISPATCH
-- ─────────────────────────────────────────────────────────────────────────────

local function dispatchInstruction(instr)
    local ok, args = pcall(json.decode, instr.payload or "[]")
    if not ok or type(args) ~= "table" then args = {} end
    local handler = Dispatcher[instr.opcode]
    if handler then
        handler(instr.target_entity_net_id, args)
    else
        local label = _opcodeToLabel[instr.opcode] or "unknown"
        print(("[stdb-relay] WARN: unhandled opcode %s label='%s'"):format(
            Opcode.Format(instr.opcode), label))
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- DIAGNOSTICS LOOP
-- ─────────────────────────────────────────────────────────────────────────────

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(30000)
        PerformHttpRequest(SIDECAR_URL .. "diagnostics",
            function(status, body, _)
                if status ~= 200 or not body then
                    print("[stdb-relay] DIAG: sidecar unreachable")
                    return
                end
                local ok, d = pcall(json.decode, body)
                if not ok or not d then return end
                print(("[stdb-relay] DIAG: db=%s deltas_fired=%d queue_pending=%d last_delta=%s slots_in_db=%d"):format(
                    tostring(d.db_connected),
                    d.delta_fire_count    or 0,
                    d.delta_queue_pending or 0,
                    tostring(d.last_delta_utc),
                    d.inventory_slot_count or -1
                ))
            end,
            "GET", "", {}
        )
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- INSTRUCTION POLL LOOP
-- ─────────────────────────────────────────────────────────────────────────────

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(100)

        -- Phase 1: drain volatile queue (zero HTTP cost)
        if #_volatileQueue > 0 then
            local batch = _volatileQueue
            _volatileQueue = {}
            for _, instr in ipairs(batch) do
                dispatchInstruction(instr)
            end
        end

        -- Phase 2: fetch persisted instructions from sidecar
        PerformHttpRequest(SIDECAR_URL .. "instructions",
            function(status, body, _)
                if status ~= 200 or not body or body == "" or body == "[]" then return end
                local ok, instructions = pcall(json.decode, body)
                if not ok or type(instructions) ~= "table" or #instructions == 0 then return end
                local consumed = {}
                for _, instr in ipairs(instructions) do
                    dispatchInstruction(instr)
                    consumed[#consumed + 1] = instr.id
                end
                if #consumed > 0 then
                    PerformHttpRequest(SIDECAR_URL .. "consumed",
                        function() end, "POST",
                        json.encode(consumed),
                        { ["Content-Type"] = "application/json" }
                    )
                end
            end,
            "GET", "", {}
        )
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- SLOT DELTA PUSH LOOP
-- ─────────────────────────────────────────────────────────────────────────────

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(150)
        PerformHttpRequest(SIDECAR_URL .. "slot-deltas",
            function(status, body, _)
                if status ~= 200 or not body or body == "" or body == "[]" then return end
                local ok, deltas = pcall(json.decode, body)
                if not ok or type(deltas) ~= "table" or #deltas == 0 then return end

                local byServerId = {}
                for _, delta in ipairs(deltas) do
                    local oid = delta.owner_id or ""
                    if oid == "" then goto continueDelta end
                    local sid = _identityToServerId[oid] or _openStashToServerId[oid]
                    if not sid and oid:sub(1, 6) == "steam:" then
                        for _, playerSrc in ipairs(GetPlayers()) do
                            local psrc = tonumber(playerSrc)
                            if psrc then
                                for _, identifier in ipairs(GetPlayerIdentifiers(psrc)) do
                                    if identifier == oid then
                                        sid = psrc
                                        _identityToServerId[oid] = psrc
                                        break
                                    end
                                end
                            end
                            if sid then break end
                        end
                    end
                    print(("[Delta] type=" .. tostring(delta.type) ..
                           " owner_id=" .. oid ..
                           " routed_to=" .. tostring(sid)))
                    if not sid then goto continueDelta end
                    if not byServerId[sid] then byServerId[sid] = {} end
                    byServerId[sid][#byServerId[sid] + 1] = delta
                    ::continueDelta::
                end

                for serverId, playerDeltas in pairs(byServerId) do
                    TriggerClientEvent("stdb:slotDeltas", serverId, playerDeltas)
                end

                local checkedStashes = {}
                for _, delta in ipairs(deltas) do
                    if delta.type == "deleted" then
                        local oid = delta.owner_id or ""
                        if oid:sub(1, 7) == "ground_" and not checkedStashes[oid] then
                            checkedStashes[oid] = true
                            local sid = _propOwnerServerId[oid]
                            if sid then
                                PerformHttpRequest(SIDECAR_URL .. "reducer",
                                    function(qs, qb, _)
                                        if qs ~= 200 or not qb then return end
                                        local qok, qdata = pcall(json.decode, qb)
                                        if qok and qdata and (not qdata.slots or #qdata.slots == 0) then
                                            TriggerClientEvent("stdb:deleteWorldProp", sid, oid)
                                            _propOwnerServerId[oid] = nil
                                        end
                                    end,
                                    "POST",
                                    json.encode({ name = "get_inventory_slots", args = {
                                        owner_id = oid, owner_type = "stash",
                                    }}),
                                    { ["Content-Type"] = "application/json" }
                                )
                            end
                        end
                    end
                end
            end,
            "GET", "", {}
        )
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- PLAYER LIFECYCLE
-- ─────────────────────────────────────────────────────────────────────────────

AddEventHandler("onResourceStart", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    Citizen.CreateThread(function()
        Citizen.Wait(500)

        -- Ask any already-connected players to re-announce their identity
        local playerList = GetPlayers()
        if #playerList > 0 then
            print(("[stdb-relay] Resource started — asking %d connected player(s) to re-announce"):format(
                #playerList))
            for _, playerSrc in ipairs(playerList) do
                local src = tonumber(playerSrc)
                if src then TriggerClientEvent("stdb:reconnect", src) end
            end
        end

        -- Register all core opcodes, then open the gate for third-party registrations
        _registerCoreOpcodes(function()
            _flushPendingRegistrations()
        end)
    end)
end)

RegisterNetEvent("stdb:playerConnected")
AddEventHandler("stdb:playerConnected", function(netId, heading)
    local src        = source
    local playerName = GetPlayerName(src)
    local steamHex   = ""
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if string.sub(id, 1, 6) == "steam:" then steamHex = id; break end
    end
    if steamHex ~= "" then
        _identityToServerId[steamHex] = src
        Player(src).state:set("steamHex", steamHex, false)
    end
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, _, _)
            if status == 200 then
                print(("[stdb-relay] '%s' (server_id=%d) registered"):format(playerName, src))
            else
                print(("[stdb-relay] WARN: on_player_connect HTTP %d for '%s'"):format(status or 0, playerName))
            end
        end,
        "POST",
        json.encode({ name = "on_player_connect", args = {
            steam_hex    = steamHex,
            display_name = playerName,
            server_id    = src,
            net_id       = netId  or 0,
            heading      = heading or 0.0,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

AddEventHandler("playerDropped", function(_reason)
    local src      = source
    local steamHex = ""
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if string.sub(id, 1, 6) == "steam:" then steamHex = id; break end
    end
    for identity, sid in pairs(_identityToServerId) do
        if sid == src then _identityToServerId[identity] = nil; break end
    end
    for stashId, sid in pairs(_openStashToServerId) do
        if sid == src then _openStashToServerId[stashId] = nil end
    end
    for stashId, sid in pairs(_propOwnerServerId) do
        if sid == src then _propOwnerServerId[stashId] = nil end
    end
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function() end, "POST",
        json.encode({ name = "on_player_disconnect", args = {
            steam_hex = steamHex, server_id = src,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:clientReady")
AddEventHandler("stdb:clientReady", function()
    local src      = source
    local steamHex = ""
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if string.sub(id, 1, 6) == "steam:" then steamHex = id; break end
    end
    if steamHex ~= "" then
        _identityToServerId[steamHex] = src
        Player(src).state:set("steamHex", steamHex, false)
    end
end)

RegisterNetEvent("stdb:reconnect")
AddEventHandler("stdb:reconnect", function() end)

-- ─────────────────────────────────────────────────────────────────────────────
-- OWNER RESOLUTION HELPER
-- ─────────────────────────────────────────────────────────────────────────────

local function resolveOwner(rawType, rawId, playerSrc)
    if rawType == "player" then
        local identityHex = (rawId and rawId ~= "") and rawId or ""
        if identityHex == "" then
            for identity, sid in pairs(_identityToServerId) do
                if sid == playerSrc then identityHex = identity; break end
            end
        end
        return "player", identityHex
    elseif rawType == "glovebox" then
        return "vehicle_glovebox", rawId
    elseif rawType == "trunk" then
        return "vehicle_trunk", rawId
    elseif rawType == "ground" or rawType == "backpack" then
        return "stash", rawId
    else
        return rawType, rawId
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- INVENTORY: OPEN POCKETS + GROUND STASH
-- ─────────────────────────────────────────────────────────────────────────────

RegisterNetEvent("stdb:requestInventory")
AddEventHandler("stdb:requestInventory", function(x, y, z)
    local src = source
    local steamHex = Player(src).state.steamHex or ""
    if steamHex == "" then
        for _, id in ipairs(GetPlayerIdentifiers(src)) do
            if string.sub(id, 1, 6) == "steam:" then steamHex = id; break end
        end
    end
    if steamHex ~= "" then
        _identityToServerId[steamHex] = src
        Player(src).state:set("steamHex", steamHex, false)
    end
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(pi_status, pi_body, _)
            if pi_status ~= 200 or not pi_body then return end
            local pi_ok, pi = pcall(json.decode, pi_body)
            if not pi_ok or not pi then return end
            if pi.owner_id and pi.owner_id ~= "" then
                _identityToServerId[pi.owner_id] = src
            end
            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function(gs_status, gs_body, _)
                    local ground = { type = "ground", label = "GROUND", id = "", maxWeight = 999, maxSlots = 50, slots = {} }
                    if gs_status == 200 and gs_body and gs_body ~= "" then
                        local gs_ok, gs = pcall(json.decode, gs_body)
                        if gs_ok and gs then
                            ground.id        = gs.stash_id   or ""
                            ground.maxWeight = gs.max_weight or 999
                            ground.maxSlots  = gs.max_slots  or 50
                            ground.slots     = gs.slots      or {}
                            if ground.id ~= "" then
                                _openStashToServerId[ground.id] = src
                            end
                        end
                    end
                    if pi.backpack_data and pi.backpack_data.stash_id
                       and pi.backpack_data.stash_id ~= "" then
                        _openStashToServerId[pi.backpack_data.stash_id] = src
                    end
                    TriggerClientEvent("stdb:openInventory", src,
                        pi.slots or {}, pi.item_defs or {}, pi.max_weight or 85,
                        ground, pi.equipped_slots or {}, pi.backpack_data, pi.owner_id or "")
                end,
                "POST",
                json.encode({ name = "find_or_create_ground_stash", args = { x = x, y = y, z = z } }),
                { ["Content-Type"] = "application/json" }
            )
        end,
        "POST",
        json.encode({ name = "get_player_inventory", args = { server_id = src, steam_hex = steamHex } }),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- INVENTORY: VEHICLE GLOVEBOX
-- ─────────────────────────────────────────────────────────────────────────────

RegisterNetEvent("stdb:requestGlovebox")
AddEventHandler("stdb:requestGlovebox", function(vehicleId, modelName, vehicleClass)
    local src   = source
    local plate = tostring(vehicleId)
    local steamHex = Player(src).state.steamHex or ""
    if steamHex == "" then
        for _, id in ipairs(GetPlayerIdentifiers(src)) do
            if string.sub(id, 1, 6) == "steam:" then steamHex = id; break end
        end
    end
    if steamHex ~= "" then
        _identityToServerId[steamHex] = src
        Player(src).state:set("steamHex", steamHex, false)
    end
    local cfg = (VehicleConfig and VehicleConfig.GetConfig(modelName or "unknown", vehicleClass or 0))
        or { trunk_type = "rear", trunk_slots = 20, max_weight = 50 }
    PerformHttpRequest(SIDECAR_URL .. "reducer", function() end, "POST",
        json.encode({ name = "create_vehicle_inventory", args = {
            plate = plate, model_hash = 0,
            trunk_type = cfg.trunk_type or "rear",
            trunk_slots = cfg.trunk_slots or 20,
            trunk_max_weight = cfg.max_weight or 50,
        }}),
        { ["Content-Type"] = "application/json" }
    )
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(pi_status, pi_body, _)
            if pi_status ~= 200 or not pi_body then return end
            local pi_ok, pi = pcall(json.decode, pi_body)
            if not pi_ok or not pi then return end
            if pi.owner_id and pi.owner_id ~= "" then _identityToServerId[pi.owner_id] = src end
            _openStashToServerId[plate] = src
            if pi.backpack_data and pi.backpack_data.stash_id
               and pi.backpack_data.stash_id ~= "" then
                _openStashToServerId[pi.backpack_data.stash_id] = src
            end
            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function(gb_status, gb_body, _)
                    if gb_status ~= 200 or not gb_body then return end
                    local gb_ok, gb = pcall(json.decode, gb_body)
                    if not gb_ok or not gb then return end
                    TriggerClientEvent("stdb:openInventory", src,
                        pi.slots or {}, pi.item_defs or {}, pi.max_weight or 85,
                        { type = "glovebox", label = "GLOVEBOX", id = plate,
                          maxWeight = gb.max_weight or 10, maxSlots = gb.max_slots or 5, slots = gb.slots or {} },
                        pi.equipped_slots or {}, pi.backpack_data, pi.owner_id or "")
                end,
                "POST",
                json.encode({ name = "get_vehicle_inventory", args = { plate = plate, inventory_type = "glovebox" } }),
                { ["Content-Type"] = "application/json" }
            )
        end,
        "POST",
        json.encode({ name = "get_player_inventory", args = { server_id = src, steam_hex = steamHex } }),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- INVENTORY: VEHICLE TRUNK
-- ─────────────────────────────────────────────────────────────────────────────

RegisterNetEvent("stdb:requestTrunk")
AddEventHandler("stdb:requestTrunk", function(vehicleId, modelName, vehicleClass)
    local src   = source
    local plate = tostring(vehicleId)
    local steamHex = Player(src).state.steamHex or ""
    if steamHex == "" then
        for _, id in ipairs(GetPlayerIdentifiers(src)) do
            if string.sub(id, 1, 6) == "steam:" then steamHex = id; break end
        end
    end
    if steamHex ~= "" then
        _identityToServerId[steamHex] = src
        Player(src).state:set("steamHex", steamHex, false)
    end
    local cfg = (VehicleConfig and VehicleConfig.GetConfig(modelName or "unknown", vehicleClass or 0))
        or { trunk_type = "rear", trunk_slots = 20, max_weight = 50 }
    PerformHttpRequest(SIDECAR_URL .. "reducer", function() end, "POST",
        json.encode({ name = "create_vehicle_inventory", args = {
            plate = plate, model_hash = 0,
            trunk_type = cfg.trunk_type or "rear",
            trunk_slots = cfg.trunk_slots or 20,
            trunk_max_weight = cfg.max_weight or 50,
        }}),
        { ["Content-Type"] = "application/json" }
    )
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(pi_status, pi_body, _)
            if pi_status ~= 200 or not pi_body then return end
            local pi_ok, pi = pcall(json.decode, pi_body)
            if not pi_ok or not pi then return end
            if pi.owner_id and pi.owner_id ~= "" then _identityToServerId[pi.owner_id] = src end
            _openStashToServerId[plate] = src
            if pi.backpack_data and pi.backpack_data.stash_id
               and pi.backpack_data.stash_id ~= "" then
                _openStashToServerId[pi.backpack_data.stash_id] = src
            end
            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function(tr_status, tr_body, _)
                    if tr_status ~= 200 or not tr_body then return end
                    local tr_ok, tr = pcall(json.decode, tr_body)
                    if not tr_ok or not tr then return end
                    local trunkLabel = (tr.trunk_type == "front") and "FRUNK" or "TRUNK"
                    TriggerClientEvent("stdb:openInventory", src,
                        pi.slots or {}, pi.item_defs or {}, pi.max_weight or 85,
                        { type = "trunk", label = trunkLabel, id = plate,
                          maxWeight = tr.max_weight or cfg.max_weight or 50,
                          maxSlots  = tr.max_slots  or cfg.trunk_slots or 20,
                          slots     = tr.slots or {} },
                        pi.equipped_slots or {}, pi.backpack_data, pi.owner_id or "")
                end,
                "POST",
                json.encode({ name = "get_vehicle_inventory", args = { plate = plate, inventory_type = "trunk" } }),
                { ["Content-Type"] = "application/json" }
            )
        end,
        "POST",
        json.encode({ name = "get_player_inventory", args = { server_id = src, steam_hex = steamHex } }),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:closeInventory")
AddEventHandler("stdb:closeInventory", function()
    local src = source
    for stashId, sid in pairs(_openStashToServerId) do
        if sid == src then _openStashToServerId[stashId] = nil end
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- INVENTORY: MOVE / TRANSFER
-- ─────────────────────────────────────────────────────────────────────────────

RegisterNetEvent("stdb:moveItem")
AddEventHandler("stdb:moveItem", function(slotId, newSlotIndex, ownerType, ownerId, _x, _y, _z, _propModel)
    local src = source
    if not ownerType or ownerType == "" then
        PerformHttpRequest(SIDECAR_URL .. "reducer",
            function() end, "POST",
            json.encode({ name = "move_item", args = { slot_id = slotId, new_slot_index = newSlotIndex } }),
            { ["Content-Type"] = "application/json" }
        )
        return
    end
    local resolvedType, resolvedId = resolveOwner(ownerType, ownerId or "", src)
    if resolvedType == "player" and (resolvedId == nil or resolvedId == "") then
        print(("[stdb-relay] stdb:moveItem: cannot resolve identity for server_id=%d"):format(src))
        return
    end
    if resolvedType ~= "player" and resolvedType ~= "equip"
       and resolvedId ~= nil and resolvedId ~= "" then
        _openStashToServerId[resolvedId] = src
    end
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function() end, "POST",
        json.encode({ name = "transfer_item", args = {
            slot_id = slotId, new_owner_id = resolvedId,
            new_owner_type = resolvedType, new_slot_index = newSlotIndex,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- INVENTORY: USE / EQUIP / DROP / STACK OPS / BACKPACK / GIVE
-- ─────────────────────────────────────────────────────────────────────────────

RegisterNetEvent("stdb:useItem")
AddEventHandler("stdb:useItem", function(slotId, itemId)
    local src   = source
    local ped   = GetPlayerPed(src)
    local netId = NetworkGetNetworkIdFromEntity(ped)
    local identityHex = ""
    for identity, sid in pairs(_identityToServerId) do
        if sid == src then identityHex = identity; break end
    end
    if itemId and _registeredItems and _registeredItems[itemId] then
        _registeredItems[itemId](src, itemId, slotId)
        return
    end
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function() end, "POST",
        json.encode({ name = "use_item", args = { slot_id = slotId, net_id = netId } }),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:useItemByKey")
AddEventHandler("stdb:useItemByKey", function(equipKey)
    local src   = source
    local ped   = GetPlayerPed(src)
    local netId = NetworkGetNetworkIdFromEntity(ped)
    local identityHex = ""
    for identity, sid in pairs(_identityToServerId) do
        if sid == src then identityHex = identity; break end
    end
    if identityHex == "" then return end
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data or not data.slots or #data.slots == 0 then return end
            local equipSlot = data.slots[1]
            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function() end, "POST",
                json.encode({ name = "use_item", args = { slot_id = equipSlot.id, net_id = netId } }),
                { ["Content-Type"] = "application/json" }
            )
        end,
        "POST",
        json.encode({ name = "get_inventory_slots", args = {
            owner_id = identityHex .. "_equip_" .. equipKey, owner_type = "equip",
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:dropItem")
AddEventHandler("stdb:dropItem", function(slotId, quantity, _itemId, propModel)
    local src = source
    local pos = GetEntityCoords(GetPlayerPed(src))
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data or not data.ok then return end
            if data.stash_id and data.stash_id ~= "" then
                _propOwnerServerId[data.stash_id]  = src
                _openStashToServerId[data.stash_id] = src
                TriggerClientEvent("stdb:groundStashUpdate", src, data.stash_id)
            end
            TriggerClientEvent("stdb:spawnWorldDrop", src,
                slotId, data.stash_id or "", propModel or "prop_cs_cardbox_01",
                pos.x, pos.y, pos.z)
        end,
        "POST",
        json.encode({ name = "drop_item_to_ground", args = {
            slot_id = slotId, quantity = quantity or 0, x = pos.x, y = pos.y, z = pos.z,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:dropItemAt")
AddEventHandler("stdb:dropItemAt", function(slotId, quantity, _itemId, propModel, x, y, z)
    local src = source
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data or not data.ok then return end
            if data.stash_id and data.stash_id ~= "" then
                _propOwnerServerId[data.stash_id]  = src
                _openStashToServerId[data.stash_id] = src
                TriggerClientEvent("stdb:groundStashUpdate", src, data.stash_id)
            end
            TriggerClientEvent("stdb:spawnWorldDrop", src,
                slotId, data.stash_id or "", propModel or "prop_cs_cardbox_01", x, y, z)
        end,
        "POST",
        json.encode({ name = "drop_item_to_ground", args = {
            slot_id = slotId, quantity = quantity or 0, x = x, y = y, z = z,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:finalizeThrow")
AddEventHandler("stdb:finalizeThrow", function(slotId, _itemId, propModel, x, y, z)
    local src = source
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data or not data.ok then return end
            if data.stash_id and data.stash_id ~= "" then
                _propOwnerServerId[data.stash_id]  = src
                _openStashToServerId[data.stash_id] = src
                TriggerClientEvent("stdb:groundStashUpdate", src, data.stash_id)
            end
            TriggerClientEvent("stdb:spawnWorldDrop", src,
                slotId, data.stash_id or "", propModel or "prop_cs_cardbox_01", x, y, z)
        end,
        "POST",
        json.encode({ name = "drop_item_to_ground", args = {
            slot_id = slotId, quantity = 0, x = x, y = y, z = z,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:mergeStacks")
AddEventHandler("stdb:mergeStacks", function(srcSlotId, dstSlotId)
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function() end, "POST",
        json.encode({ name = "merge_stacks", args = { src_slot_id = srcSlotId, dst_slot_id = dstSlotId } }),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:splitStack")
AddEventHandler("stdb:splitStack", function(slotId, amount)
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function() end, "POST",
        json.encode({ name = "split_stack", args = { slot_id = slotId, amount = amount } }),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:equipItem")
AddEventHandler("stdb:equipItem", function(slotId, equipKey, _itemId)
    local src = source
    local identityHex = ""
    for identity, sid in pairs(_identityToServerId) do
        if sid == src then identityHex = identity; break end
    end
    if identityHex == "" then return end
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function() end, "POST",
        json.encode({ name = "transfer_item", args = {
            slot_id = slotId, new_owner_id = identityHex .. "_equip_" .. equipKey,
            new_owner_type = "equip", new_slot_index = 0,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:unequipItem")
AddEventHandler("stdb:unequipItem", function(slotId, equipKey, targetPanel, targetIndex)
    local src = source
    local identityHex = ""
    for identity, sid in pairs(_identityToServerId) do
        if sid == src then identityHex = identity; break end
    end
    if identityHex == "" then return end
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function() end, "POST",
        json.encode({ name = "transfer_item", args = {
            slot_id = slotId, new_owner_id = identityHex,
            new_owner_type = "player", new_slot_index = targetIndex or 0,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:openBackpack")
AddEventHandler("stdb:openBackpack", function(bagItemId, bagSlotId)
    local src = source
    local identityHex = ""
    for identity, sid in pairs(_identityToServerId) do
        if sid == src then identityHex = identity; break end
    end
    if identityHex == "" then return end
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data then return end
            local bpStashId = data.stash_id or ""
            if bpStashId ~= "" then _openStashToServerId[bpStashId] = src end
            TriggerClientEvent("stdb:openBackpackPanel", src, {
                type      = "stash",
                label     = data.label      or "BACKPACK",
                id        = bpStashId,
                maxWeight = data.max_weight or 30,
                maxSlots  = data.max_slots  or 20,
                slots     = data.slots      or {},
                item_defs = data.item_defs  or {},
            })
        end,
        "POST",
        json.encode({ name = "open_backpack", args = {
            owner_identity = identityHex,
            bag_item_id    = bagItemId or "backpack",
            bag_slot_id    = bagSlotId or 0,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:giveItem")
AddEventHandler("stdb:giveItem", function(slotId, targetServerId)
    local src = source
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data then return end
            if data.ok then
                TriggerClientEvent("stdb:itemGiven",    src,           true)
                TriggerClientEvent("stdb:itemReceived", targetServerId, true)
            else
                TriggerClientEvent("stdb:itemGiven", src, false,
                    data.error_code or "UNKNOWN_ERROR", data.actual_kg, data.max_kg)
            end
        end,
        "POST",
        json.encode({ name = "transfer_item_to_player", args = {
            slot_id = slotId, server_id = targetServerId,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- ADMIN: RESET PLAYER INVENTORY
-- ─────────────────────────────────────────────────────────────────────────────

local function resolveSteamHex(serverId)
    for hex, sid in pairs(_identityToServerId) do
        if sid == serverId then return hex end
    end
    return nil
end

local function doResetInventory(targetSrc, invokerSrc)
    if invokerSrc ~= 0 and invokerSrc ~= targetSrc then
        if not IsPlayerAceAllowed(tostring(invokerSrc), "stdb.admin") then
            TriggerClientEvent("chat:addMessage", invokerSrc, {
                color = { 255, 80, 80 }, args = { "SYSTEM", "Permission denied." }
            })
            return
        end
    end
    local steamHex    = resolveSteamHex(targetSrc)
    local argsPayload = steamHex and steamHex ~= ""
        and { steam_hex = steamHex }
        or  { server_id = targetSrc }
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            local ok, data = pcall(json.decode, body or "")
            if status ~= 200 or not ok or not data or not data.ok then
                local errMsg = (ok and data and data.error) or ("HTTP " .. tostring(status))
                print(("[stdb-relay] resetinventory failed: %s"):format(errMsg))
                if invokerSrc ~= 0 then
                    TriggerClientEvent("chat:addMessage", invokerSrc, {
                        color = { 255, 80, 80 },
                        args  = { "SYSTEM", "Inventory reset failed: " .. errMsg }
                    })
                end
                return
            end
            TriggerClientEvent("stdb:forceCloseInventory", targetSrc)
            if invokerSrc ~= 0 then
                TriggerClientEvent("chat:addMessage", invokerSrc, {
                    color = { 80, 220, 80 },
                    args  = { "SYSTEM", ("Reset — %d cleared, %d given."):format(
                        data.removed or 0, data.given or 0) }
                })
            end
        end,
        "POST",
        json.encode({ name = "reset_player_inventory", args = argsPayload }),
        { ["Content-Type"] = "application/json" }
    )
end

RegisterCommand("resetinventory", function(src, cmdArgs, _)
    local targetSrc = src
    if cmdArgs[1] then
        local arg = cmdArgs[1]
        if arg:sub(1, 6) == "steam:" then
            if src ~= 0 and not IsPlayerAceAllowed(tostring(src), "stdb.admin") then return end
            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function() end, "POST",
                json.encode({ name = "reset_player_inventory", args = { steam_hex = arg } }),
                { ["Content-Type"] = "application/json" }
            )
            return
        end
        local parsed = tonumber(arg)
        if not parsed then return end
        targetSrc = math.floor(parsed)
    end
    if targetSrc == 0 then
        print("[stdb-relay] resetinventory: specify a server_id")
        return
    end
    doResetInventory(targetSrc, src)
end, true)