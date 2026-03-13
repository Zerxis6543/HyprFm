local isOpen       = false
local inVehicle    = false
local currentPlate = nil
local currentModel = nil
local currentClass = nil

-- World prop model map (client-side visual only)
local ITEM_PROPS = {
    default      = "prop_drug_package",
    cash         = "prop_amb_cash_note",
    burger       = "prop_cs_hotdog_01",
    phone        = "prop_npc_phone_02",
    bandage      = "prop_med_bag_01b",
    water_bottle = "prop_cs_beer_01",
    id_card      = "prop_notepad_01",
}

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
AddEventHandler("stdb:openInventory", function(slots, itemDefs, maxWeight, context)
    isOpen = true
    SetNuiFocus(true, true)
    TriggerScreenblurFadeIn(500)
    SendNUIMessage({
        action    = "openInventory",
        slots     = slots,
        itemDefs  = itemDefs,
        maxWeight = maxWeight or 85,
        context   = context,
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
AddEventHandler("stdb:spawnWorldDrop", function(slotId, x, y, z)
    -- slotId is passed for future use (e.g. linking prop to slot for cleanup)
    -- For now we look up the item from the NUI side; we spawn a generic prop
    local propName = ITEM_PROPS.default
    local propHash = GetHashKey(propName)

    RequestModel(propHash)
    local timeout = 0
    while not HasModelLoaded(propHash) and timeout < 40 do
        Citizen.Wait(50)
        timeout = timeout + 1
    end

    if HasModelLoaded(propHash) then
        local obj = CreateObject(propHash, x, y, z - 0.1, true, true, false)
        PlaceObjectOnGroundProperly(obj)
        FreezeEntityPosition(obj, true)
        SetEntityAsMissionEntity(obj, true, true)
    end
    SetModelAsNoLongerNeeded(propHash)
end)

RegisterNUICallback("mergeStacks", function(data, cb)
    TriggerServerEvent("stdb:mergeStacks", data.srcSlotId, data.dstSlotId)
    cb({ ok = true })
end)

RegisterNUICallback("openBackpack", function(data, cb)
    TriggerServerEvent("stdb:openBackpack", data.bagItemId)
    cb({ ok = true })
end)

-- ── NUI Callbacks ─────────────────────────────────────────────────────────────
RegisterNUICallback("close", function(_, cb)
    isOpen = false
    SetNuiFocus(false, false)
    TriggerScreenblurFadeOut(500)
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
    TriggerServerEvent("stdb:dropItem", data.slotId, data.quantity)
    cb("ok")
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