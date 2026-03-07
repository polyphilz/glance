if exists('g:loaded_glance')
  finish
endif
let g:loaded_glance = 1

command! Glance lua require('glance').start()
