-- G:\FivemSTDBProject\fivem-server-files\resources\[core]\stdb-inventory\fxmanifest.lua
-- COMPLETE FILE — replace entire contents

fx_version 'cerulean'
game 'gta5'

description 'STDB Inventory UI'
version '1.0.0'

client_scripts {
    'client/main.lua',
}

ui_page 'web/dist/index.html'

files {
    'web/dist/index.html',
    'web/dist/**/*',
}
