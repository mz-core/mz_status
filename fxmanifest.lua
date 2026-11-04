fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'mz_status'
author 'Mazus'
description 'Server-authoritative survival status for mz_core'
version '1.0.0'

shared_scripts {
  '@ox_lib/init.lua',
  'config.lua'
}

server_scripts {
  'server/service.lua'
}

client_scripts {
  'client/main.lua'
}

dependencies {
  'ox_lib',
  'mz_core',
  'mz_inventory'
}
