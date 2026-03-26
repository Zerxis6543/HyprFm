-- G:\FivemSTDBProject\fivem-server-files\resources\[core]\stdb-relay\fxmanifest.lua
-- COMPLETE FILE — replace entire contents

fx_version 'cerulean'
game 'gta5'

description 'STDB Relay — SpacetimeDB bridge'
version '1.0.0'

-- vehicle_config.lua is shared so both server and client can call VehicleConfig.GetConfig()
shared_scripts {
    'shared/vehicle_config.lua',
}

client_scripts {
    'client/spawn.lua',
}

server_scripts {
    'server/main.lua',
    'server/exports.lua',
}
