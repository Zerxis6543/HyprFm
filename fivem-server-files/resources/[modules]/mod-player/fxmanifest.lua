fx_version 'cerulean'
game 'gta5'

author      'Your Name'
description 'Player module — spawn, session, movement'
version     '1.0.0'

clr_version '2'

server_scripts {
    'bin/Release/*.dll',
}

-- CRITICAL: bridge must be loaded before this module
dependencies {
    'stdb-bridge',
}