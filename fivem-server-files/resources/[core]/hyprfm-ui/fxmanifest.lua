-- hyprfm-ui/fxmanifest.lua

fx_version 'cerulean'
game 'gta5'

description 'HyprFM UI — unified NUI context for all game panels'
version '1.0.0'

client_scripts {
    'client/main.lua',
}

ui_page 'web/dist/index.html'

files {
    'web/dist/index.html',
    'web/dist/**/*',
}