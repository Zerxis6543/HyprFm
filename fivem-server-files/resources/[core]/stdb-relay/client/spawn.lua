-- client/spawn.lua
-- ── HyprFM Client-Side Opcode Dispatcher ─────────────────────────────────────
--
-- Receives opcode integers from the server relay and executes the
-- appropriate GTA5 native call.
--
-- Design rules:
--   • Table is defined ONCE at resource start — no table allocation per event
--   • Handlers are pure functions of (args) where args is the decoded array
--   • The whitelist for 0x9001 (CALL_LOCAL_NATIVE) is explicit — no arbitrary exec
--   • The stdb:executeNative event is preserved as a legacy alias for compatibility
-- ─────────────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════════════
-- CLIENT OPCODE DISPATCHER
-- Pre-allocated once — handlers are closures over the ped reference.
-- ═════════════════════════════════════════════════════════════════════════════

-- Pre-allocate the dispatch table at load time (not inside the event handler).
-- This means the VM creates the table once and reuses it for every event call.
local ClientDispatcher = {}

-- 0x1001  ENTITY:SET_COORDS
-- args: [x, y, z, xAxis, yAxis, clearArea]
ClientDispatcher[0x1001] = function(args)
    local ped = PlayerPedId()
    SetEntityCoords(ped, args[1], args[2], args[3], args[4], args[5], args[6], false)
end

-- 0x1002  ENTITY:SET_FROZEN
-- args: [frozen]
ClientDispatcher[0x1002] = function(args)
    FreezeEntityPosition(PlayerPedId(), args[1])
end

-- 0x1003  ENTITY:SET_MODEL
-- args: [model_hash]
-- Streams the model, waits for load, swaps, then releases the reference.
ClientDispatcher[0x1003] = function(args)
    local modelHash = args[1]
    RequestModel(modelHash)
    Citizen.CreateThread(function()
        local timeout = 0
        while not HasModelLoaded(modelHash) and timeout < 100 do
            Citizen.Wait(50); timeout = timeout + 1
        end
        if HasModelLoaded(modelHash) then
            SetPlayerModel(PlayerId(), modelHash)
            SetModelAsNoLongerNeeded(modelHash)
        end
    end)
end

-- 0x9001  ENGINE:CALL_LOCAL_NATIVE — cosmetic proxy
-- args: [nativeName, arg1, arg2, ...]
-- SECURITY: explicit whitelist — only approved cosmetic natives are allowed.
-- Never call SetEntityHealth, GiveWeaponToPed, etc. through this path.
-- Those have their own server-authoritative opcodes (0x1004, 0x1005).
local _nativeWhitelist = {
    PLAY_SOUND_FRONTEND      = function(a) PlaySoundFrontend(a[2] or -1, a[3] or "", a[4] or "", false) end,
    SET_CLOCK_TIME           = function(a) NetworkOverrideClockTime(a[2] or 12, a[3] or 0, a[4] or 0) end,
    SHAKE_GAMEPLAY_CAM       = function(a) ShakeGameplayCam(a[2] or "SMALL_EXPLOSION_SHAKE", a[3] or 0.5) end,
    SET_WEATHER_TYPE_NOW_PERSIST = function(a) SetWeatherTypePersist(a[2] or "CLEAR"); SetWeatherTypeNowPersist(a[2] or "CLEAR") end,
}

ClientDispatcher[0x9001] = function(args)
    local nativeName = args[1]
    local handler    = _nativeWhitelist[nativeName]
    if handler then
        handler(args)
    else
        print(("[stdb-relay] CLIENT: blocked unlisted native '%s'"):format(tostring(nativeName)))
    end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- EVENT HANDLER — stdb:executeOpcode
-- ═════════════════════════════════════════════════════════════════════════════

RegisterNetEvent("stdb:executeOpcode")
AddEventHandler("stdb:executeOpcode", function(opcode, args)
    -- args arrives as a Lua table (decoded by the server before sending)
    local handler = ClientDispatcher[opcode]
    if handler then
        handler(args)
    else
        print(("[stdb-relay] CLIENT: unhandled opcode 0x%04X"):format(opcode))
    end
end)

-- ── Legacy alias: stdb:executeNative ─────────────────────────────────────────
-- Kept for any external scripts that still fire this event.
-- Translates the old string-key format to the new opcode dispatch.
local _legacyKeyToOpcode = {
    SET_ENTITY_COORDS      = 0x1001,
    FREEZE_ENTITY_POSITION = 0x1002,
    SET_ENTITY_MODEL       = 0x1003,
}

RegisterNetEvent("stdb:executeNative")
AddEventHandler("stdb:executeNative", function(nativeKey, payloadJson)
    local opcode = _legacyKeyToOpcode[nativeKey]
    if not opcode then
        print("[stdb-relay] CLIENT legacy: no opcode mapping for " .. tostring(nativeKey))
        return
    end
    local ok, args = pcall(json.decode, payloadJson)
    if not ok or not args then
        print("[stdb-relay] CLIENT legacy: bad payload: " .. tostring(payloadJson))
        return
    end
    local handler = ClientDispatcher[opcode]
    if handler then handler(args) end
end)

-- ── Announce readiness to the server ─────────────────────────────────────────
AddEventHandler("onClientResourceStart", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    TriggerServerEvent("stdb:clientReady")
end)