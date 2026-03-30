-- ─────────────────────────────────────────────────────────────────────────────
-- HyprFM Relay — the thin bridge between FiveM natives and SpacetimeDB.
-- Principle: This file NEVER decides game state.
--            It routes instructions, forwards events, and nothing else.
-- ─────────────────────────────────────────────────────────────────────────────

print("[stdb-relay] SERVER MAIN LOADED")

local SIDECAR_URL = "http://127.0.0.1:27200/"

-- ═════════════════════════════════════════════════════════════════════════════
-- MODULE-LEVEL GLOBALS
-- Intentionally global (not local) so exports.lua, which is loaded AFTER this
-- file within the same resource, can safely reference them.
-- ═════════════════════════════════════════════════════════════════════════════

_volatileQueue       = {}   -- Instructions injected by InvokeNative — no HTTP cost
_identityToServerId  = {}   -- player identity hex  → FiveM server_id
_openStashToServerId = {}   -- stash_id / plate     → FiveM server_id
                            -- Both maps populated when any inventory panel opens
                            -- and cleared on close/disconnect. Together they cover
                            -- every panel type the delta push loop needs to reach.
_propOwnerServerId   = {}   -- ground stash_id → FiveM server_id of the player who
                            -- DROPPED the item and spawned the world prop.
                            -- Set when stdb:spawnWorldDrop fires.
                            -- NEVER cleared by stdb:closeInventory — only cleared
                            -- when the stash empties and the prop is deleted.
                            -- This prevents the close-before-delta race condition.

-- ═════════════════════════════════════════════════════════════════════════════
-- OPCODE DISPATCHER TABLE
-- Pre-allocated once at resource start; each entry is a pure function.
-- Mirrors opcodes.rs exactly — add entries here when new opcodes are added.
-- ═════════════════════════════════════════════════════════════════════════════

-- Helper: resolve net_id → owning FiveM player server-id
local function netToPlayer(netId)
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 then return nil end
    return NetworkGetEntityOwner(entity)
end

local Dispatcher = {}

-- 0x1001  ENTITY:SET_COORDS  — teleport ped to world coordinates
Dispatcher[0x1001] = function(netId, args)
    local pid = netToPlayer(netId)
    if pid then TriggerClientEvent("stdb:executeOpcode", pid, 0x1001, args) end
end

-- 0x1002  ENTITY:SET_FROZEN  — freeze / unfreeze ped position
Dispatcher[0x1002] = function(netId, args)
    local pid = netToPlayer(netId)
    if pid then TriggerClientEvent("stdb:executeOpcode", pid, 0x1002, args) end
end

-- 0x1003  ENTITY:SET_MODEL   — swap ped visual model
Dispatcher[0x1003] = function(netId, args)
    local pid = netToPlayer(netId)
    if pid then TriggerClientEvent("stdb:executeOpcode", pid, 0x1003, args) end
end

-- 0x1004  ENTITY:SET_HEALTH  — set raw GTA health value (100–200)
Dispatcher[0x1004] = function(netId, args)
    local pid = netToPlayer(netId)
    if pid then TriggerClientEvent("stdb:executeOpcode", pid, 0x1004, args) end
end

-- 0x1005  ENTITY:GIVE_WEAPON — give weapon + ammo to ped
Dispatcher[0x1005] = function(netId, args)
    local pid = netToPlayer(netId)
    if pid then TriggerClientEvent("stdb:executeOpcode", pid, 0x1005, args) end
end

-- 0x2001  EFFECT:HEAL   — restore HP with animation on owning client
Dispatcher[0x2001] = function(netId, args)
    local pid = netToPlayer(netId)
    if pid then
        TriggerClientEvent("stdb:applyEffect", pid, { effect = "heal",   amount = args[1] or 40 })
    end
end

-- 0x2002  EFFECT:HUNGER — restore hunger status
Dispatcher[0x2002] = function(netId, args)
    local pid = netToPlayer(netId)
    if pid then
        TriggerClientEvent("stdb:applyEffect", pid, { effect = "hunger", amount = args[1] or 30 })
    end
end

-- 0x2003  EFFECT:THIRST — restore thirst status
Dispatcher[0x2003] = function(netId, args)
    local pid = netToPlayer(netId)
    if pid then
        TriggerClientEvent("stdb:applyEffect", pid, { effect = "thirst", amount = args[1] or 30 })
    end
end

-- 0x9001  ENGINE:CALL_LOCAL_NATIVE — cosmetic proxy (whitelist enforced client-side)
Dispatcher[0x9001] = function(netId, args)
    local pid = netToPlayer(netId)
    if pid then TriggerClientEvent("stdb:executeOpcode", pid, 0x9001, args) end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- INSTRUCTION DISPATCH HELPER
-- Decodes the JSON payload array and routes to the correct Dispatcher entry.
-- ─────────────────────────────────────────────────────────────────────────────
local function dispatchInstruction(instr)
    local ok, args = pcall(json.decode, instr.payload or "[]")
    if not ok or type(args) ~= "table" then args = {} end

    local handler = Dispatcher[instr.opcode]
    if handler then
        handler(instr.target_entity_net_id, args)
    else
        print(("[stdb-relay] WARN: unhandled opcode 0x%04X"):format(instr.opcode or 0))
    end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- INSTRUCTION POLL LOOP  (100 ms cadence)
--
-- Phase 1 — Volatile queue drain:
--   Instructions inserted by InvokeNative() are dispatched without any HTTP
--   round-trip. This is the "zero-latency" path for cosmetic effects.
--
-- Phase 2 — Sidecar fetch:
--   Persisted instructions (spawns, heals, weapon gives) are fetched from the
--   C# sidecar, dispatched to the owning client, then ACK'd via POST /consumed.
--   SpacetimeDB marks them consumed so they are never replayed.
-- ═════════════════════════════════════════════════════════════════════════════

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(100)

        -- ── Phase 1: drain volatile queue (zero HTTP cost) ────────────────────
        if #_volatileQueue > 0 then
            local batch = _volatileQueue
            _volatileQueue = {}                         -- reset before processing
            for _, instr in ipairs(batch) do
                dispatchInstruction(instr)
            end
        end

        -- ── Phase 2: fetch persisted instructions from sidecar ────────────────
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

                -- ACK consumed IDs so SpacetimeDB marks them processed
                -- This prevents replay on sidecar reconnect
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

-- ═════════════════════════════════════════════════════════════════════════════
-- SLOT DELTA PUSH LOOP  (150 ms cadence)
--
-- The C# sidecar emits three event types to GET /slot-deltas:
--   "added"   — new slot inserted (e.g. item spawned or given)
--   "updated" — slot mutated, owner_id = NEW owner
--   "deleted" — slot removed, owner_id = OLD owner
--             ↑ also emitted for the OLD owner when owner changes (Program.cs fix)
--
-- Routing: we check BOTH lookup tables for each delta's owner_id, then group
-- by server_id so each player gets ONE batched TriggerClientEvent per tick
-- even when a single operation affects two of their panels simultaneously
-- (e.g. pickup: stash loses a slot AND pockets gains one).
-- ═════════════════════════════════════════════════════════════════════════════

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(150)

        PerformHttpRequest(SIDECAR_URL .. "slot-deltas",
            function(status, body, _)
                if status ~= 200 or not body or body == "" or body == "[]" then return end
                local ok, deltas = pcall(json.decode, body)
                if not ok or type(deltas) ~= "table" or #deltas == 0 then return end

                -- Group by server_id (recipient) not by owner_id.
                -- A single delta tick can produce entries for two different
                -- owner_ids that both resolve to the same player.
                local byServerId = {}
                for _, delta in ipairs(deltas) do
                    local oid = delta.owner_id or ""
                    if oid == "" then goto continueDelta end

                    -- Check identity map first (pockets/equip), then stash map
                    -- (ground stash, glovebox, trunk, backpack)
                    local sid = _identityToServerId[oid] or _openStashToServerId[oid]
                    if not sid then goto continueDelta end

                    if not byServerId[sid] then byServerId[sid] = {} end
                    byServerId[sid][#byServerId[sid] + 1] = delta

                    ::continueDelta::
                end

                for serverId, playerDeltas in pairs(byServerId) do
                    TriggerClientEvent("stdb:slotDeltas", serverId, playerDeltas)
                end

                -- ── Ground stash prop cleanup ─────────────────────────────────────────
                -- When the last item is removed from a ground stash (by pickup, drop,
                -- or any other reducer), the world prop should be deleted.
                --
                -- We use the EXISTING stdb:deleteWorldProp net event which already
                -- iterates worldProps and deletes the matching object. No NUI callback
                -- chain needed — the server owns this signal.
                --
                -- Guard: only check ground stashes (prefix "ground_") once per stash
                -- per tick, so rapid multi-slot deletions don't fan out extra queries.
                local checkedStashes = {}
                for _, delta in ipairs(deltas) do
                    if delta.type == "deleted" then
                        local oid = delta.owner_id or ""
                        -- Ground stash IDs are always "ground_<timestamp>" (see reducers.rs)
                        if oid:sub(1, 7) == "ground_" and not checkedStashes[oid] then
                            checkedStashes[oid] = true
                            print(("[prop] DELTA deleted for ground stash: " .. oid))
                            -- Use _propOwnerServerId, NOT _openStashToServerId.
                            -- _openStashToServerId is cleared by stdb:closeInventory
                            -- (which fires before the delta loop processes the deletion).
                            -- _propOwnerServerId is set at drop time and persists until
                            -- the prop is actually deleted.
                            local sid = _propOwnerServerId[oid]
                            print(("[prop] owner lookup for " .. oid .. " = " .. tostring(sid)))
                            if sid then
                                -- Query the sidecar for remaining slots in this stash.
                                -- If the count is 0, fire deleteWorldProp so the client
                                -- removes the prop from worldProps and calls DeleteObject.
                                PerformHttpRequest(SIDECAR_URL .. "reducer",
                                    function(qs, qb, _)
                                        if qs ~= 200 or not qb then return end
                                        local qok, qdata = pcall(json.decode, qb)
                                        local slotCount = qdata and qdata.slots and #qdata.slots or -1
                                        print(("[prop] slot count for " .. oid .. " = " .. slotCount))
                                        if qok and qdata and
                                           (not qdata.slots or #qdata.slots == 0) then
                                            print(("[prop] FIRING deleteWorldProp -> src=" .. sid .. " stash=" .. oid))
                                            TriggerClientEvent("stdb:deleteWorldProp", sid, oid)
                                            -- Prop deleted — clear the owner map entry
                                            _propOwnerServerId[oid] = nil
                                        end
                                    end,
                                    "POST",
                                    json.encode({ name = "get_inventory_slots", args = {
                                        owner_id   = oid,
                                        owner_type = "stash",
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

-- ═════════════════════════════════════════════════════════════════════════════
-- PLAYER LIFECYCLE
-- ═════════════════════════════════════════════════════════════════════════════

-- Fired by client/spawn.lua once the player's ped has fully spawned and its
-- net_id is valid. This is the authoritative connect signal for SpacetimeDB.
RegisterNetEvent("stdb:playerConnected")
AddEventHandler("stdb:playerConnected", function(netId, heading)
    local src        = source
    local playerName = GetPlayerName(src)
    local steamHex   = ""

    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if string.sub(id, 1, 6) == "steam:" then steamHex = id; break end
    end

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, _, _)
            if status == 200 then
                print(("[stdb-relay] '%s' (server_id=%d) registered with SpacetimeDB"):format(playerName, src))
            else
                print(("[stdb-relay] WARN: on_player_connect returned HTTP %d for '%s'"):format(status or 0, playerName))
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

-- FiveM built-in event — fires reliably on disconnect / timeout / kick
AddEventHandler("playerDropped", function(_reason)
    local src = source

    -- Remove from all maps so delta-push stops forwarding to this server-id
    for identity, sid in pairs(_identityToServerId) do
        if sid == src then _identityToServerId[identity] = nil; break end
    end
    for stashId, sid in pairs(_openStashToServerId) do
        if sid == src then _openStashToServerId[stashId] = nil end
    end
    for stashId, sid in pairs(_propOwnerServerId) do
        if sid == src then _propOwnerServerId[stashId] = nil end
    end

    -- Clear the active session in SpacetimeDB
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function() end, "POST",
        json.encode({ name = "on_player_disconnect", args = {} }),
        { ["Content-Type"] = "application/json" }
    )
end)

-- No-op — client announces readiness; reserved for future server-side init
RegisterNetEvent("stdb:clientReady")
AddEventHandler("stdb:clientReady", function() end)

-- ═════════════════════════════════════════════════════════════════════════════
-- INVENTORY: OPEN POCKETS + GROUND STASH
-- ═════════════════════════════════════════════════════════════════════════════

RegisterNetEvent("stdb:requestInventory")
AddEventHandler("stdb:requestInventory", function(x, y, z)
    local src = source

    -- 1. Fetch player slots, equipped slots, and backpack data
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(pi_status, pi_body, _)
            if pi_status ~= 200 or not pi_body then return end
            local pi_ok, pi = pcall(json.decode, pi_body)
            if not pi_ok or not pi then return end

            -- Register identity → server_id so delta-push can find this player
            if pi.owner_id and pi.owner_id ~= "" then
                _identityToServerId[pi.owner_id] = src
            end

            -- 2. Concurrently fetch/create the nearby ground stash
            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function(gs_status, gs_body, _)
                    local ground = {
                        type = "ground", label = "GROUND",
                        id = "", maxWeight = 999, maxSlots = 50, slots = {},
                    }
                    if gs_status == 200 and gs_body and gs_body ~= "" then
                        local gs_ok, gs = pcall(json.decode, gs_body)
                        if gs_ok and gs then
                            ground.id        = gs.stash_id   or ""
                            ground.maxWeight = gs.max_weight or 999
                            ground.maxSlots  = gs.max_slots  or 50
                            ground.slots     = gs.slots      or {}
                            -- Register ground stash id so delta-push can route
                            -- stash-owned slot changes back to this player
                            if ground.id ~= "" then
                                _openStashToServerId[ground.id] = src
                            end
                        end
                    end

                    -- 3. Send everything to the client NUI in one message
                    TriggerClientEvent("stdb:openInventory", src,
                        pi.slots          or {},
                        pi.item_defs       or {},
                        pi.max_weight      or 85,
                        ground,
                        pi.equipped_slots  or {},
                        pi.backpack_data
                    )
                end,
                "POST",
                json.encode({ name = "find_or_create_ground_stash", args = { x = x, y = y, z = z } }),
                { ["Content-Type"] = "application/json" }
            )
        end,
        "POST",
        json.encode({ name = "get_player_inventory", args = { server_id = src } }),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ═════════════════════════════════════════════════════════════════════════════
-- INVENTORY: OPEN VEHICLE GLOVEBOX
-- ═════════════════════════════════════════════════════════════════════════════

RegisterNetEvent("stdb:requestGlovebox")
AddEventHandler("stdb:requestGlovebox", function(vehicleId, modelName, vehicleClass)
    local src   = source
    local plate = tostring(vehicleId)

    -- Ensure the vehicle inventory config row exists (idempotent in Rust)
    local cfg = (VehicleConfig and VehicleConfig.GetConfig(modelName or "unknown", vehicleClass or 0))
        or { trunk_type = "rear", trunk_slots = 20, max_weight = 50 }

    PerformHttpRequest(SIDECAR_URL .. "reducer", function() end, "POST",
        json.encode({ name = "create_vehicle_inventory", args = {
            plate            = plate,
            model_hash       = 0,
            trunk_type       = cfg.trunk_type  or "rear",
            trunk_slots      = cfg.trunk_slots or 20,
            trunk_max_weight = cfg.max_weight  or 50,
        }}),
        { ["Content-Type"] = "application/json" }
    )

    -- Fetch player inventory
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(pi_status, pi_body, _)
            if pi_status ~= 200 or not pi_body then return end
            local pi_ok, pi = pcall(json.decode, pi_body)
            if not pi_ok or not pi then return end

            if pi.owner_id and pi.owner_id ~= "" then
                _identityToServerId[pi.owner_id] = src
            end
            -- Register plate so glovebox slot deltas reach this player
            _openStashToServerId[plate] = src

            -- Fetch glovebox slots
            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function(gb_status, gb_body, _)
                    if gb_status ~= 200 or not gb_body then return end
                    local gb_ok, gb = pcall(json.decode, gb_body)
                    if not gb_ok or not gb then return end

                    TriggerClientEvent("stdb:openInventory", src,
                        pi.slots          or {},
                        pi.item_defs       or {},
                        pi.max_weight      or 85,
                        {
                            type      = "glovebox",
                            label     = "GLOVEBOX",
                            id        = plate,
                            maxWeight = gb.max_weight or 10,
                            maxSlots  = gb.max_slots  or 5,
                            slots     = gb.slots      or {},
                        },
                        pi.equipped_slots  or {},
                        pi.backpack_data
                    )
                end,
                "POST",
                json.encode({ name = "get_vehicle_inventory", args = {
                    plate          = plate,
                    inventory_type = "glovebox",
                }}),
                { ["Content-Type"] = "application/json" }
            )
        end,
        "POST",
        json.encode({ name = "get_player_inventory", args = { server_id = src } }),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ═════════════════════════════════════════════════════════════════════════════
-- INVENTORY: OPEN VEHICLE TRUNK  (called from third-eye or proximity script)
-- ═════════════════════════════════════════════════════════════════════════════

RegisterNetEvent("stdb:requestTrunk")
AddEventHandler("stdb:requestTrunk", function(vehicleId, modelName, vehicleClass)
    local src   = source
    local plate = tostring(vehicleId)

    local cfg = (VehicleConfig and VehicleConfig.GetConfig(modelName or "unknown", vehicleClass or 0))
        or { trunk_type = "rear", trunk_slots = 20, max_weight = 50 }

    PerformHttpRequest(SIDECAR_URL .. "reducer", function() end, "POST",
        json.encode({ name = "create_vehicle_inventory", args = {
            plate            = plate, model_hash = 0,
            trunk_type       = cfg.trunk_type  or "rear",
            trunk_slots      = cfg.trunk_slots or 20,
            trunk_max_weight = cfg.max_weight  or 50,
        }}),
        { ["Content-Type"] = "application/json" }
    )

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(pi_status, pi_body, _)
            if pi_status ~= 200 or not pi_body then return end
            local pi_ok, pi = pcall(json.decode, pi_body)
            if not pi_ok or not pi then return end

            if pi.owner_id and pi.owner_id ~= "" then
                _identityToServerId[pi.owner_id] = src
            end
            -- Register plate so trunk slot deltas reach this player
            _openStashToServerId[plate] = src

            PerformHttpRequest(SIDECAR_URL .. "reducer",
                function(tr_status, tr_body, _)
                    if tr_status ~= 200 or not tr_body then return end
                    local tr_ok, tr = pcall(json.decode, tr_body)
                    if not tr_ok or not tr then return end

                    local trunkLabel = (tr.trunk_type == "front") and "FRUNK" or "TRUNK"
                    TriggerClientEvent("stdb:openInventory", src,
                        pi.slots or {}, pi.item_defs or {}, pi.max_weight or 85,
                        {
                            type      = "trunk",
                            label     = trunkLabel,
                            id        = plate,
                            maxWeight = tr.max_weight or cfg.max_weight  or 50,
                            maxSlots  = tr.max_slots  or cfg.trunk_slots or 20,
                            slots     = tr.slots      or {},
                        },
                        pi.equipped_slots or {}, pi.backpack_data
                    )
                end,
                "POST",
                json.encode({ name = "get_vehicle_inventory", args = {
                    plate = plate, inventory_type = "trunk",
                }}),
                { ["Content-Type"] = "application/json" }
            )
        end,
        "POST",
        json.encode({ name = "get_player_inventory", args = { server_id = src } }),
        { ["Content-Type"] = "application/json" }
    )
end)

-- SpacetimeDB maintains state persistently; no server action required on close.
-- Clear the open-stash map so stale stash deltas stop being forwarded after close.
RegisterNetEvent("stdb:closeInventory")
AddEventHandler("stdb:closeInventory", function()
    local src = source
    for stashId, sid in pairs(_openStashToServerId) do
        if sid == src then _openStashToServerId[stashId] = nil end
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- OWNER RESOLUTION / TYPE NORMALISATION
--
-- The TypeScript store uses UI-facing vocabulary for secondary.type:
--   "player" | "glovebox" | "trunk" | "ground" | "backpack" | "stash"
--
-- SpacetimeDB uses its own owner_type column values:
--   "player" | "vehicle_glovebox" | "vehicle_trunk" | "stash" | "equip"
--
-- This function is the ONLY place these two vocabularies meet.
-- Adding a new inventory panel type means one new entry here — nothing else
-- in Rust, C#, or TypeScript needs to change.
-- ─────────────────────────────────────────────────────────────────────────────

--- Translate a UI ownerType to the SpacetimeDB column value and resolve
--- an empty ownerId to the requesting player's identity hex when needed.
---
--- @param rawType   string   UI type from store.ts secondary.type / getOwnerForPanel()
--- @param rawId     string   Owner ID from the client (empty string for player pockets)
--- @param playerSrc number   FiveM server_id of the requesting player
--- @return string, string    resolvedType, resolvedId — ready for transfer_item
local function resolveOwner(rawType, rawId, playerSrc)
    if rawType == "player" then
        -- Player pockets: the TypeScript store sends ownerId = "" because it
        -- does not know the identity hex. Resolve it from the local map,
        -- populated the first time the player opens their inventory.
        local identityHex = (rawId and rawId ~= "") and rawId or ""
        if identityHex == "" then
            for identity, sid in pairs(_identityToServerId) do
                if sid == playerSrc then identityHex = identity; break end
            end
        end
        return "player", identityHex

    elseif rawType == "glovebox" then
        -- UI calls it "glovebox"; SpacetimeDB column is "vehicle_glovebox"
        return "vehicle_glovebox", rawId

    elseif rawType == "trunk" then
        -- UI calls it "trunk"; SpacetimeDB column is "vehicle_trunk"
        return "vehicle_trunk", rawId

    elseif rawType == "ground" then
        -- Ground drops share the generic "stash" owner_type.
        -- The stash_id in rawId already uniquely identifies the drop zone.
        return "stash", rawId

    elseif rawType == "backpack" then
        -- Backpack contents also live under owner_type = "stash".
        return "stash", rawId

    else
        -- Pass-through for types that already match the DB: "stash", "equip"
        return rawType, rawId
    end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- INVENTORY: ITEM MOVE / CROSS-PANEL TRANSFER
--
-- The TypeScript store emits TWO distinct fetch shapes to /moveItem:
--
--   Same-panel reorder:
--     { slotId, newSlotIndex }
--     → only slot_index changes; call move_item (owned-by check in Rust)
--
--   Cross-panel transfer:
--     { slotId, newSlotIndex, ownerType, ownerId }
--     → owner changes atomically; call transfer_item via resolveOwner()
--
-- We distinguish them purely by whether ownerType is present and non-empty.
-- resolveOwner() handles the UI→DB vocabulary translation for every panel type.
-- ═════════════════════════════════════════════════════════════════════════════

RegisterNetEvent("stdb:moveItem")
AddEventHandler("stdb:moveItem", function(slotId, newSlotIndex, ownerType, ownerId, _x, _y, _z, _propModel)
    local src = source

    -- ── Case 1: No ownerType ─ same-panel reorder ─────────────────────────────
    -- The TypeScript store omits ownerType entirely for same-panel moves,
    -- so this arrives as nil/"". Only the slot_index needs updating.
    if not ownerType or ownerType == "" then
        PerformHttpRequest(SIDECAR_URL .. "reducer",
            function() end, "POST",
            json.encode({ name = "move_item", args = {
                slot_id        = slotId,
                new_slot_index = newSlotIndex,
            }}),
            { ["Content-Type"] = "application/json" }
        )
        return
    end

    -- ── Case 2: ownerType present ─ cross-panel transfer ─────────────────────
    -- Translate the UI vocabulary to DB values and resolve the identity hex
    -- when the destination is the player's own pockets.
    local resolvedType, resolvedId = resolveOwner(ownerType, ownerId or "", src)

    -- Guard: if we couldn't resolve the player's identity (race condition on
    -- first connect) bail out rather than writing a corrupt empty owner_id.
    if resolvedType == "player" and (resolvedId == nil or resolvedId == "") then
        print(("[stdb-relay] stdb:moveItem: cannot resolve identity for server_id=%d; " ..
               "player may not have opened their inventory yet"):format(src))
        return
    end

    -- Register the transfer TARGET in _openStashToServerId immediately.
    -- C# OnUpdate emits an "updated" delta with owner_id = resolvedId.
    -- Without this registration, that delta has no route and is silently
    -- dropped — causing the item to vanish from the destination panel.
    -- This runs BEFORE the HTTP call so the delta loop is ready by the time
    -- SpacetimeDB commits the change (typically ~80ms later).
    if resolvedType ~= "player" and resolvedType ~= "equip"
       and resolvedId ~= nil and resolvedId ~= "" then
        _openStashToServerId[resolvedId] = src
    end

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function() end, "POST",
        json.encode({ name = "transfer_item", args = {
            slot_id        = slotId,
            new_owner_id   = resolvedId,
            new_owner_type = resolvedType,
            new_slot_index = newSlotIndex,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ═════════════════════════════════════════════════════════════════════════════
-- INVENTORY: USE ITEM
-- Server resolves the player's ped net_id so the Rust reducer can enqueue
-- the correct effect opcode for that specific entity.
-- ═════════════════════════════════════════════════════════════════════════════

RegisterNetEvent("stdb:useItem")
AddEventHandler("stdb:useItem", function(slotId)
    local src   = source
    local ped   = GetPlayerPed(src)
    local netId = NetworkGetNetworkIdFromEntity(ped)

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function() end, "POST",
        json.encode({ name = "use_item", args = { slot_id = slotId, net_id = netId } }),
        { ["Content-Type"] = "application/json" }
    )
end)

-- Use an item that is currently in an equipment slot (hotkey activation)
RegisterNetEvent("stdb:useItemByKey")
AddEventHandler("stdb:useItemByKey", function(equipKey)
    local src = source
    local ped = GetPlayerPed(src)
    local netId = NetworkGetNetworkIdFromEntity(ped)

    -- Resolve identity hex from our local map
    local identityHex = ""
    for identity, sid in pairs(_identityToServerId) do
        if sid == src then identityHex = identity; break end
    end
    if identityHex == "" then return end

    -- Fetch the equip slot to get the slot_id, then fire use_item
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
            owner_id   = identityHex .. "_equip_" .. equipKey,
            owner_type = "equip",
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ═════════════════════════════════════════════════════════════════════════════
-- INVENTORY: DROP ITEM
-- ═════════════════════════════════════════════════════════════════════════════

-- Drop at the player's current position (NUI "DROP" button)
RegisterNetEvent("stdb:dropItem")
AddEventHandler("stdb:dropItem", function(slotId, quantity, _itemId, propModel)
    local src = source
    local pos = GetEntityCoords(GetPlayerPed(src))

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data or not data.ok then return end
            -- Tell the client to spawn a world prop at the drop position
            -- Register this player as the prop owner BEFORE spawning the prop,
            -- so the delta loop can find them even after inventory is closed.
            if data.stash_id and data.stash_id ~= "" then
                _propOwnerServerId[data.stash_id] = src
                print(("[prop] DROP registered: stash=%s src=%d"):format(data.stash_id, src))
            end
            TriggerClientEvent("stdb:spawnWorldDrop", src,
                slotId, data.stash_id or "", propModel or "prop_cs_cardbox_01",
                pos.x, pos.y, pos.z
            )
        end,
        "POST",
        json.encode({ name = "drop_item_to_ground", args = {
            slot_id  = slotId,
            quantity = quantity or 0,
            x        = pos.x, y = pos.y, z = pos.z,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

-- Drop at an explicit world position (inspect-place mechanic)
RegisterNetEvent("stdb:dropItemAt")
AddEventHandler("stdb:dropItemAt", function(slotId, quantity, _itemId, propModel, x, y, z)
    local src = source
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data or not data.ok then return end
            if data.stash_id and data.stash_id ~= "" then
                _propOwnerServerId[data.stash_id] = src
                print(("[prop] PLACE registered: stash=%s src=%d"):format(data.stash_id, src))
            end
            TriggerClientEvent("stdb:spawnWorldDrop", src,
                slotId, data.stash_id or "", propModel or "prop_cs_cardbox_01",
                x, y, z
            )
        end,
        "POST",
        json.encode({ name = "drop_item_to_ground", args = {
            slot_id  = slotId,
            quantity = quantity or 0,
            x        = x, y = y, z = z,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

-- Finalize thrown item — physics have settled, record final world position
RegisterNetEvent("stdb:finalizeThrow")
AddEventHandler("stdb:finalizeThrow", function(slotId, _itemId, propModel, x, y, z)
    local src = source
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data or not data.ok then return end
            if data.stash_id and data.stash_id ~= "" then
                _propOwnerServerId[data.stash_id] = src
                print(("[prop] THROW registered: stash=%s src=%d"):format(data.stash_id, src))
            end
            TriggerClientEvent("stdb:spawnWorldDrop", src,
                slotId, data.stash_id or "", propModel or "prop_cs_cardbox_01",
                x, y, z
            )
        end,
        "POST",
        json.encode({ name = "drop_item_to_ground", args = {
            slot_id  = slotId,
            quantity = 0,           -- 0 = drop the full stack
            x        = x, y = y, z = z,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ═════════════════════════════════════════════════════════════════════════════
-- INVENTORY: STACK OPERATIONS
-- ═════════════════════════════════════════════════════════════════════════════

RegisterNetEvent("stdb:mergeStacks")
AddEventHandler("stdb:mergeStacks", function(srcSlotId, dstSlotId)
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function() end, "POST",
        json.encode({ name = "merge_stacks", args = {
            src_slot_id = srcSlotId,
            dst_slot_id = dstSlotId,
        }}),
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

-- ═════════════════════════════════════════════════════════════════════════════
-- INVENTORY: EQUIP / UNEQUIP
-- Equipment slots are modelled as owner_id = "<identityHex>_equip_<key>",
-- owner_type = "equip". This means equipping is just a transfer_item call.
-- ═════════════════════════════════════════════════════════════════════════════

RegisterNetEvent("stdb:equipItem")
AddEventHandler("stdb:equipItem", function(slotId, equipKey, _itemId)
    local src = source
    local identityHex = ""
    for identity, sid in pairs(_identityToServerId) do
        if sid == src then identityHex = identity; break end
    end
    if identityHex == "" then return end

    -- Transfer the slot into the virtual equip owner namespace
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function() end, "POST",
        json.encode({ name = "transfer_item", args = {
            slot_id        = slotId,
            new_owner_id   = identityHex .. "_equip_" .. equipKey,
            new_owner_type = "equip",
            new_slot_index = 0,
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

    -- Always unequip back to player pockets.
    -- TODO: To support unequip-to-secondary, the client should pass the full
    --       target owner_id and owner_type in the event data.
    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function() end, "POST",
        json.encode({ name = "transfer_item", args = {
            slot_id        = slotId,
            new_owner_id   = identityHex,
            new_owner_type = "player",
            new_slot_index = targetIndex or 0,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)

-- ═════════════════════════════════════════════════════════════════════════════
-- INVENTORY: BACKPACK
-- ═════════════════════════════════════════════════════════════════════════════

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

            -- Register backpack stash id so slot deltas reach this player
            local bpStashId = data.stash_id or ""
            if bpStashId ~= "" then
                _openStashToServerId[bpStashId] = src
            end
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

-- ═════════════════════════════════════════════════════════════════════════════
-- INVENTORY: GIVE ITEM TO NEARBY PLAYER  (inspect-give mechanic)
-- ═════════════════════════════════════════════════════════════════════════════

RegisterNetEvent("stdb:giveItem")
AddEventHandler("stdb:giveItem", function(slotId, targetServerId)
    local src = source

    PerformHttpRequest(SIDECAR_URL .. "reducer",
        function(status, body, _)
            if status ~= 200 or not body then return end
            local ok, data = pcall(json.decode, body)
            if not ok or not data then return end

            if data.ok then
                TriggerClientEvent("stdb:itemGiven",    src,          true)
                TriggerClientEvent("stdb:itemReceived", targetServerId, true)
            else
                TriggerClientEvent("stdb:itemGiven", src, false,
                    data.error_code or "UNKNOWN_ERROR",
                    data.actual_kg, data.max_kg
                )
            end
        end,
        "POST",
        json.encode({ name = "transfer_item_to_player", args = {
            slot_id   = slotId,
            server_id = targetServerId,
        }}),
        { ["Content-Type"] = "application/json" }
    )
end)