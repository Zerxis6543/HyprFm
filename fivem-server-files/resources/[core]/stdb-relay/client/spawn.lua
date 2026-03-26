RegisterNetEvent("stdb:executeNative")
AddEventHandler("stdb:executeNative", function(nativeKey, payloadJson)
    local ok, args = pcall(json.decode, payloadJson)
    if not ok or not args then
        print("[stdb-relay] Bad native payload: " .. tostring(payloadJson))
        return
    end

    local ped = PlayerPedId()

    if nativeKey == "SET_ENTITY_COORDS" then
        SetEntityCoords(ped, args[1], args[2], args[3], args[4], args[5], args[6], false)
    elseif nativeKey == "FREEZE_ENTITY_POSITION" then
        FreezeEntityPosition(ped, args[1])
    elseif nativeKey == "SET_ENTITY_MODEL" then
        RequestModel(args[1])
        while not HasModelLoaded(args[1]) do Citizen.Wait(10) end
        SetPlayerModel(PlayerId(), args[1])
        SetModelAsNoLongerNeeded(args[1])
    else
        print("[stdb-relay] Unhandled client native: " .. tostring(nativeKey))
    end
end)

-- Tell the server we are fully loaded and ready
AddEventHandler("onClientResourceStart", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    TriggerServerEvent("stdb:clientReady")
end)
