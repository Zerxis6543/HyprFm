-- server/modules.lua
-- ─────────────────────────────────────────────────────────────────────────────
-- HyprFM Module Discovery & Registration
--
-- Runs at stdb-relay resource start. Scans every started resource for
-- stdb_module metadata declarations and registers each with the C# sidecar.
--
-- IPC contract:
--   Lua  → discovers, validates JSON, checks file exists, fires HTTP
--   C#   → verifies WASM on disk (same host), stores in _moduleRegistry
--   STDB → unchanged; WASM publishing is a build-time, not runtime, concern
-- ─────────────────────────────────────────────────────────────────────────────

local SIDECAR_URL = "http://127.0.0.1:27200/"
local SELF_NAME   = GetCurrentResourceName()

-- ── In-memory registry ───────────────────────────────────────────────────────
-- Keyed by module name. Status is updated asynchronously when the sidecar
-- HTTP response arrives. Prevents double-registration across hot-reloads.
--   [name] → { resource: string, wasm_path: string, status: string }
local _moduleRegistry = {}

-- ── WASM existence check (server-side Lua has full io access) ────────────────
-- We gate on this BEFORE calling the sidecar so the error message can name
-- the exact file path — not just report a generic sidecar 500.
local function fileExists(absolutePath)
    local fh = io.open(absolutePath, "rb")
    if fh then io.close(fh); return true end
    return false
end

-- ── Register one validated module with the sidecar ───────────────────────────
-- Called only after JSON validation and WASM existence check pass.
local function registerModule(resourceName, moduleDef, absoluteWasmPath)
    local key = moduleDef.name

    -- Idempotent guard: skip if this module name was already registered this
    -- session. A duplicate name across two resources is a conflict, not an
    -- error — first-registered wins and the second emits a warning.
    if _moduleRegistry[key] then
        print(("[stdb-relay] SKIP: module '%s' already registered by resource '%s' — ignoring duplicate from '%s'"):format(
            key, _moduleRegistry[key].resource, resourceName))
        return
    end

    -- Optimistically write to local registry before the async HTTP response
    -- arrives. Status is "pending" until the sidecar confirms.
    _moduleRegistry[key] = {
        resource  = resourceName,
        wasm_path = absoluteWasmPath,
        status    = "pending",
    }

    print(("[stdb-relay] Registering module '%s' from resource '%s'"):format(key, resourceName))

    -- ── IPC step 1: POST to sidecar ──────────────────────────────────────────
    -- The sidecar performs a second File.Exists check so both the Lua and C#
    -- layers have an explicit record of the failure. This is intentional
    -- redundancy: Lua catches the error synchronously with a better message;
    -- C# catches it if the check races (e.g. the file is deleted mid-startup).
    PerformHttpRequest(
        SIDECAR_URL .. "modules/register",
        function(status, body, _)
            local parseOk, result = pcall(json.decode, body or "")
            local entry           = _moduleRegistry[key]
            if not entry then return end     -- resource stopped before response

            if status == 200 and parseOk and result and result.ok ~= false then
                entry.status = "registered"
                print(("[stdb-relay] ✓ Module '%s' registered (tables: %s)"):format(
                    key,
                    (#(moduleDef.tables or {}) > 0)
                        and table.concat(moduleDef.tables, ", ")
                        or  "(none declared)"))
            else
                entry.status = "failed"
                -- Surface the sidecar's error message verbatim so it shows
                -- the full wasm_path the sidecar expected to find.
                local reason = (parseOk and result and result.message)
                            or (parseOk and result and result.error)
                            or ("sidecar HTTP " .. tostring(status))
                print(("[stdb-relay] ✗ Module '%s' (resource '%s') FAILED: %s"):format(
                    key, resourceName, reason))
            end
        end,
        "POST",
        json.encode({
            name          = moduleDef.name,
            wasm_path     = absoluteWasmPath,
            resource_name = resourceName,
            tables        = moduleDef.tables   or {},
            database      = moduleDef.database or "fivem-game",
            version       = moduleDef.version  or "0.0.0",
        }),
        { ["Content-Type"] = "application/json" }
    )
end

-- ── Scan one resource for stdb_module metadata ───────────────────────────────
-- GetResourceMetadata with a sequential index is the FiveM-idiomatic way to
-- read repeated manifest keys. The loop breaks on the first nil/empty string.
local function scanResource(resourceName)
    local idx = 0

    while true do
        -- ── IPC step 0: read FiveM manifest metadata ─────────────────────────
        local raw = GetResourceMetadata(resourceName, "stdb_module", idx)
        if not raw or raw == "" then break end

        -- ── Guard 1: JSON parse ───────────────────────────────────────────────
        local ok, moduleDef = pcall(json.decode, raw)
        if not ok or type(moduleDef) ~= "table" then
            print(("[stdb-relay] WARN [%s]: stdb_module[%d] is not valid JSON"):format(
                resourceName, idx))
            print(("  → Got: %s"):format(tostring(raw)))
            print("  → Expected: '{\"name\":\"my_module\",\"wasm\":\"dist/my.wasm\"}'")
            idx = idx + 1
            goto nextEntry
        end

        -- ── Guard 2: required fields ─────────────────────────────────────────
        if type(moduleDef.name) ~= "string" or moduleDef.name == "" then
            print(("[stdb-relay] WARN [%s]: stdb_module[%d] missing required field 'name' (string)"):format(
                resourceName, idx))
            idx = idx + 1
            goto nextEntry
        end
        if type(moduleDef.wasm) ~= "string" or moduleDef.wasm == "" then
            print(("[stdb-relay] WARN [%s]: stdb_module[%d] '%s' missing required field 'wasm' (string)"):format(
                resourceName, idx, moduleDef.name))
            idx = idx + 1
            goto nextEntry
        end

        do
            -- Resolve the absolute path so the sidecar (same host, different
            -- process) can verify the file using standard .NET File.Exists().
            -- Normalise separators: GetResourcePath may return backslashes on Windows.
            local absoluteWasm = (GetResourcePath(resourceName) .. "/" .. moduleDef.wasm)
                :gsub("\\", "/")

            -- ── Guard 3: WASM existence ───────────────────────────────────────
            -- This is the highest-value check. Fail fast here with an actionable
            -- error before touching the network, so the developer can act on it
            -- immediately without reading sidecar logs.
            if not fileExists(absoluteWasm) then
                print(("[stdb-relay] ERROR: Module '%s' declared by resource '%s' — WASM not found."):format(
                    moduleDef.name, resourceName))
                print(("  → Expected path : %s"):format(absoluteWasm))
                print(("  → Declared wasm : %s"):format(moduleDef.wasm))
                print("  → Fix           : Run your build step (e.g. `cargo build --release`) before starting the server.")
                print(("  → Tip           : GetResourcePath('%s') + '/%s'"):format(
                    resourceName, moduleDef.wasm))
                idx = idx + 1
                goto nextEntry
            end

            registerModule(resourceName, moduleDef, absoluteWasm)
        end

        idx = idx + 1
        ::nextEntry::
    end
end

-- ── Full sweep across all started resources ───────────────────────────────────
-- Called once on our own resource start, after a delay for other resources
-- to finish loading and for the sidecar HTTP listener to come up.
local function discoverAllModules()
    local total = GetNumResources()
    local found = 0

    print(("[stdb-relay] Module discovery: scanning %d resource(s)..."):format(total))

    for i = 0, total - 1 do
        local name  = GetResourceByFindIndex(i)
        local state = name and GetResourceState(name)

        -- Only scan started resources that are not the relay itself.
        if name and name ~= "" and name ~= SELF_NAME and state == "started" then
            -- Cheap probe: skip resources with no stdb_module at all to
            -- avoid running the full scanResource loop on every resource.
            local probe = GetResourceMetadata(name, "stdb_module", 0)
            if probe and probe ~= "" then
                found = found + 1
                scanResource(name)
            end
        end
    end

    if found == 0 then
        print("[stdb-relay] Module discovery: no stdb_module declarations found in any running resource.")
    else
        print(("[stdb-relay] Module discovery: found %d resource(s) with stdb_module declarations."):format(found))
    end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- EVENT HANDLERS
-- ═════════════════════════════════════════════════════════════════════════════

-- ── Initial sweep: triggered when THIS resource starts ───────────────────────
-- The 3-second delay lets the sidecar HTTP listener come up and lets most
-- other resources finish their onResourceStart handlers. Without the delay,
-- GetResourceState may return "starting" for resources that haven't settled.
AddEventHandler("onResourceStart", function(name)
    if name ~= SELF_NAME then return end
    Citizen.SetTimeout(3000, discoverAllModules)
end)

-- ── Hot-registration: triggered when ANY other resource starts ────────────────
-- Handles txAdmin hot-restarts and /start commands without requiring a full
-- relay restart. The 500ms delay ensures GetResourceMetadata returns current
-- manifest values (not stale pre-start state).
AddEventHandler("onResourceStart", function(name)
    if name == SELF_NAME then return end
    Citizen.SetTimeout(500, function()
        local probe = GetResourceMetadata(name, "stdb_module", 0)
        if probe and probe ~= "" then
            print(("[stdb-relay] Hot-register: late resource '%s' declared stdb_module — scanning"):format(name))
            scanResource(name)
        end
    end)
end)

-- ── Clean up registry on resource stop ───────────────────────────────────────
-- Removes entries so a subsequent hot-start can re-register cleanly.
AddEventHandler("onResourceStop", function(name)
    for key, entry in pairs(_moduleRegistry) do
        if entry.resource == name then
            _moduleRegistry[key] = nil
            print(("[stdb-relay] Module '%s' unregistered (resource '%s' stopped)"):format(key, name))
        end
    end
end)

-- ═════════════════════════════════════════════════════════════════════════════
-- EXPORTS  (the "dumb" facade for community developers)
-- ═════════════════════════════════════════════════════════════════════════════

--- Returns a snapshot of all registered modules for this session.
--- Status values: "pending" | "registered" | "failed"
---
--- @return table  { [name] = { resource: string, status: string } }
---
--- Usage:
---   local mods = exports['stdb-relay']:GetRegisteredModules()
---   for name, info in pairs(mods) do
---       print(name, info.status, info.resource)
---   end
exports("GetRegisteredModules", function()
    local snapshot = {}
    for name, entry in pairs(_moduleRegistry) do
        -- Shallow copy — callers must not mutate the internal registry.
        snapshot[name] = { resource = entry.resource, status = entry.status }
    end
    return snapshot
end)