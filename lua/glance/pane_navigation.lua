local config = require('glance.config')

local M = {}

local WINCMDS = {
  left = 'h',
  down = 'j',
  up = 'k',
  right = 'l',
}

local function set_buffer_keymap(buf, lhs, rhs)
  if lhs == nil or lhs == '' then
    return
  end

  vim.keymap.set('n', lhs, rhs, {
    noremap = true,
    silent = true,
    buffer = buf,
  })
end

function M.bind(buf)
  local pane = config.options.pane_navigation or {}

  for direction, wincmd in pairs(WINCMDS) do
    set_buffer_keymap(buf, pane[direction], function()
      vim.cmd.wincmd(wincmd)
    end)
  end
end

return M
