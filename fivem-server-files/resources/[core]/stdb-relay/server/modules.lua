local SIDECAR_URL = "http://127.0.0.1:27200/"
local SELF_NAME   = GetCurrentResourceName()

-- ── In-memory registry ───────────────────────────────────────────────────────
local _moduleRegistry = {}

-- ── WASM existence check (server-side Lua has full io access) ────────────────
local function fileExists(absolutePath)
    local fh = io.open(absolutePath, "rb")
    if fh then io.close(fh); return true end
    return false
end

-- ── Register one validated module with the sidecar ───────────────────────────
local function registerModule(resourceName, moduleDef, absoluteWasmPath)
    local key = moduleDef.name

    if _moduleRegistry[key] then
        print(("[stdb-relay] SKIP: module '%s' already registered by resource '%s' — ignoring duplicate from '%s'"):format(
            key, _moduleRegistry[key].resource, resourceName))
        return
    end


    _moduleRegistry[key] = {
        resource  = resourceName,
        wasm_path = absoluteWasmPath,
        status    = "pending",
    }

    print(("[stdb-relay] Registering module '%s' from resource '%s'"):format(key, resourceName))

    -- ── IPC step 1: POST to sidecar ──────────────────────────────────────────
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
            local absoluteWasm = (GetResourcePath(resourceName) .. "/" .. moduleDef.wasm)
                :gsub("\\", "/")

            -- ── Guard 3: WASM existence ───────────────────────────────────────
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
AddEventHandler("onResourceStart", function(name)
    if name ~= SELF_NAME then return end
    Citizen.SetTimeout(3000, discoverAllModules)
end)

-- ── Hot-registration: triggered when ANY other resource starts ────────────────
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