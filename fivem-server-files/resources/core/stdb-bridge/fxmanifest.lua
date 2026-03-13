fx_version 'cerulean'
game 'gta5'

author      'Your Name'
description 'SpacetimeDB Bridge — core routing layer'
version     '1.0.0'

-- clr_version '2' = Mono CLR2 runtime (the one FXServer actually ships)
-- Do NOT use 'dotnet' here — that is a different, newer runtime
clr_version '2'

-- FXServer reads compiled DLLs from bin/Release/ — NOT the .cs source files
server_scripts {
    'bin/Release/*.dll',
}

client_scripts {
    'client/events.lua',
}

dependencies {}