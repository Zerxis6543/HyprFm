local isOpen       = false
local inVehicle    = false
local currentPlate = nil
local currentModel = nil
local currentClass = nil
local playerStats = { hunger = 100, thirst = 100, health = 200 }
local worldProps = {}  -- list of { prop, stashId }

-- Force-stream throwing dictionaries at resource start
Citizen.CreateThread(function()
    Citizen.Wait(5000)  -- wait for player to fully spawn
    local ped = PlayerPedId()
    local hash = GetHashKey("WEAPON_SMOKEGRENADE")
    GiveWeaponToPed(ped, hash, 1, false, false)
    
    local dicts = {"weapons@projectiles@", "melee@unarmed@streamed_core_fps"}
    for _, dict in ipairs(dicts) do
        RequestAnimDict(dict)
        local t = 0
        while not HasAnimDictLoaded(dict) and t < 60 do
            Citizen.Wait(50); t = t + 1
        end
    end
    
    RemoveWeaponFromPed(ped, hash)
end)

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

-- ── Weapon system ─────────────────────────────────────────────────────────────
local WEAPON_HASHES = {
    weapon_pistol = GetHashKey("WEAPON_PISTOL"),
    weapon_knife  = GetHashKey("WEAPON_KNIFE"),
    assault_rifle = GetHashKey("WEAPON_ASSAULTRIFLE"),
}

local equippedWeapons = {}

local isWeaponAnimating = false

local function equipWeapon(itemId, equipKey)
    local hash = WEAPON_HASHES[itemId]
    if not hash then return end
    if isWeaponAnimating then return end
    local ped = PlayerPedId()
    Citizen.CreateThread(function()
        isWeaponAnimating = true

        -- Give with 0 ammo so weapon is visible but can't fire
        GiveWeaponToPed(ped, hash, 0, false, true)
        SetCurrentPedWeapon(ped, hash, true)

        RequestAnimDict("reaction@intimidation@1h")
        local t = 0
        while not HasAnimDictLoaded("reaction@intimidation@1h") and t < 20 do
            Citizen.Wait(50); t = t + 1
        end
        TaskPlayAnim(ped, "reaction@intimidation@1h", "intro",
            8.0, -8.0, -1, 48, 0, false, false, false)

         local animStart = GetGameTimer()
        while not IsEntityPlayingAnim(ped, "reaction@intimidation@1h", "intro", 3)
              and (GetGameTimer() - animStart) < 500 do
            Citizen.Wait(0)
        end
        animStart = GetGameTimer()
        while IsEntityPlayingAnim(ped, "reaction@intimidation@1h", "intro", 3)
              and (GetGameTimer() - animStart) < 2500 do
            Citizen.Wait(0)
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
        end
        ClearPedTasks(ped)
        SetPedAmmo(ped, hash, 9999)
        equippedWeapons[equipKey] = hash
        isWeaponAnimating = false
    end)
end

local function unequipWeapon(equipKey)
    local hash = equippedWeapons[equipKey]
    if not hash then return end
    if isWeaponAnimating then return end
    local ped = PlayerPedId()
    equippedWeapons[equipKey] = nil
    Citizen.CreateThread(function()
        isWeaponAnimating = true

        -- Zero ammo so can't fire during holster
        SetPedAmmo(ped, hash, 0)

        RequestAnimDict("reaction@intimidation@1h")
        local t = 0
        while not HasAnimDictLoaded("reaction@intimidation@1h") and t < 20 do
            Citizen.Wait(50); t = t + 1
        end
        TaskPlayAnim(ped, "reaction@intimidation@1h", "outro",
            8.0, -8.0, -1, 48, 0, false, false, false)

        local animStart = GetGameTimer()
        while not IsEntityPlayingAnim(ped, "reaction@intimidation@1h", "outro", 3)
              and (GetGameTimer() - animStart) < 500 do
            Citizen.Wait(0)
        end
        animStart = GetGameTimer()
        while IsEntityPlayingAnim(ped, "reaction@intimidation@1h", "outro", 3)
              and (GetGameTimer() - animStart) < 2000 do
            Citizen.Wait(0)
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
        end
        ClearPedTasks(ped)
        RemoveWeaponFromPed(ped, hash)
        isWeaponAnimating = false
    end)
end

-- Active weapon slot (currently equipped to ped)
local activeWeaponSlot = nil

local function activateSlot(equipKey)
    -- Get equipped slots from NUI store via a fetch
    fetch = fetch or function() end  -- no-op guard
    -- Use SendNUIMessage to request slot info back
    -- Instead, track locally via equippedWeapons table
    -- If this slot has a weapon active, remove it (toggle off)
    if activeWeaponSlot == equipKey then
        unequipWeapon(equipKey)
        activeWeaponSlot = nil
        return
    end
    -- Deactivate previous active slot
    if activeWeaponSlot then
        unequipWeapon(activeWeaponSlot)
        activeWeaponSlot = nil
    end
    -- We need item info from the store — request via NUI message
    SendNUIMessage({ action = "activateSlot", equipKey = equipKey })
end

-- Listen for slot activation response from NUI
RegisterNUICallback("activateSlot", function(data, cb)
    local equipKey = data.equipKey
    local itemId   = data.itemId
    if not itemId then cb({ ok = true }); return end

    if WEAPON_HASHES[itemId] then
        equipWeapon(itemId, equipKey)
        activeWeaponSlot = equipKey
    else
        -- Non-weapon: trigger use via server
        TriggerServerEvent("stdb:useItemByKey", equipKey)
    end
    cb({ ok = true })
end)

-- ── Hotkey thread ─────────────────────────────────────────────────────────────
local SLOT_KEYS = {
    [0x71] = "weapon_primary",   -- key 1 (INPUT_SELECT_WEAPON_UNARMED)
    [0x72] = "weapon_secondary", -- key 2
    [0x73] = "hotkey_1",         -- key 3
    [0x74] = "hotkey_2",         -- key 4
    [0x75] = "hotkey_3",         -- key 5
}

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        if isOpen or isInspecting then goto continueHotkeys end

        if IsControlJustPressed(0, 157) then activateSlot("weapon_primary")   end  -- 1
        if IsControlJustPressed(0, 158) then activateSlot("weapon_secondary") end  -- 2
        if IsControlJustPressed(0, 159) then activateSlot("hotkey_1")         end  -- 3
        if IsControlJustPressed(0, 160) then activateSlot("hotkey_2")         end  -- 4
        if IsControlJustPressed(0, 161) then activateSlot("hotkey_3")         end  -- 5

        ::continueHotkeys::
    end
end)

-- ── Consume animations ────────────────────────────────────────────────────────
local isConsuming = false

local function playConsumeAnimation(animDict, animClip, duration, onComplete)
    if isConsuming then return end
    isConsuming = true
    RequestAnimDict(animDict)
    local t = 0
    while not HasAnimDictLoaded(animDict) and t < 40 do
        Citizen.Wait(50); t = t + 1
    end
    local ped = PlayerPedId()
    TaskPlayAnim(ped, animDict, animClip, 8.0, -8.0, duration, 49, 0, false, false, false)
    Citizen.CreateThread(function()
        local elapsed = 0
        while elapsed < duration and isConsuming do
            Citizen.Wait(0)
            SetTextFont(4)
            SetTextScale(0.0, 0.28)
            SetTextColour(255, 255, 255, 200)
            SetTextCentre(true)
            SetTextEntry("STRING")
            AddTextComponentString("BKSP TO CANCEL")
            DrawText(0.5, 0.93)
            if IsControlJustPressed(0, 177) then
                isConsuming = false
                ClearPedTasks(ped)
                return
            end
            elapsed = elapsed + 0
            Citizen.Wait(0)
        end
        if isConsuming then
            isConsuming = false
            if onComplete then onComplete() end
        end
    end)
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

-- ── Disable GTA default TAB UI ────────────────────────────────────────────────
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        -- Hide weapon wheel (TAB)
        DisableControlAction(0, 37, true)   -- INPUT_SELECT_WEAPON
        DisableControlAction(0, 157, true)  -- INPUT_SELECT_WEAPON (on foot alt)
        DisableControlAction(0, 158, true)  -- INPUT_SELECT_WEAPON (vehicle)
        -- Hide vehicle tab switching (TAB in vehicle)
        DisableControlAction(27, 37, true)
        DisableControlAction(27, 157, true)
        DisableControlAction(27, 158, true)
        -- Hide the radio wheel that can appear on TAB in vehicles
        DisableControlAction(0, 96, true)   -- INPUT_VEH_RADIO_WHEEL
        -- Disable number keys from switching GTA weapon slots
        if IsDisabledControlJustPressed(0, 157) then activateSlot("weapon_primary")   end
        if IsDisabledControlJustPressed(0, 158) then activateSlot("weapon_secondary") end
        if IsDisabledControlJustPressed(0, 159) then activateSlot("hotkey_1")         end
        if IsDisabledControlJustPressed(0, 160) then activateSlot("hotkey_2")         end
        if IsDisabledControlJustPressed(0, 161) then activateSlot("hotkey_3")         end
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
        -- Store x/y/z so the proximity scan does pure arithmetic (no GetEntityCoords per prop)
        table.insert(worldProps, { prop = obj, stashId = stashId, x = x, y = y, z = z })
    end
    SetModelAsNoLongerNeeded(propHash)
end)

local PICKUP_RADIUS   = 3.0
local nearGroundStash = false
 
-- 500ms scan — pure arithmetic on stored coords, zero native calls per prop
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(500)
        if isOpen then nearGroundStash = false; goto continueProxScan end
 
        local pedPos  = GetEntityCoords(PlayerPedId())
        local closest = false
        for _, data in ipairs(worldProps) do
            if data.prop and DoesEntityExist(data.prop) then
                local dx = data.x - pedPos.x
                local dy = data.y - pedPos.y
                if dx * dx + dy * dy <= PICKUP_RADIUS * PICKUP_RADIUS then
                    closest = true; break
                end
            end
        end
        nearGroundStash = closest
 
        ::continueProxScan::
    end
end)
 
-- Per-frame hint draw
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        if not nearGroundStash or isOpen or isInspecting then goto continueProxDraw end
 
        DrawRect(0.5, 0.935, 0.20, 0.032, 8, 10, 14, 210)
 
        SetTextFont(4); SetTextScale(0.0, 0.22)
        SetTextColour(74, 222, 128, 255); SetTextCentre(false)
        SetTextEntry("STRING"); AddTextComponentString("TAB"); DrawText(0.416, 0.924)
 
        SetTextFont(4); SetTextScale(0.0, 0.22)
        SetTextColour(220, 220, 220, 200); SetTextCentre(false)
        SetTextEntry("STRING"); AddTextComponentString("Pick up nearby item"); DrawText(0.446, 0.924)
 
        ::continueProxDraw::
    end
end)

RegisterNUICallback("mergeStacks", function(data, cb)
    TriggerServerEvent("stdb:mergeStacks", data.srcSlotId, data.dstSlotId)
    cb({ ok = true })
end)

RegisterNUICallback("openBackpack", function(data, cb)
    TriggerServerEvent("stdb:openBackpack", data.bagItemId, data.bagSlotId)
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
        pos.x, pos.y, pos.z,
        data.propModel or ""
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

RegisterNUICallback("groundStashEmpty", function(data, cb)
    local stashId = data.stashId or ""
    if stashId == "" then cb({ ok = false }); return end
 
    -- Reverse iterate so table.remove is safe
    for i = #worldProps, 1, -1 do
        local propData = worldProps[i]
        if propData.stashId == stashId then
            if propData.prop and DoesEntityExist(propData.prop) then
                SetEntityAsMissionEntity(propData.prop, false, true)
                DeleteObject(propData.prop)
            end
            table.remove(worldProps, i)
            break
        end
    end
 
    cb({ ok = true })
end)

RegisterNetEvent("stdb:openBackpackPanel")
AddEventHandler("stdb:openBackpackPanel", function(ctx)
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
    -- If a weapon was active in this slot, remove it from ped
    if equippedWeapons[data.equipKey] then
        unequipWeapon(data.equipKey)
    end
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
        -- Bandage animation: applying bandage
        playConsumeAnimation("anim@heists@ornate_bank@hack", "hack_loop", 3000, function()
            local current = GetEntityHealth(ped)
            SetEntityHealth(ped, math.min(200, current + data.amount))
            playerStats.health = GetEntityHealth(ped)
            updateStatsNUI()
        end)

    elseif data.effect == "hunger" then
        -- Eating animation
        playConsumeAnimation("mp_player_inteat@burger", "loop", 3000, function()
            playerStats.hunger = math.min(100, playerStats.hunger + data.amount)
            updateStatsNUI()
        end)

    elseif data.effect == "thirst" then
        -- Drinking animation
        playConsumeAnimation("mp_player_intdrink", "loop_bottle", 3000, function()
            playerStats.thirst = math.min(100, playerStats.thirst + data.amount)
            updateStatsNUI()
        end)
    end
end)

-- ── Inspect mode ─────────────────────────────────────────────────────────────
local inspectProp      = nil
local inspectSlotId    = nil
local inspectItemId    = nil
local isInspecting     = false
local isThrowingAnim   = false  -- flag to pause coord setter during throw
local placementProp    = nil
local placementPropHash = nil

local NON_THROWABLE_ITEMS = {
    backpack    = true,
    duffel_bag  = true,
    body_armour = true,
    parachute   = true,
    weapon_pistol = true,
    assault_rifle = true,
    weapon_knife  = true,
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
    local slotToDrop   = inspectSlotId
    local itemIdToDrop = inspectItemId
    local propModel    = getItemProp(itemIdToDrop)

    local placePos = nil
    if placementProp and DoesEntityExist(placementProp) then
        placePos = GetEntityCoords(placementProp)
        DeleteObject(placementProp)
        placementProp = nil
    end
    if inspectProp and DoesEntityExist(inspectProp) then
        DetachEntity(inspectProp, true, true)
        DeleteObject(inspectProp)
        inspectProp = nil
    end

    cleanupInspect()

    if placePos then
        TriggerServerEvent("stdb:dropItemAt", slotToDrop, 0, itemIdToDrop, propModel,
            placePos.x, placePos.y, placePos.z)
    else
        local pos = GetEntityCoords(PlayerPedId())
        TriggerServerEvent("stdb:dropItem", slotToDrop, 0, itemIdToDrop, propModel, false)
    end
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
        DisableControlAction(0, 37, true)  -- INPUT_SELECT_WEAPON (weapon wheel)

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

        -- RMB: enter native grenade aim/throw mode
        if IsDisabledControlJustPressed(0, 25) and not NON_THROWABLE_ITEMS[inspectItemId] then
            local throwSlot   = inspectSlotId
            local throwItemId = inspectItemId
            local throwProp   = inspectProp
            inspectProp       = nil
            isThrowingAnim    = true

            local inVeh       = IsPedInAnyVehicle(ped, false)
            local grenadeHash = GetHashKey("WEAPON_SMOKEGRENADE")
            local prevWeapon  = GetSelectedPedWeapon(ped)

            -- Show our prop at hand bone, hide grenade object each frame
            if throwProp and DoesEntityExist(throwProp) then
                SetEntityVisible(throwProp, true, false)
            end

            GiveWeaponToPed(ped, grenadeHash, 1, false, true)
            SetCurrentPedWeapon(ped, grenadeHash, true)

            -- Hide grenade, show our prop at hand bone each frame
            Citizen.CreateThread(function()
                while GetSelectedPedWeapon(ped) == grenadeHash do
                    Citizen.Wait(0)
                    local obj = GetCurrentPedWeaponEntityIndex(ped)
                    if obj and obj ~= 0 then
                        SetEntityVisible(obj, false, false)
                    end
                     if throwProp and DoesEntityExist(throwProp) then
                        local bx, by, bz = GetPedBoneCoords(ped, 28422, 0.0, 0.0, 0.0)
                        SetEntityCoords(throwProp, bx, by, bz, false, false, false, false)
                    end
                end
            end)

            local thrown    = false
            local cancelled = false

            -- Wait for player to throw (IsPedShooting) or cancel (Backspace)
            while not thrown and not cancelled do
                Citizen.Wait(0)
                DisableControlAction(0, 37, true)  -- hide weapon wheel during aim
                -- Don't disable controls — let GTA handle RMB aim and LMB throw natively
                if IsPedShooting(ped) then
                    thrown = true
                end
                if IsControlJustPressed(0, 177) then
                    cancelled = true
                end
            end

            -- Remove grenade weapon immediately
            RemoveWeaponFromPed(ped, grenadeHash)
            SetCurrentPedWeapon(ped, prevWeapon, true)

            if cancelled then
                if throwProp and DoesEntityExist(throwProp) then
                    SetEntityVisible(throwProp, true, false)
                end
                isThrowingAnim = false
                inspectProp    = throwProp
                goto continueInspect
            end

            -- Aggressively clear smoke grenade projectile for 1 second
            local pedPos = GetEntityCoords(ped)
            Citizen.CreateThread(function()
                for i = 1, 20 do
                    Citizen.Wait(50)
                    ClearAreaOfProjectiles(pedPos.x, pedPos.y, pedPos.z, 20.0, 0)
                    RemoveParticleFxInRange(pedPos.x, pedPos.y, pedPos.z, 20.0)
                end
            end)

            -- Capture throw direction from camera
            local camRot = GetGameplayCamRot(2)
            local pitch  = math.rad(camRot.x)
            local yaw    = math.rad(camRot.z)
            local fwdX   = -math.sin(yaw) * math.cos(pitch)
            local fwdY   =  math.cos(yaw) * math.cos(pitch)
            local fwdZ   =  math.sin(pitch)
            local power  = 40.0

            -- Launch our prop
            if throwProp and DoesEntityExist(throwProp) then
                SetEntityVisible(throwProp, true, false)
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
                ApplyForceToEntity(throwProp, 1,
                    fwdX * power,
                    fwdY * power,
                    (fwdZ * power) + 5.0,
                    0.0, 0.0, 0.0, 0, false, true, true, false, true)
            end

            -- Settle monitor
            local capturedSlot   = throwSlot
            local capturedItemId = throwItemId
            local capturedProp   = throwProp

            Citizen.CreateThread(function()
                Citizen.Wait(1000)
                local moving = true
                while moving do
                    Citizen.Wait(200)
                    if not capturedProp or not DoesEntityExist(capturedProp) then return end
                    local vel = GetEntityVelocity(capturedProp)
                    if #(vel) < 0.2 then
                        moving = false
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
    while true do
        Citizen.Wait(0)
        if not isInspecting then
            if placementProp and DoesEntityExist(placementProp) then
                DeleteObject(placementProp)
                placementProp     = nil
                placementPropHash = nil
            end
            goto continuePlacement
        end

        local ped    = PlayerPedId()
        local pedPos = GetEntityCoords(ped)
        local camRot = GetGameplayCamRot(2)
        local pitch  = math.rad(camRot.x)
        local yaw    = math.rad(camRot.z)
        local fwdX   = -math.sin(yaw) * math.cos(pitch)
        local fwdY   =  math.cos(yaw) * math.cos(pitch)
        local endX   = pedPos.x + fwdX * 3.0
        local endY   = pedPos.y + fwdY * 3.0

        local groundZ = 0.0
        local found, gz = GetGroundZFor_3dCoord(endX, endY, pedPos.z + 5.0, groundZ, false)
        if not found then goto continuePlacement end

        local hitCoords = vector3(endX, endY, gz)
        local propName  = getItemProp(inspectItemId)
        local propHash  = GetHashKey(propName)

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
    print(("[prop] CLIENT received deleteWorldProp stashId=" .. tostring(stashId)))
    print(("[prop] worldProps count=" .. #worldProps))
    local remaining = {}
    for _, data in ipairs(worldProps) do
        print(("[prop] checking entry stashId=" .. tostring(data.stashId)))
        if data.stashId == stashId then
            print("[prop] MATCH - deleting prop")
            if data.prop and DoesEntityExist(data.prop) then
                DeleteObject(data.prop)
            end
        else
            table.insert(remaining, data)
        end
    end
    worldProps = remaining
    print(("[prop] worldProps after cleanup=" .. #worldProps))
end)

RegisterNetEvent("stdb:slotDeltas")
AddEventHandler("stdb:slotDeltas", function(deltas)
    SendNUIMessage({ action = "applySlotDeltas", deltas = deltas })
end)


RegisterNUICallback("requestInventory", function(_, cb)
    local pos = GetEntityCoords(PlayerPedId())
    if inVehicle and currentVehicleId then
        TriggerServerEvent("stdb:requestGlovebox", currentVehicleId, currentModel, currentClass)
    else
        TriggerServerEvent("stdb:requestInventory", pos.x, pos.y, pos.z)
    end
    cb({ ok = true })
end)
