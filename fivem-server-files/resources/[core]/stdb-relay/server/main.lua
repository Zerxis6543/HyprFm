local SIDECAR_URL     = "http://127.0.0.1:27200/"
local netIdToServerId = {}

local clientSideNatives = {
    SET_ENTITY_COORDS      = true,
    FREEZE_ENTITY_POSITION = true,
    SET_ENTITY_MODEL       = true,
}

-- ── Poll sidecar for pending native instructions ──────────────────────────────
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(100)
        PerformHttpRequest(SIDECAR_URL .. "instructions", function(status, body, headers)
            if status ~= 200 or not body or body == "" or body == "[]" then return end
            local ok, instructions = pcall(json.decode, body)
            if not ok or not instructions then return end

            local consumed = {}
            for _, instr in ipairs(instructions) do
                local key   = instr.native_key
                local netId = instr.target_entity_net_id
                local ok2, args = pcall(json.decode, instr.payload)
                if not ok2 then
                    print("[stdb-relay] Bad payload for #" .. tostring(instr.id))
                else
                    if clientSideNatives[key] then
                        local serverId = netIdToServerId[netId]
                        if serverId then
                            TriggerClientEvent("stdb:executeNative", serverId, key, instr.payload)
                        end
                    elseif key == "SET_ENTITY_HEALTH" then
                        local entity = NetworkGetEntityFromNetworkId(netId)
                        if entity and entity ~= 0 then SetEntityHealth(entity, args[1], 0) end
                    elseif key == "GIVE_WEAPON_TO_PED" then
                        local entity = NetworkGetEntityFromNetworkId(netId)
                        if entity and entity ~= 0 then GiveWeaponToPed(entity, args[1], args[2], false, true) end
                    elseif key == "TRIGGER_CLIENT_EVENT" then
                        TriggerClientEvent(args[1], args[2], args[3])
                    end
                end
                table.insert(consumed, instr.id)
            end

            if #consumed > 0 then
                PerformHttpRequest(SIDECAR_URL .. "consumed", function() end, "POST",
                    json.encode(consumed), { ["Content-Type"] = "application/json" })
            end
        end, "GET", "", {})
    end
end)

-- ── Helper ────────────────────────────────────────────────────────────────────
local function callSidecar(reducerName, args)
    PerformHttpRequest(
        SIDECAR_URL .. "reducer",
        function(status, _, _)
            if status ~= 200 then
                print("[stdb-relay] Sidecar rejected " .. reducerName .. " (" .. tostring(status) .. ")")
            end
        end,
        "POST",
        json.encode({ name = reducerName, args = args }),
        { ["Content-Type"] = "application/json" }
    )
end

-- ── Player lifecycle ──────────────────────────────────────────────────────────
AddEventHandler("playerConnecting", function(name, setReason, deferrals)
    deferrals.defer()
    Citizen.SetTimeout(0, function() deferrals.done() end)
end)

AddEventHandler("playerDropped", function()
    local player = tonumber(source)
    for netId, serverId in pairs(netIdToServerId) do
        if serverId == player then netIdToServerId[netId] = nil; break end
    end
    callSidecar("on_player_disconnect", { server_id = player })
end)

RegisterNetEvent("stdb:clientReady")
AddEventHandler("stdb:clientReady", function()
    local player   = source
    local serverId = tonumber(player)
    local steamHex = GetPlayerIdentifier(player, "steam") or "unknown"
    netIdToServerId[serverId] = serverId
    callSidecar("on_player_connect", {
        steam_hex    = steamHex,
        display_name = GetPlayerName(player),
        server_id    = serverId,
        net_id       = serverId,
    })
end)

RegisterNetEvent("stdb:requestSpawn")
AddEventHandler("stdb:requestSpawn", function(x, y, z, heading)
    local serverId = tonumber(source)
    callSidecar("request_spawn", {
        spawn_x = x, spawn_y = y, spawn_z = z,
        heading = heading, server_id = serverId, net_id = serverId,
    })
end)

RegisterNetEvent("stdb:executeNative")

-- ── Player inventory ──────────────────────────────────────────────────────────
-- Client sends player position so we can find/create nearby ground stash
RegisterNetEvent("stdb:requestInventory")
AddEventHandler("stdb:requestInventory", function(px, py, pz)
    local player   = source
    local serverId = tonumber(player)
    px = px or 0.0; py = py or 0.0; pz = pz or 0.0

    -- 1. Get player pockets
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(pStatus, pBody, _)
            if pStatus ~= 200 or not pBody then return end
            local pOk, pData = pcall(json.decode, pBody)
            if not pOk or not pData then return end

            -- 2. Find or create nearby ground stash
            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function(gStatus, gBody, _)
                    local gData = { stash_id = "", label = "GROUND", max_weight = 999, max_slots = 20, slots = {} }
                    if gStatus == 200 and gBody then
                        local gOk, gParsed = pcall(json.decode, gBody)
                        if gOk and gParsed then gData = gParsed end
                    end

                    TriggerClientEvent("stdb:openInventory", player,
                        pData.slots or {}, pData.item_defs or {}, pData.max_weight or 85, {
                            type      = "ground",
                            label     = "GROUND",
                            id        = gData.stash_id or "",
                            maxWeight = gData.max_weight or 999,
                            maxSlots  = gData.max_slots  or 20,
                            slots     = gData.slots       or {},
                        }
                    )
                end,
                "POST",
                json.encode({ name = "find_or_create_ground_stash", args = { x = px, y = py, z = pz } }),
                { ["Content-Type"] = "application/json" }
            )
        end,
        "POST",
        json.encode({ name = "get_player_inventory", args = { server_id = serverId } }),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ── Move / transfer items ─────────────────────────────────────────────────────
-- targetOwnerType: nil/"" = same panel, "player" = to pockets,
--   "ground"/"stash"/"glovebox"/"trunk" = to secondary
RegisterNetEvent("stdb:moveItem")
AddEventHandler("stdb:moveItem", function(slotId, newSlotIndex, targetOwnerType, targetOwnerId, px, py, pz)
    local player   = source
    local serverId = tonumber(player)

    if not targetOwnerType or targetOwnerType == "" then
        -- Same panel reorder
        callSidecar("move_item", { slot_id = slotId, new_slot_index = newSlotIndex })
        return
    end

    if targetOwnerType == "player" then
        -- Moving into player pockets from any panel
        callSidecar("transfer_item_to_player", {
            slot_id        = slotId,
            server_id      = serverId,
            new_slot_index = newSlotIndex,
        })
    else
        -- Moving to vehicle or stash/ground
        local stdbOwnerType = "stash"
        if targetOwnerType == "glovebox" then
            stdbOwnerType = "vehicle_glovebox"
        elseif targetOwnerType == "trunk" then
            stdbOwnerType = "vehicle_trunk"
        end

        callSidecar("transfer_item", {
            slot_id        = slotId,
            new_owner_id   = targetOwnerId,
            new_owner_type = stdbOwnerType,
            new_slot_index = newSlotIndex,
        })

        -- Spawn a world prop for the player when dropping to ground
        if targetOwnerType == "ground" and px and px ~= 0 then
            TriggerClientEvent("stdb:spawnWorldDrop", player, slotId, px, py, pz)
        end
    end
end)

RegisterNetEvent("stdb:useItem")
AddEventHandler("stdb:useItem", function(slotId)
    local player   = source
    local serverId = tonumber(player)
    local netId = 0
    for nId, sId in pairs(netIdToServerId) do
        if sId == serverId then netId = nId; break end
    end
    callSidecar("use_item", { slot_id = slotId, net_id = netId })
end)

-- ── Vehicle inventory — Glovebox ──────────────────────────────────────────────
RegisterNetEvent("stdb:requestGlovebox")
AddEventHandler("stdb:requestGlovebox", function(vehicleId, modelName, vehicleClass)
    local plate    = vehicleId  -- vehicleId is now the persistent key
    local player   = source
    local serverId = tonumber(player)
    local cfg      = VehicleConfig.GetConfig(modelName, vehicleClass)

    callSidecar("create_vehicle_inventory", {
        plate            = plate,
        model_hash       = tonumber(modelName) or 0,
        trunk_type       = cfg.trunk_type,
        trunk_slots      = cfg.trunk_slots,
        trunk_max_weight = cfg.max_weight,
    })

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data then return end

            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function(pStatus, pBody, _)
                    local pSlots = {}
                    if pStatus == 200 and pBody then
                        local pOk, pData = pcall(json.decode, pBody)
                        if pOk and pData then pSlots = pData.slots or {} end
                    end
                    TriggerClientEvent("stdb:openInventory", player,
                        pSlots, data.item_defs or {}, 85, {
                            type      = "glovebox",
                            label     = "GLOVEBOX",
                            id        = plate,
                            maxWeight = data.max_weight or 10,
                            maxSlots  = data.max_slots  or 5,
                            slots     = data.slots       or {},
                        }
                    )
                end,
                "POST",
                json.encode({ name = "get_player_inventory", args = { server_id = serverId } }),
                { ["Content-Type"] = "application/json" }
            )
        end,
        "POST",
        json.encode({ name = "get_vehicle_inventory", args = { plate = plate, inventory_type = "glovebox" } }),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ── Vehicle inventory — Trunk ─────────────────────────────────────────────────
RegisterNetEvent("stdb:requestTrunk")
AddEventHandler("stdb:requestTrunk", function(vehicleId, modelName, vehicleClass)
    local plate    = vehicleId
    local player   = source
    local serverId = tonumber(player)
    local cfg      = VehicleConfig.GetConfig(modelName, vehicleClass)

    if cfg.trunk_type == "none" then
        TriggerClientEvent("stdb:noTrunk", player)
        return
    end

    callSidecar("create_vehicle_inventory", {
        plate            = plate,
        model_hash       = tonumber(modelName) or 0,
        trunk_type       = cfg.trunk_type,
        trunk_slots      = cfg.trunk_slots,
        trunk_max_weight = cfg.max_weight,
    })

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data then return end

            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function(pStatus, pBody, _)
                    local pSlots = {}
                    if pStatus == 200 and pBody then
                        local pOk, pData = pcall(json.decode, pBody)
                        if pOk and pData then pSlots = pData.slots or {} end
                    end
                    TriggerClientEvent("stdb:openInventory", player,
                        pSlots, data.item_defs or {}, 85, {
                            type      = "trunk",
                            label     = (data.trunk_type == "front") and "FRUNK" or "TRUNK",
                            id        = plate,
                            maxWeight = data.max_weight or 0,
                            maxSlots  = data.max_slots  or 0,
                            slots     = data.slots       or {},
                        }
                    )
                end,
                "POST",
                json.encode({ name = "get_player_inventory", args = { server_id = serverId } }),
                { ["Content-Type"] = "application/json" }
            )
        end,
        "POST",
        json.encode({ name = "get_vehicle_inventory", args = { plate = plate, inventory_type = "trunk" } }),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ── Stashes ───────────────────────────────────────────────────────────────────
RegisterNetEvent("stdb:requestStash")
AddEventHandler("stdb:requestStash", function(stashId)
    local player   = source
    local serverId = tonumber(player)

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data then return end

            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function(pStatus, pBody, _)
                    local pSlots = {}
                    if pStatus == 200 and pBody then
                        local pOk, pData = pcall(json.decode, pBody)
                        if pOk and pData then pSlots = pData.slots or {} end
                    end
                    TriggerClientEvent("stdb:openInventory", player,
                        pSlots, data.item_defs or {}, 85, {
                            type      = "stash",
                            label     = data.label or "STASH",
                            id        = stashId,
                            maxWeight = data.max_weight or 100,
                            maxSlots  = data.max_slots  or 20,
                            slots     = data.slots       or {},
                        }
                    )
                end,
                "POST",
                json.encode({ name = "get_player_inventory", args = { server_id = serverId } }),
                { ["Content-Type"] = "application/json" }
            )
        end,
        "POST",
        json.encode({ name = "get_stash_inventory", args = { stash_id = stashId } }),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:createStash")
AddEventHandler("stdb:createStash", function(stashId, stashType, label, maxSlots, maxWeight, ownerId, x, y, z)
    callSidecar("create_stash", {
        stash_id = stashId, stash_type = stashType, label = label,
        max_slots = maxSlots, max_weight = maxWeight, owner_id = ownerId or "",
        pos_x = x or 0.0, pos_y = y or 0.0, pos_z = z or 0.0,
    })
end)

RegisterNetEvent("stdb:mergeStacks")
AddEventHandler("stdb:mergeStacks", function(srcSlotId, dstSlotId)
    callSidecar("merge_stacks", {
        src_slot_id = srcSlotId,
        dst_slot_id = dstSlotId,
    })
end)

RegisterNetEvent("stdb:openBackpack")
AddEventHandler("stdb:openBackpack", function(bagItemId)
    local player   = source
    local serverId = tonumber(player)

    -- Look up identity from active session
    local sessionResult = callSidecar("get_player_inventory", { server_id = serverId })
    if not sessionResult or not sessionResult.owner_id then return end
    local ownerIdentity = sessionResult.owner_id

    local result = callSidecar("open_backpack", {
        owner_identity = ownerIdentity,
        bag_item_id    = bagItemId,
    })
    if not result then return end

    TriggerClientEvent("stdb:updateSecondary", player, {
        type       = "stash",
        label      = result.label,
        id         = result.stash_id,
        maxWeight  = result.max_weight,
        maxSlots   = result.max_slots,
        slots      = result.slots,
        item_defs  = result.item_defs,
    })
end)

RegisterNetEvent("stdb:splitStack")
AddEventHandler("stdb:splitStack", function(slotId, amount)
    callSidecar("split_stack", { slot_id = slotId, amount = amount })
end)

print("[stdb-relay] Server ready — polling sidecar.")
