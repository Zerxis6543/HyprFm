fx_version 'cerulean'
game 'gta5'

description 'STDB Relay — SpacetimeDB bridge'
version '1.0.0'

shared_scripts {
    'shared/vehicle_config.lua',
    'shared/constants.lua',
}

client_scripts {
    'client/spawn.lua',
}

server_scripts {
    'server/main.lua',
    'server/exports.lua',
}
