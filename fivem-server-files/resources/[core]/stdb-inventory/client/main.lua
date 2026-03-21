local isOpen       = false
local inVehicle    = false
local currentPlate = nil
local currentModel = nil
local currentClass = nil
local playerStats = { hunger = 100, thirst = 100, health = 200 }
local worldProps = {}  -- list of { prop, stashId }

local function deleteNearestWorldProp(x, y, z)
    local bestKey  = nil
    local bestDist = 5.0  -- max 5m
    for k, data in pairs(worldProps) do
        if data.prop and DoesEntityExist(data.prop) then
            local dist = #(vector3(data.x, data.y, data.z) - vector3(x, y, z))
            if dist < bestDist then
                bestDist = dist
                bestKey  = k
            end
        end
    end
    if bestKey then
        local prop = worldProps[bestKey].prop
        if DoesEntityExist(prop) then DeleteObject(prop) end
        worldProps[bestKey] = nil
    end
end
local function updateStatsNUI()
    SendNUIMessage({
        action = "updateStats",
        hunger = playerStats.hunger,
        thirst = playerStats.thirst,
        health = playerStats.health,
    })
end

-- Drain hunger/thirst over time
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(60000) -- every 60s
        playerStats.hunger = math.max(0, playerStats.hunger - 2)
        playerStats.thirst = math.max(0, playerStats.thirst - 3)
        updateStatsNUI()
    end
end)

-- World prop model map (client-side visual only)
local itemPropCache = {}  -- populated from itemDefs sent by server

local function getItemProp(itemId)
    return itemPropCache[itemId] or "prop_cs_cardbox_01"
end

local currentVehicleId = nil  -- stdb UUID, not plate

local function generateVehicleId()
    return string.format("veh_%x%x%x%x",
        math.random(0, 0xFFFF), math.random(0, 0xFFFF),
        math.random(0, 0xFFFF), math.random(0, 0xFFFF))
end

-- ── Vehicle tracking ──────────────────────────────────────────────────────────
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(500)
        local ped     = PlayerPedId()
        local vehicle = GetVehiclePedIsIn(ped, false)
        if vehicle ~= 0 then
            inVehicle    = true
            currentClass = GetVehicleClass(vehicle)
            currentModel = tostring(GetEntityModel(vehicle))
            currentPlate = GetVehicleNumberPlateText(vehicle):gsub("%s+", ""):upper()

            -- Use state bag UUID as the persistent vehicle identifier
            local existingId = Entity(vehicle).state.stdbVehicleId
            if existingId and existingId ~= "" then
                currentVehicleId = existingId
            else
                -- Only driver assigns the ID to avoid race conditions
                if GetPedInVehicleSeat(vehicle, -1) == ped then
                    local newId = generateVehicleId()
                    Entity(vehicle).state:set("stdbVehicleId", newId, true)
                    currentVehicleId = newId
                end
            end
        else
            inVehicle        = false
            currentPlate     = nil
            currentClass     = nil
            currentModel     = nil
            currentVehicleId = nil
        end
    end
end)
-- ── TAB — open inventory ──────────────────────────────────────────────────────
RegisterCommand("+openInventory", function()
    if isOpen then return end
    if inVehicle then
        -- If ID not yet available (passenger waiting for driver), poll briefly
        Citizen.CreateThread(function()
            local timeout = 0
            while not currentVehicleId and timeout < 20 do
                Citizen.Wait(100)
                timeout = timeout + 1
                -- Re-check state bag in case driver just set it
                local ped = PlayerPedId()
                local veh = GetVehiclePedIsIn(ped, false)
                if veh ~= 0 then
                    local sid = Entity(veh).state.stdbVehicleId
                    if sid and sid ~= "" then currentVehicleId = sid end
                end
            end
            if currentVehicleId then
                TriggerServerEvent("stdb:requestGlovebox", currentVehicleId, currentModel, currentClass)
            else
                -- Fallback: open pockets+ground if vehicle has no ID yet
                local pos = GetEntityCoords(PlayerPedId())
                TriggerServerEvent("stdb:requestInventory", pos.x, pos.y, pos.z)
            end
        end)
    else
        local pos = GetEntityCoords(PlayerPedId())
        TriggerServerEvent("stdb:requestInventory", pos.x, pos.y, pos.z)
    end
end, false)
RegisterKeyMapping("+openInventory", "Open Inventory", "keyboard", "TAB")

-- ── Unified open event (used for all inventory types now) ─────────────────────
RegisterNetEvent("stdb:openInventory")
AddEventHandler("stdb:openInventory", function(slots, itemDefs, maxWeight, context, equippedSlots, backpackData)
    isOpen = true
    SetNuiFocus(true, true)
    TriggerScreenblurFadeIn(500)
    -- Cache prop models from itemDefs
    if itemDefs then
        for id, def in pairs(itemDefs) do
            if def.prop_model then
                itemPropCache[id] = def.prop_model
            end
        end
    end
    SendNUIMessage({
        action         = "openInventory",
        slots          = slots,
        itemDefs       = itemDefs,
        maxWeight      = maxWeight or 85,
        context        = context,
        equippedSlots  = equippedSlots or {},
        backpackData   = backpackData,
    })
end)

-- Keep legacy events for compatibility (redirect to unified handler)
RegisterNetEvent("stdb:openGlovebox")
AddEventHandler("stdb:openGlovebox", function(playerSlots, gloveboxSlots, itemDefs, maxWeight, maxSlots, plate)
    isOpen = true
    SetNuiFocus(true, true)
    TriggerScreenblurFadeIn(500)
    SendNUIMessage({
        action    = "openInventory",
        slots     = playerSlots,
        itemDefs  = itemDefs,
        maxWeight = 85,
        context   = {
            type      = "glovebox",
            label     = "GLOVEBOX",
            id        = plate,
            maxWeight = maxWeight or 10,
            maxSlots  = maxSlots  or 5,
            slots     = gloveboxSlots,
        }
    })
end)

RegisterNetEvent("stdb:openTrunk")
AddEventHandler("stdb:openTrunk", function(playerSlots, trunkSlots, itemDefs, trunkType, maxWeight, maxSlots, plate)
    isOpen = true
    SetNuiFocus(true, true)
    TriggerScreenblurFadeIn(500)
    SendNUIMessage({
        action    = "openInventory",
        slots     = playerSlots,
        itemDefs  = itemDefs,
        maxWeight = 85,
        context   = {
            type      = "trunk",
            label     = (trunkType == "front") and "FRUNK" or "TRUNK",
            id        = plate,
            maxWeight = maxWeight or 0,
            maxSlots  = maxSlots  or 0,
            slots     = trunkSlots,
        }
    })
end)

RegisterNetEvent("stdb:openStash")
AddEventHandler("stdb:openStash", function(playerSlots, stashSlots, itemDefs, stashId, label, maxWeight, maxSlots)
    isOpen = true
    SetNuiFocus(true, true)
    TriggerScreenblurFadeIn(500)
    SendNUIMessage({
        action    = "openInventory",
        slots     = playerSlots,
        itemDefs  = itemDefs,
        maxWeight = 85,
        context   = {
            type      = "stash",
            label     = label or "STASH",
            id        = stashId,
            maxWeight = maxWeight or 100,
            maxSlots  = maxSlots  or 20,
            slots     = stashSlots,
        }
    })
end)

RegisterNetEvent("stdb:noTrunk")
AddEventHandler("stdb:noTrunk", function() end)

RegisterNetEvent("stdb:updateInventory")
AddEventHandler("stdb:updateInventory", function(slots)
    SendNUIMessage({ action = "updateInventory", slots = slots })
end)

-- ── World drop prop spawn ─────────────────────────────────────────────────────
RegisterNetEvent("stdb:spawnWorldDrop")
AddEventHandler("stdb:spawnWorldDrop", function(slotId, stashId, propModel, x, y, z)
    local propName = (propModel and propModel ~= "") and propModel or "prop_cs_cardbox_01"
    local propHash = GetHashKey(propName)
    RequestModel(propHash)
    local timeout = 0
    while not HasModelLoaded(propHash) and timeout < 40 do
        Citizen.Wait(50); timeout = timeout + 1
    end
    if HasModelLoaded(propHash) then
        local obj = CreateObject(propHash, x, y, z - 0.1, true, true, false)
        PlaceObjectOnGroundProperly(obj)
        FreezeEntityPosition(obj, true)
        SetEntityAsMissionEntity(obj, true, true)
        table.insert(worldProps, { prop = obj, stashId = stashId })
    end
    SetModelAsNoLongerNeeded(propHash)
end)

RegisterNUICallback("mergeStacks", function(data, cb)
    TriggerServerEvent("stdb:mergeStacks", data.srcSlotId, data.dstSlotId)
    cb({ ok = true })
end)

RegisterNUICallback("openBackpack", function(data, cb)
    print("[stdb-inventory] openBackpack NUI callback fired, bagItemId=" .. tostring(data.bagItemId))
    TriggerServerEvent("stdb:openBackpack", data.bagItemId)
    cb({ ok = true })
end)

-- ── NUI Callbacks ─────────────────────────────────────────────────────────────
RegisterNUICallback("close", function(_, cb)
    isOpen = false
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    TriggerScreenblurFadeOut(500)
    TriggerServerEvent("stdb:closeInventory")
    cb("ok")
end)

-- Passes targetOwnerType + targetOwnerId for cross-panel transfers
-- Passes player position for ground drops (world prop spawn)
RegisterNUICallback("moveItem", function(data, cb)
    local pos = GetEntityCoords(PlayerPedId())
    TriggerServerEvent("stdb:moveItem",
        data.slotId,
        data.newSlotIndex,
        data.ownerType or "",
        data.ownerId   or "",
        pos.x, pos.y, pos.z
    )
    cb("ok")
end)

RegisterNUICallback("useItem", function(data, cb)
    TriggerServerEvent("stdb:useItem", data.slotId)
    cb("ok")
end)

RegisterNUICallback("dropItem", function(data, cb)
    TriggerServerEvent("stdb:dropItem", data.slotId, data.quantity, data.itemId, data.propModel)
    cb("ok")
end)

RegisterNetEvent("stdb:openBackpackPanel")
AddEventHandler("stdb:openBackpackPanel", function(ctx)
    print("[stdb-inventory] openBackpackPanel received, label=" .. tostring(ctx.label))
    SendNUIMessage({
        action    = "openBackpackPanel",
        type      = ctx.type,
        label     = ctx.label,
        id        = ctx.id,
        maxWeight = ctx.maxWeight,
        maxSlots  = ctx.maxSlots,
        slots     = ctx.slots,
        item_defs = ctx.item_defs,
    })
end)

AddEventHandler("stdb:updateSecondary", function(ctx)
    SendNUIMessage({
        action     = "updateSecondary",
        type       = ctx.type,
        label      = ctx.label,
        id         = ctx.id,
        maxWeight  = ctx.maxWeight,
        maxSlots   = ctx.maxSlots,
        slots      = ctx.slots,
        item_defs  = ctx.item_defs,
    })
end)

RegisterNUICallback("splitStack", function(data, cb)
    TriggerServerEvent("stdb:splitStack", data.slotId, data.amount)
    cb({ ok = true })
end)

RegisterNUICallback("equipItem", function(data, cb)
    TriggerServerEvent("stdb:equipItem", data.slotId, data.equipKey)
    cb({ ok = true })
end)

RegisterNUICallback("unequipItem", function(data, cb)
    TriggerServerEvent("stdb:unequipItem", data.slotId, data.equipKey, data.targetPanel, data.targetIndex)
    cb({ ok = true })
end)

RegisterNetEvent("stdb:syncSlots")
AddEventHandler("stdb:syncSlots", function(data)
    SendNUIMessage({
        action    = "syncSlots",
        ownerType = data.ownerType,
        ownerId   = data.ownerId,
        slots     = data.slots,
    })
end)

RegisterNetEvent("stdb:applyEffect")
AddEventHandler("stdb:applyEffect", function(data)
    local ped = PlayerPedId()
    if data.effect == "heal" then
        local current = GetEntityHealth(ped)
        SetEntityHealth(ped, math.min(200, current + data.amount))
        playerStats.health = GetEntityHealth(ped)
    elseif data.effect == "hunger" then
        playerStats.hunger = math.min(100, playerStats.hunger + data.amount)
    elseif data.effect == "thirst" then
        playerStats.thirst = math.min(100, playerStats.thirst + data.amount)
    end
    updateStatsNUI()
end)

-- ── Inspect mode ─────────────────────────────────────────────────────────────
local inspectProp      = nil
local inspectSlotId    = nil
local inspectItemId    = nil
local isInspecting     = false
local isThrowingAnim   = false  -- flag to pause coord setter during throw
local placementProp    = nil
local placementPropHash = nil

local THROWABLE_ITEMS = {
    water_bottle = true,
    food_burger  = true,
    weed         = true,
    cocaine      = true,
    lockpick     = true,
}

local function cleanupInspect()
    SetNuiFocusKeepInput(false)
    isThrowingAnim = false
    if placementProp and DoesEntityExist(placementProp) then
        DeleteObject(placementProp)
    end
    placementProp     = nil
    placementPropHash = nil
    if inspectProp and DoesEntityExist(inspectProp) then
        DetachEntity(inspectProp, true, true)
        DeleteObject(inspectProp)
    end
    inspectProp   = nil
    isInspecting  = false
    inspectSlotId = nil
    inspectItemId = nil
end

local function cancelInspect()
    if not isInspecting then return end
    cleanupInspect()
    SendNUIMessage({ action = "cancelInspect" })
end

local function spawnInspectProp(itemId, callback)
    local propName = getItemProp(itemId)
    local propHash = GetHashKey(propName)
    RequestModel(propHash)
    local t = 0
    while not HasModelLoaded(propHash) and t < 40 do
        Citizen.Wait(50); t = t + 1
    end
    if HasModelLoaded(propHash) then
        local ped  = PlayerPedId()
        local pos  = GetEntityCoords(ped)
        local prop = CreateObject(propHash, pos.x, pos.y, pos.z, true, true, false)
        SetEntityCollision(prop, false, false)
        SetEntityAsMissionEntity(prop, true, true)
        SetModelAsNoLongerNeeded(propHash)
        if callback then callback(prop) end
    end
end

local function loadAnimDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    local t = 0
    while not HasAnimDictLoaded(dict) and t < 60 do
        Citizen.Wait(50); t = t + 1
    end
    return HasAnimDictLoaded(dict)
end

-- ── Hand prop coordinate setter (disabled during throw) ──────────────────────
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        if not isInspecting or isThrowingAnim then goto continueHandProp end
        if not inspectProp or not DoesEntityExist(inspectProp) then goto continueHandProp end
        local ped = PlayerPedId()
        local bx, by, bz = GetPedBoneCoords(ped, 28422, 0.0, 0.0, 0.0)
        SetEntityCoords(inspectProp, bx, by, bz, false, false, false, false)
        ::continueHandProp::
    end
end)

RegisterNUICallback("inspectItem", function(data, cb)
    inspectSlotId  = data.slotId
    inspectItemId  = data.itemId
    isInspecting   = true
    isThrowingAnim = false
    isOpen         = false
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(true)
    TriggerScreenblurFadeOut(200)
    spawnInspectProp(data.itemId, function(prop)
        inspectProp = prop
    end)
    -- Pre-load both anim dicts in background
    Citizen.CreateThread(function()
        loadAnimDict("melee@unarmed@streamed_core_fps")
        loadAnimDict("melee@large_wpn@streamed_core")
    end)
    SendNUIMessage({ action = "hideForInspect" })
    cb({ ok = true })
end)

RegisterCommand("+placeItem", function()
    if not isInspecting then return end
    if placementProp and DoesEntityExist(placementProp) then
        SetEntityAlpha(placementProp, 255, false)
        SetEntityCollision(placementProp, true, true)
        FreezeEntityPosition(placementProp, true)
        SetEntityAsMissionEntity(placementProp, true, true)
        placementProp = nil
    end
    if inspectProp and DoesEntityExist(inspectProp) then
        DetachEntity(inspectProp, true, true)
        DeleteObject(inspectProp)
        inspectProp = nil
    end
    local slotToDrop   = inspectSlotId
    local itemIdToDrop = inspectItemId
    cleanupInspect()
    TriggerServerEvent("stdb:dropItem", slotToDrop, 0, itemIdToDrop, getItemProp(itemIdToDrop), true)
    SendNUIMessage({ action = "cancelInspect" })
end, false)
RegisterKeyMapping("+placeItem", "Place Inspected Item", "keyboard", "e")

-- ── Inspect keybind loop ──────────────────────────────────────────────────────
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        if not isInspecting then goto continueInspect end

        local ped = PlayerPedId()

        DisableControlAction(0, 24, true)
        DisableControlAction(0, 25, true)

        -- G: Give to nearby player
        if IsControlJustPressed(0, 47) then
            local myPos     = GetEntityCoords(ped)
            local targetPed = nil
            for _, pid in ipairs(GetActivePlayers()) do
                if pid ~= PlayerId() then
                    local otherPed = GetPlayerPed(pid)
                    if #(myPos - GetEntityCoords(otherPed)) < 3.0 then
                        targetPed = otherPed
                        break
                    end
                end
            end
            if targetPed then
                local targetServerId = GetPlayerServerId(NetworkGetPlayerIndexFromPed(targetPed))
                if targetServerId and targetServerId ~= 0 then
                    local slotToGive = inspectSlotId
                    cleanupInspect()
                    TriggerServerEvent("stdb:giveItem", slotToGive, targetServerId)
                    SendNUIMessage({ action = "cancelInspect" })
                end
            end
            goto continueInspect
        end

        -- RMB hold to charge, release to throw
        if IsDisabledControlJustPressed(0, 25) and THROWABLE_ITEMS[inspectItemId] then
            local throwSlot   = inspectSlotId
            local throwItemId = inspectItemId
            local throwProp   = inspectProp
            inspectProp       = nil
            isThrowingAnim    = true  -- stop coord-setter immediately

            local power    = 10.0
            local maxPower = 30.0
            local cancelled = false
            local inVeh     = IsPedInAnyVehicle(ped, false)

            -- ── Charge phase: hold RMB ────────────────────────────────────
            while IsDisabledControlPressed(0, 25) do
                Citizen.Wait(0)
                DisableControlAction(0, 24, true)
                DisableControlAction(0, 25, true)
                power = math.min(power + 0.2, maxPower)

                local pct = power / maxPower
                SetTextFont(4)
                SetTextScale(0.0, 0.25)
                SetTextColour(255, 255, 255, 180)
                SetTextCentre(true)
                SetTextEntry("STRING")
                AddTextComponentString("THROW POWER")
                DrawText(0.5, 0.855)
                DrawRect(0.5, 0.875, 0.26, 0.016, 0, 0, 0, 180)
                local r = math.floor(255 * math.min(pct * 2, 1))
                local g = math.floor(255 * math.min((1 - pct) * 2, 1))
                DrawRect(0.5 - 0.13 + (pct * 0.13), 0.875, pct * 0.26, 0.016, r, g, 0, 220)

                if IsControlJustPressed(0, 177) then
                    cancelled = true
                    break
                end
            end

            if cancelled then
                isThrowingAnim = false
                inspectProp    = throwProp
                goto continueInspect
            end

            -- Capture camera direction at exact release moment
            local camRot = GetGameplayCamRot(2)
            local pitch  = math.rad(camRot.x)
            local yaw    = math.rad(camRot.z)
            local fwdX   = -math.sin(yaw) * math.cos(pitch)
            local fwdY   =  math.cos(yaw) * math.cos(pitch)
            local fwdZ   =  math.sin(pitch)
            local pedPos = GetEntityCoords(ped)

            -- ── Detach prop from coord-setter before anim ─────────────────
            if throwProp and DoesEntityExist(throwProp) then
                DetachEntity(throwProp, true, true)
                SetEntityCollision(throwProp, false, false)
                -- Re-attach to hand bone for the animation
                AttachEntityToEntity(throwProp, ped,
                    GetPedBoneIndex(ped, 28422),
                    0.12, 0.0, 0.0, 0.0, 0.0, 0.0,
                    true, true, false, true, 1, true)
            end
            Citizen.Wait(0)

            -- ── Task override: vehicle-aware ──────────────────────────────
            local animFlag = 48
            if inVeh then
                -- Upper body only so player stays seated
                animFlag = 49
            else
                ClearPedTasks(ped)
                Citizen.Wait(0)
            end

            -- ── Load and play toss animation ──────────────────────────────
            local animDict = nil
            local animClip = nil
            if HasAnimDictLoaded("melee@unarmed@streamed_core_fps") then
                animDict = "melee@unarmed@streamed_core_fps"
                animClip = "throw"
            elseif HasAnimDictLoaded("melee@large_wpn@streamed_core") then
                animDict = "melee@large_wpn@streamed_core"
                animClip = "ground_attack_on_spot"
            end

            if animDict then
                TaskPlayAnim(ped, animDict, animClip,
                    8.0, -8.0, 800, animFlag, 0, false, false, false)
            end

            -- ── Release point: 250ms — the "flick" moment ─────────────────
            Citizen.Wait(250)

            -- ── Physics release with arc ──────────────────────────────────
            if throwProp and DoesEntityExist(throwProp) then
                DetachEntity(throwProp, true, true)
                SetEntityCollision(throwProp, true, true)
                SetEntityAsMissionEntity(throwProp, true, true)
                SetEntityDynamic(throwProp, true)
                SetEntityCoords(throwProp,
                    pedPos.x + fwdX * 0.6,
                    pedPos.y + fwdY * 0.6,
                    pedPos.z + 1.0,
                    false, false, false, false)
                Citizen.Wait(0)
                Citizen.Wait(0)
                -- Horizontal velocity from power + 5.0 Z arc boost
                ApplyForceToEntity(throwProp, 1,
                    fwdX * power,
                    fwdY * power,
                    fwdZ * power + 5.0,
                    0.0, 0.0, 0.0,
                    0, false, true, true, false, true)
            end

            -- ── Settle monitor: watch velocity, finalize when stopped ─────
            local capturedSlot   = throwSlot
            local capturedItemId = throwItemId
            local capturedProp   = throwProp

            Citizen.CreateThread(function()
                Citizen.Wait(500)  -- let it fly first

                local settleTimer  = 0
                local maxWait      = 10000
                local settleThresh = 0.05

                while settleTimer < maxWait do
                    Citizen.Wait(100)
                    settleTimer = settleTimer + 100

                    if not capturedProp or not DoesEntityExist(capturedProp) then return end

                    local vel   = GetEntityVelocity(capturedProp)
                    local speed = math.sqrt(vel.x*vel.x + vel.y*vel.y + vel.z*vel.z)

                    if speed < settleThresh then
                        local finalPos = GetEntityCoords(capturedProp)
                        -- Fire server event FIRST — permanent prop spawns for all clients
                        TriggerServerEvent("stdb:finalizeThrow",
                            capturedSlot, capturedItemId,
                            getItemProp(capturedItemId),
                            finalPos.x, finalPos.y, finalPos.z)
                        -- Wait for network round-trip before removing local prop
                        Citizen.Wait(500)
                        if DoesEntityExist(capturedProp) then
                            DeleteObject(capturedProp)
                        end
                        return
                    end
                end

                -- Timeout fallback
                if capturedProp and DoesEntityExist(capturedProp) then
                    local finalPos = GetEntityCoords(capturedProp)
                    TriggerServerEvent("stdb:finalizeThrow",
                        capturedSlot, capturedItemId,
                        getItemProp(capturedItemId),
                        finalPos.x, finalPos.y, finalPos.z)
                    Citizen.Wait(500)
                    if DoesEntityExist(capturedProp) then
                        DeleteObject(capturedProp)
                    end
                end
            end)

            cleanupInspect()
            SendNUIMessage({ action = "cancelInspect" })
            goto continueInspect
        end

        -- Backspace: cancel, reopen inventory
        if IsControlJustPressed(0, 177) then
            cancelInspect()
            Citizen.SetTimeout(200, function()
                local pos = GetEntityCoords(PlayerPedId())
                TriggerServerEvent("stdb:requestInventory", pos.x, pos.y, pos.z)
            end)
        end

        ::continueInspect::
    end
end)

-- ── Placement preview ─────────────────────────────────────────────────────────
Citizen.CreateThread(function()
    local pendingRay = nil
    while true do
        Citizen.Wait(0)
        if not isInspecting then
            if placementProp and DoesEntityExist(placementProp) then
                DeleteObject(placementProp)
                placementProp     = nil
                placementPropHash = nil
            end
            pendingRay = nil
            goto continuePlacement
        end

        local ped    = PlayerPedId()
        local camPos = GetGameplayCamCoord()
        local camRot = GetGameplayCamRot(2)
        local pitch  = math.rad(camRot.x)
        local yaw    = math.rad(camRot.z)
        local fwdX   = -math.sin(yaw) * math.cos(pitch)
        local fwdY   =  math.cos(yaw) * math.cos(pitch)
        local fwdZ   =  math.sin(pitch)
        local endX   = camPos.x + fwdX * 5.0
        local endY   = camPos.y + fwdY * 5.0
        local endZ   = camPos.z + fwdZ * 5.0

        local hit       = false
        local hitCoords = vector3(endX, endY, endZ)
        if pendingRay then
            local retval, h, hc = GetShapeTestResult(pendingRay)
            if retval == 2 and h == 1 then
                hit       = true
                hitCoords = hc
            end
        end
        pendingRay = StartShapeTestRay(
            camPos.x, camPos.y, camPos.z,
            endX, endY, endZ, 1 + 16, ped, 0)

        if not hit then goto continuePlacement end

        local propName = getItemProp(inspectItemId)
        local propHash = GetHashKey(propName)

        if not placementProp or not DoesEntityExist(placementProp) or placementPropHash ~= propHash then
            if placementProp and DoesEntityExist(placementProp) then
                DeleteObject(placementProp)
            end
            RequestModel(propHash)
            local t3 = 0
            while not HasModelLoaded(propHash) and t3 < 20 do
                Citizen.Wait(50); t3 = t3 + 1
            end
            placementProp     = CreateObject(propHash, hitCoords.x, hitCoords.y, hitCoords.z, true, true, false)
            placementPropHash = propHash
            SetEntityAlpha(placementProp, 120, false)
            SetEntityCollision(placementProp, false, false)
            FreezeEntityPosition(placementProp, true)
            SetModelAsNoLongerNeeded(propHash)
        end

        SetEntityCoords(placementProp, hitCoords.x, hitCoords.y, hitCoords.z, false, false, false, false)
        PlaceObjectOnGroundProperly(placementProp)

        ::continuePlacement::
    end
end)

RegisterNetEvent("stdb:deleteWorldProp")
AddEventHandler("stdb:deleteWorldProp", function(stashId)
    local remaining = {}
    for _, data in ipairs(worldProps) do
        if data.stashId == stashId then
            if data.prop and DoesEntityExist(data.prop) then
                DeleteObject(data.prop)
            end
        else
            table.insert(remaining, data)
        end
    end
    worldProps = remaining
end)
