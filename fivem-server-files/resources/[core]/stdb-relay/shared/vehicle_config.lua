-- G:\FivemSTDBProject\fivem-server-files\resources\[core]\stdb-relay\shared\vehicle_config.lua
--
-- Vehicle inventory configuration.
-- Trunk type:   "rear"  = trunk at back  (front-engine cars)
--               "front" = trunk at front (rear/mid-engine cars)
--               "none"  = no trunk (motorcycles, trucks, etc.)
-- Trunk weight and slots scale by vehicle class.
--
-- To customise a specific model, add it to VehicleConfig.models with its
-- lowercased model name (same as GetEntityModel → GetHashKey comparison).

VehicleConfig = {}

-- ── DEFAULT CONFIG BY GTA VEHICLE CLASS ──────────────────────────────────────
-- Class IDs match GetVehicleClass() native values.
VehicleConfig.classes = {
    [0]  = { name = "Compacts",        trunk_type = "rear",  trunk_slots = 15, max_weight = 40  },
    [1]  = { name = "Sedans",          trunk_type = "rear",  trunk_slots = 20, max_weight = 50  },
    [2]  = { name = "SUVs",            trunk_type = "rear",  trunk_slots = 25, max_weight = 70  },
    [3]  = { name = "Coupes",          trunk_type = "rear",  trunk_slots = 18, max_weight = 45  },
    [4]  = { name = "Muscle",          trunk_type = "rear",  trunk_slots = 15, max_weight = 45  },
    [5]  = { name = "Sports Classics", trunk_type = "rear",  trunk_slots = 12, max_weight = 35  },
    [6]  = { name = "Sports",          trunk_type = "rear",  trunk_slots = 12, max_weight = 35  },
    -- Super cars are mostly mid/rear engine — trunk at front
    [7]  = { name = "Super",           trunk_type = "front", trunk_slots = 10, max_weight = 30  },
    [8]  = { name = "Motorcycles",     trunk_type = "none",  trunk_slots = 0,  max_weight = 0   },
    [9]  = { name = "Off-road",        trunk_type = "rear",  trunk_slots = 20, max_weight = 60  },
    [10] = { name = "Industrial",      trunk_type = "none",  trunk_slots = 0,  max_weight = 0   },
    [11] = { name = "Utility",         trunk_type = "rear",  trunk_slots = 20, max_weight = 80  },
    [12] = { name = "Vans",            trunk_type = "rear",  trunk_slots = 30, max_weight = 120 },
    [13] = { name = "Cycles",          trunk_type = "none",  trunk_slots = 0,  max_weight = 0   },
    [14] = { name = "Boats",           trunk_type = "none",  trunk_slots = 0,  max_weight = 0   },
    [15] = { name = "Helicopters",     trunk_type = "none",  trunk_slots = 0,  max_weight = 0   },
    [16] = { name = "Planes",          trunk_type = "none",  trunk_slots = 0,  max_weight = 0   },
    [17] = { name = "Service",         trunk_type = "rear",  trunk_slots = 15, max_weight = 40  },
    [18] = { name = "Emergency",       trunk_type = "rear",  trunk_slots = 25, max_weight = 80  },
    [19] = { name = "Military",        trunk_type = "rear",  trunk_slots = 20, max_weight = 100 },
    [20] = { name = "Commercial",      trunk_type = "rear",  trunk_slots = 50, max_weight = 200 },
    [21] = { name = "Trains",          trunk_type = "none",  trunk_slots = 0,  max_weight = 0   },
}

-- ── PER-MODEL OVERRIDES ───────────────────────────────────────────────────────
-- Key = lowercased model name as used by GetEntityModel/GetHashKey.
-- These override the class defaults above.
VehicleConfig.models = {
    -- ── FRONT-ENGINE SPORTS THAT ARE ACTUALLY REAR/MID ENGINE ─────────────
    infernus    = { trunk_type = "front", trunk_slots = 10, max_weight = 25 },
    cheetah     = { trunk_type = "front", trunk_slots = 10, max_weight = 25 },
    entityxf    = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    turismor    = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    t20         = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    zentorno    = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    osiris      = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    vacca       = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    cheetah2    = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    reaper      = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    nero        = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    nero2       = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    italigtb    = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    italigtb2   = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    fmj         = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    visione     = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    penetrator   = { trunk_type = "front", trunk_slots = 10, max_weight = 25 },
    -- Porsche-style (front engine but class 7 override — normal rear trunk)
    growler     = { trunk_type = "rear",  trunk_slots = 10, max_weight = 30 },

    -- ── SPORTS CLASSICS — some are rear engine ────────────────────────────
    stinger     = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    stingergt   = { trunk_type = "front", trunk_slots = 8,  max_weight = 20 },
    coquette    = { trunk_type = "front", trunk_slots = 10, max_weight = 25 },
    coquette2   = { trunk_type = "front", trunk_slots = 10, max_weight = 25 },

    -- ── NO-TRUNK VEHICLES (override class defaults) ───────────────────────
    -- Tow trucks
    towtruck    = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    towtruck2   = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    -- Flatbeds / heavy haulers
    flatbed     = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    -- Dump/mining
    dump        = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    hauler      = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    hauler2     = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    phantom     = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    phantom2    = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    phantom3    = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    mule        = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    mule2       = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    mule3       = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    mule4       = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    pounder     = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    pounder2    = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    bulldozer   = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    -- Buses
    bus         = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    coach       = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    dashound    = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    -- Garbage
    trash       = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    trash2      = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    -- Tankers
    tanker      = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    tanker2     = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    -- Forklifts / service
    forklift    = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    tractor     = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    tractor2    = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },
    tractor3    = { trunk_type = "none", trunk_slots = 0, max_weight = 0 },

    -- ── VANS WITH EXTRA SPACE ─────────────────────────────────────────────
    rumpo       = { trunk_type = "rear", trunk_slots = 35, max_weight = 140 },
    rumpo2      = { trunk_type = "rear", trunk_slots = 35, max_weight = 140 },
    rumpo3      = { trunk_type = "rear", trunk_slots = 35, max_weight = 140 },
    burrito     = { trunk_type = "rear", trunk_slots = 35, max_weight = 140 },
    burrito2    = { trunk_type = "rear", trunk_slots = 35, max_weight = 140 },
    burrito3    = { trunk_type = "rear", trunk_slots = 35, max_weight = 140 },
    burrito4    = { trunk_type = "rear", trunk_slots = 35, max_weight = 140 },
    burrito5    = { trunk_type = "rear", trunk_slots = 35, max_weight = 140 },
}

-- ── STASH DEFINITIONS ─────────────────────────────────────────────────────────
-- World prop stashes that are registered automatically on resource start.
-- stash_id must be unique — use object hash + coords to guarantee uniqueness
-- when creating them at runtime. These are the default sizes.
VehicleConfig.stash_types = {
    dumpster       = { label = "Dumpster",        max_slots = 20, max_weight = 200 },
    dropbox        = { label = "Drop Box",         max_slots = 10, max_weight = 50  },
    locker_police  = { label = "Police Locker",    max_slots = 30, max_weight = 150 },
    locker_ems     = { label = "EMS Locker",       max_slots = 30, max_weight = 150 },
    locker_mechanic= { label = "Mechanic Locker",  max_slots = 25, max_weight = 120 },
    -- Player-created stashes (size set at creation time)
    player_stash   = { label = "Personal Stash",  max_slots = 25, max_weight = 100 },
    player_stash_l = { label = "Large Stash",     max_slots = 50, max_weight = 200 },
}

-- ── HELPER: Get config for a vehicle ─────────────────────────────────────────
-- Returns the merged config (model override wins over class default)
function VehicleConfig.GetConfig(modelName, vehicleClass)
    local override = VehicleConfig.models[modelName:lower()]
    if override then return override end
    return VehicleConfig.classes[vehicleClass] or { trunk_type = "none", trunk_slots = 0, max_weight = 0 }
end
