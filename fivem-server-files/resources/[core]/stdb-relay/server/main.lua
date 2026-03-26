local SIDECAR_URL     = "http://127.0.0.1:27200/"
local netIdToServerId = {}
local openInventories = {}  -- tracks who has what open: source → { ownerType, ownerId }

local function broadcastInventoryUpdate(ownerType, ownerId)
    -- Just a debug print so you can see it working in the console
    print(("^2[Inventory]^7 Internal state change detected for %s:%s - Syncing via Delta Queue"):format(ownerType, ownerId))
end

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

                    openInventories[player] = {
                        primary   = { ownerType = "player", ownerId = tostring(player) },
                        secondary = { ownerType = "stash",  ownerId = gData.stash_id or "" },
                    }
                    TriggerClientEvent("stdb:openInventory", player,
                        pData.slots or {}, pData.item_defs or {}, pData.max_weight or 85, {
                            type      = "ground",
                            label     = "GROUND",
                            id        = gData.stash_id or "",
                            maxWeight = gData.max_weight or 999,
                            maxSlots  = gData.max_slots  or 20,
                            slots     = gData.slots       or {},
                        }, pData.equipped_slots or {}, pData.backpack_data
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
AddEventHandler("stdb:moveItem", function(slotId, newSlotIndex, targetOwnerType, targetOwnerId, px, py, pz, itemPropModel)
    local player   = source
    local serverId = tonumber(player)

    if not targetOwnerType or targetOwnerType == "" then
        -- Same panel reorder
        callSidecar("move_item", { slot_id = slotId, new_slot_index = newSlotIndex })
        return
    end

    if targetOwnerType == "player" then
        callSidecar("transfer_item_to_player", {
            slot_id        = slotId,
            server_id      = serverId,
            new_slot_index = newSlotIndex,
        })
        local info = openInventories[player]
        if info and info.secondary then
            local capturedSecType = info.secondary.ownerType
            local capturedSecId   = info.secondary.ownerId
            -- Delete world prop when item picked up from ground stash
            if capturedSecType == "stash" then
                TriggerClientEvent("stdb:deleteWorldProp", -1, capturedSecId)
            end
            Citizen.SetTimeout(150, function()
                broadcastInventoryUpdate(capturedSecType, capturedSecId)
            end)
        end
    else
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

        -- Spawn world prop when dragging to ground
        if targetOwnerType == "ground" and px and px ~= 0 then
            Citizen.SetTimeout(400, function()
                PerformHttpRequest(SIDECAR_URL .. "reducer",
                    function(s2, b2, _)
                        local ok2, slots2 = pcall(json.decode, b2)
                        if ok2 and slots2 and slots2.slots then
                            for _, sl in ipairs(slots2.slots) do
                                TriggerClientEvent("stdb:spawnWorldDrop", -1,
                                    sl.id, targetOwnerId,
                                    itemPropModel or "prop_cs_cardbox_01",
                                    px, py, pz)
                                break
                            end
                        end
                    end,
                    "POST",
                    json.encode({ name = "get_inventory_slots", args = {
                        owner_type = "stash",
                        owner_id   = targetOwnerId,
                    }}),
                    { ["Content-Type"] = "application/json" }
                )
            end)
        end

        local capturedType = stdbOwnerType
        local capturedId   = targetOwnerId
        Citizen.SetTimeout(150, function()
            broadcastInventoryUpdate(capturedType, capturedId)
        end)
    end
    local capturedPlayer = tostring(player)
    Citizen.SetTimeout(150, function()
        broadcastInventoryUpdate("player", capturedPlayer)
    end)
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
                    local pEquipped = {}
                    local pBackpackData = nil
                    local pItemDefs = {}
                    if pStatus == 200 and pBody then
                        local pOk, pData = pcall(json.decode, pBody)
                        if pOk and pData then
                            pSlots        = pData.slots          or {}
                            pEquipped     = pData.equipped_slots  or {}
                            pBackpackData = pData.backpack_data
                            pItemDefs     = pData.item_defs      or {}
                        end
                    end
                    openInventories[player] = {
                        primary   = { ownerType = "player",           ownerId = tostring(player) },
                        secondary = { ownerType = "vehicle_glovebox", ownerId = plate },
                    }
                    local mergedDefs = {}
                    for k, v in pairs(pItemDefs) do mergedDefs[k] = v end
                    for k, v in pairs(data.item_defs or {}) do mergedDefs[k] = v end
                    TriggerClientEvent("stdb:openInventory", player,
                        pSlots, mergedDefs, 85, {
                            type      = "glovebox",
                            label     = "GLOVEBOX",
                            id        = plate,
                            maxWeight = data.max_weight or 10,
                            maxSlots  = data.max_slots  or 5,
                            slots     = data.slots       or {},
                        }, pEquipped, pBackpackData
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
                    local pEquipped = {}
                    local pBackpackData = nil
                    if pStatus == 200 and pBody then
                        local pOk, pData = pcall(json.decode, pBody)
                        if pOk and pData then
                            pSlots       = pData.slots          or {}
                            pEquipped    = pData.equipped_slots  or {}
                            pBackpackData = pData.backpack_data
                        end
                    end
                    openInventories[player] = {
                        primary   = { ownerType = "player",       ownerId = tostring(player) },
                        secondary = { ownerType = "vehicle_trunk", ownerId = plate },
                    }
                    local mergedDefs = {}
                    for k, v in pairs(pItemDefs) do mergedDefs[k] = v end
                    for k, v in pairs(data.item_defs or {}) do mergedDefs[k] = v end
                    TriggerClientEvent("stdb:openInventory", player,
                        pSlots, mergedDefs, 85, {
                            type      = "trunk",
                            label     = "TRUNK",
                            id        = plate,
                            maxWeight = data.max_weight or 0,
                            maxSlots  = data.max_slots  or 0,
                            slots     = data.slots       or {},
                        }, pEquipped, pBackpackData
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
                    local pEquipped = {}
                    local pBackpackData = nil
                    if pStatus == 200 and pBody then
                        local pOk, pData = pcall(json.decode, pBody)
                        if pOk and pData then
                            pSlots        = pData.slots         or {}
                            pEquipped     = pData.equipped_slots or {}
                            pBackpackData = pData.backpack_data
                        end
                    end
                    openInventories[player] = {
                        primary   = { ownerType = "player", ownerId = tostring(player) },
                        secondary = { ownerType = "stash",  ownerId = stashId },
                    }
                    TriggerClientEvent("stdb:openInventory", player,
                        pSlots, data.item_defs or {}, 85, {
                            type      = "stash",
                            label     = data.label or "STASH",
                            id        = stashId,
                            maxWeight = data.max_weight or 100,
                            maxSlots  = data.max_slots  or 20,
                            slots     = data.slots      or {},
                        }, pEquipped, pBackpackData
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
AddEventHandler("stdb:openBackpack", function(bagItemId, bagSlotId)
    local player   = source
    local serverId = tonumber(player)

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(pStatus, pBody, _)
            if pStatus ~= 200 or not pBody then return end
            local pOk, pData = pcall(json.decode, pBody)
            if not pOk or not pData or not pData.owner_id then return end

            -- Find the equipped backpack slot ID
            local bagSlotId = tonumber(bagSlotId) or 0
            if bagSlotId == 0 and pData.equipped_slots then
                for _, es in ipairs(pData.equipped_slots) do
                    if es.equip_key == "backpack" then
                        bagSlotId = es.id or 0
                        break
                    end
                end
            end

            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function(bStatus, bBody, _)
                    if bStatus ~= 200 or not bBody then return end
                    local bOk, result = pcall(json.decode, bBody)
                    if not bOk or not result then return end
                    print("[stdb-relay] Sending openBackpackPanel to player " .. tostring(player) .. " stash=" .. tostring(result.stash_id))
                    TriggerClientEvent("stdb:openBackpackPanel", player, {
                        type      = "stash",
                        label     = result.label     or "BACKPACK",
                        id        = result.stash_id  or "",
                        maxWeight = result.max_weight or 30,
                        maxSlots  = result.max_slots  or 20,
                        slots     = result.slots      or {},
                        item_defs = result.item_defs  or {},
                    })
                end,
                "POST",
                json.encode({ name = "open_backpack", args = { owner_identity = pData.owner_id, bag_item_id = bagItemId, bag_slot_id = bagSlotId } }),
                { ["Content-Type"] = "application/json" }
            )
        end,
        "POST",
        json.encode({ name = "get_player_inventory", args = { server_id = serverId } }),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:splitStack")
AddEventHandler("stdb:splitStack", function(slotId, amount)
    callSidecar("split_stack", { slot_id = slotId, amount = amount })
end)

RegisterNetEvent("stdb:closeInventory")
AddEventHandler("stdb:closeInventory", function()
    openInventories[source] = nil
end)

RegisterNetEvent("stdb:equipItem")
AddEventHandler("stdb:equipItem", function(slotId, equipKey)
    local player   = source
    local serverId = tonumber(player)
    -- Get player identity to build equip owner_id
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data or not data.owner_id then return end
            local equipOwnerId = data.owner_id .. "_equip_" .. equipKey
            callSidecar("transfer_item", {
                slot_id        = slotId,
                new_owner_id   = equipOwnerId,
                new_owner_type = "equip",
                new_slot_index = 0,
            })
        end,
        "POST",
        json.encode({ name = "get_player_inventory", args = { server_id = serverId } }),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:unequipItem")
AddEventHandler("stdb:unequipItem", function(slotId, equipKey, targetPanel, targetIndex)
    local player   = source
    local serverId = tonumber(player)
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data or not data.owner_id then return end
            callSidecar("transfer_item", {
                slot_id        = slotId,
                new_owner_id   = data.owner_id,
                new_owner_type = "player",
                new_slot_index = targetIndex,
            })
        end,
        "POST",
        json.encode({ name = "get_player_inventory", args = { server_id = serverId } }),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:dropItem")
AddEventHandler("stdb:dropItem", function(slotId, quantity, itemId, propModel, skipPropSpawn)
    local player = source
    local pos    = GetEntityCoords(GetPlayerPed(player))

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, result = pcall(json.decode, body)
            if not ok or not result then return end
            if result.stash_id and result.stash_id ~= "" then
                Citizen.SetTimeout(150, function()
                    broadcastInventoryUpdate("stash", result.stash_id)
                end)
                if propModel and propModel ~= "" and not skipPropSpawn then
                    -- Delay slightly to let SpacetimeDB commit and return real slot ID
                    Citizen.SetTimeout(300, function()
                        PerformHttpRequest(SIDECAR_URL .. "reducer",
                            function(s2, b2, _)
                                local ok2, slots = pcall(json.decode, b2)
                                if ok2 and slots and slots.slots then
                                    local newSlotId = slotId
                                    for _, sl in ipairs(slots.slots) do
                                        newSlotId = sl.id
                                        break
                                    end
                                    TriggerClientEvent("stdb:spawnWorldDrop", -1,
                                        newSlotId,
                                        result.stash_id,
                                        propModel,
                                        pos.x, pos.y, pos.z)
                                end
                            end,
                            "POST",
                            json.encode({ name = "get_inventory_slots", args = {
                                owner_type = "stash",
                                owner_id   = result.stash_id
                            }}),
                            { ["Content-Type"] = "application/json" }
                        )
                    end)
                end
            end
            broadcastInventoryUpdate("player", tostring(player))
        end,
        "POST",
        json.encode({ name = "drop_item_to_ground", args = {
            slot_id  = slotId,
            quantity = quantity or 0,
            x = pos.x, y = pos.y, z = pos.z,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:giveItem")
AddEventHandler("stdb:giveItem", function(slotId, targetServerId)
    local player   = source
    local serverId = tonumber(player)

    callSidecar("transfer_item_to_player", {
        slot_id        = slotId,
        server_id      = targetServerId,
        new_slot_index = 0, -- sidecar finds next free
    })

    Citizen.SetTimeout(150, function()
        broadcastInventoryUpdate("player", tostring(player))
        broadcastInventoryUpdate("player", tostring(targetServerId))
    end)
end)

RegisterNetEvent("stdb:finalizeThrow")
AddEventHandler("stdb:finalizeThrow", function(slotId, itemId, propModel, x, y, z)
    local player = source
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, result = pcall(json.decode, body)
            if not ok or not result then return end
            if result.stash_id and result.stash_id ~= "" then
                Citizen.SetTimeout(150, function()
                    broadcastInventoryUpdate("stash", result.stash_id)
                end)
                -- Spawn permanent prop with REAL stash ID so deletion works on pickup
                Citizen.SetTimeout(400, function()
                    PerformHttpRequest(SIDECAR_URL .. "reducer",
                        function(s2, b2, _)
                            local ok2, slots2 = pcall(json.decode, b2)
                            if ok2 and slots2 and slots2.slots then
                                local newSlotId = slotId
                                for _, sl in ipairs(slots2.slots) do
                                    newSlotId = sl.id
                                    break
                                end
                                TriggerClientEvent("stdb:spawnWorldDrop", -1,
                                    newSlotId,
                                    result.stash_id,
                                    propModel,
                                    x, y, z)
                            end
                        end,
                        "POST",
                        json.encode({ name = "get_inventory_slots", args = {
                            owner_type = "stash",
                            owner_id   = result.stash_id,
                        }}),
                        { ["Content-Type"] = "application/json" }
                    )
                end)
            end
            broadcastInventoryUpdate("player", tostring(player))
        end,
        "POST",
        json.encode({ name = "drop_item_to_ground", args = {
            slot_id  = slotId,
            quantity = 0,
            x = x, y = y, z = z,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterNetEvent("stdb:dropItemAt")
AddEventHandler("stdb:dropItemAt", function(slotId, quantity, itemId, propModel, x, y, z)
    local player = source
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, result = pcall(json.decode, body)
            if not ok or not result then return end
            if result.stash_id and result.stash_id ~= "" then
                Citizen.SetTimeout(150, function()
                    broadcastInventoryUpdate("stash", result.stash_id)
                end)
                Citizen.SetTimeout(400, function()
                    PerformHttpRequest(SIDECAR_URL .. "reducer",
                        function(s2, b2, _)
                            local ok2, slots2 = pcall(json.decode, b2)
                            if ok2 and slots2 and slots2.slots then
                                for _, sl in ipairs(slots2.slots) do
                                    TriggerClientEvent("stdb:spawnWorldDrop", -1,
                                        sl.id, result.stash_id,
                                        propModel, x, y, z)
                                    break
                                end
                            end
                        end,
                        "POST",
                        json.encode({ name = "get_inventory_slots", args = {
                            owner_type = "stash",
                            owner_id   = result.stash_id,
                        }}),
                        { ["Content-Type"] = "application/json" }
                    )
                end)
            end
            broadcastInventoryUpdate("player", tostring(player))
        end,
        "POST",
        json.encode({ name = "drop_item_to_ground", args = {
            slot_id  = slotId,
            quantity = quantity or 0,
            x = x, y = y, z = z,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

RegisterCommand("stdbgive", function(source, args)
    local targetId = tonumber(args[1]) or source
    local itemId   = args[2] or "weapon_pistol"
    local qty      = tonumber(args[3]) or 1
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            print("[stdbgive] " .. tostring(body))
            print("[stdbgive] Item given. Delta sync will handle the UI update.")
        end,
        "POST",
        json.encode({ name = "give_item_to_player", args = {
            server_id = targetId,
            item_id   = itemId,
            quantity  = qty,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end, true)

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(100) -- Check for changes 10 times per second
        
        PerformHttpRequest(SIDECAR_URL .. "slot-deltas", function(status, body, _)
            if status ~= 200 or not body then return end
            
            local ok, deltas = pcall(json.decode, body)
            if not (ok and #deltas > 0) then return end

            for _, delta in ipairs(deltas) do
                -- Logic: Find which player needs this update
                -- In SpacetimeDB, owner_id is the Hex Identity
                for src, info in pairs(openInventories) do
                    -- Check if the delta belongs to a player's open inventory
                    if delta.owner_id == info.primary.ownerId or (info.secondary and delta.owner_id == info.secondary.ownerId) then
                        TriggerClientEvent("stdb:applyInventoryDelta", src, delta)
                    end
                end
            end
        end, "GET", "")
    end
end)

print("[stdb-relay] Server ready — polling sidecar.")
