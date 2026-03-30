local config = require('glance.config')

local M = {}
local AUGROUP = vim.api.nvim_create_augroup('GlanceCommitEditor', { clear = true })

M.buf = nil
M.win = nil
M.on_submit = nil
M.on_cancel = nil
M.closing = false
M.suppress_win_closed = false
M.submitted = false

local function editor_zindex()
  return math.max((config.options.minimap.zindex or 50) + 10, 60)
end

local function float_config()
  local width = math.min(76, math.max(vim.o.columns - 8, 32))
  local editor_height = math.max(vim.o.lines - vim.o.cmdheight, 8)
  local height = math.min(14, math.max(editor_height - 6, 6))

  return {
    relative = 'editor',
    row = math.max(0, math.floor((editor_height - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' Commit (submit: <Esc> :w, cancel: <Esc> q) ',
    title_pos = 'center',
    zindex = editor_zindex(),
  }
end

local function apply_window_options(win)
  vim.api.nvim_win_set_option(win, 'wrap', true)
  vim.api.nvim_win_set_option(win, 'linebreak', true)
  vim.api.nvim_win_set_option(win, 'spell', true)
  vim.api.nvim_win_set_option(win, 'cursorline', false)
  vim.api.nvim_win_set_option(win, 'number', false)
  vim.api.nvim_win_set_option(win, 'relativenumber', false)
  vim.api.nvim_win_set_option(win, 'signcolumn', 'no')
  vim.api.nvim_win_set_option(win, 'winhighlight', 'FloatTitle:GlanceLegendKey')
end

local function buffer_valid()
  return M.buf and vim.api.nvim_buf_is_valid(M.buf)
end

local function window_valid()
  return M.win and vim.api.nvim_win_is_valid(M.win)
end

local function draft_is_dirty()
  if not buffer_valid() then
    return false
  end

  return vim.api.nvim_buf_get_option(M.buf, 'modified')
end

local function confirm_discard()
  return vim.fn.confirm('Discard commit message draft?', '&Discard\n&Cancel', 2) == 1
end

local function reset_state()
  pcall(vim.api.nvim_clear_autocmds, { group = AUGROUP })
  M.buf = nil
  M.win = nil
  M.on_submit = nil
  M.on_cancel = nil
  M.closing = false
  M.suppress_win_closed = false
  M.submitted = false
end

local function register_window_close_autocmd(win)
  vim.api.nvim_create_autocmd('WinClosed', {
    group = AUGROUP,
    pattern = tostring(win),
    once = true,
    callback = function()
      if M.closing or M.suppress_win_closed then
        return
      end

      vim.schedule(function()
        if not buffer_valid() then
          reset_state()
          return
        end

        if M.submitted then
          return
        end

        M.close({
          notify_cancel = true,
        })
      end)
    end,
  })
end

local function open_window()
  if not buffer_valid() then
    return nil
  end

  M.win = vim.api.nvim_open_win(M.buf, true, float_config())
  apply_window_options(M.win)
  register_window_close_autocmd(M.win)
  return M.win
end

local function setup_buffer()
  vim.api.nvim_buf_set_name(M.buf, 'glance://commit')
  vim.api.nvim_buf_set_option(M.buf, 'buftype', 'acwrite')
  vim.api.nvim_buf_set_option(M.buf, 'bufhidden', 'hide')
  vim.api.nvim_buf_set_option(M.buf, 'swapfile', false)
  vim.api.nvim_buf_set_option(M.buf, 'filetype', 'gitcommit')
  vim.api.nvim_buf_set_option(M.buf, 'modifiable', true)
  vim.api.nvim_buf_set_option(M.buf, 'readonly', false)
  vim.api.nvim_buf_set_option(M.buf, 'textwidth', 72)
end

local function setup_keymaps()
  local opts = { noremap = true, silent = true, buffer = M.buf }
  local function request_close()
    M.close({
      notify_cancel = true,
    })
  end

  vim.keymap.set('n', 'q', request_close, opts)
  vim.keymap.set('n', 'Q', request_close, opts)

  vim.keymap.set('n', 'ZZ', function()
    vim.cmd('write')
  end, opts)
end

local function setup_autocmds()
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = AUGROUP,
    buffer = M.buf,
    callback = function()
      local on_submit = M.on_submit
      if not on_submit or not buffer_valid() then
        return
      end

      local ok = on_submit(vim.api.nvim_buf_get_lines(M.buf, 0, -1, false))
      if not ok or not buffer_valid() then
        return
      end

      M.submitted = true
      vim.api.nvim_buf_set_option(M.buf, 'modified', false)

      vim.schedule(function()
        if buffer_valid() then
          M.close({
            force = true,
            notify_cancel = false,
          })
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    group = AUGROUP,
    buffer = M.buf,
    callback = function()
      reset_state()
    end,
  })

  vim.api.nvim_create_autocmd('VimResized', {
    group = AUGROUP,
    callback = function()
      if window_valid() then
        pcall(vim.api.nvim_win_set_config, M.win, float_config())
      end
    end,
  })
end

function M.is_open()
  return buffer_valid() and window_valid()
end

function M.focus()
  if not buffer_valid() then
    return false
  end

  if not window_valid() then
    open_window()
  end

  if not window_valid() then
    return false
  end

  vim.api.nvim_set_current_win(M.win)
  return true
end

function M.open(opts)
  opts = opts or {}

  if buffer_valid() then
    if opts.on_submit ~= nil then
      M.on_submit = opts.on_submit
    end
    if opts.on_cancel ~= nil then
      M.on_cancel = opts.on_cancel
    end
    if M.focus() then
      vim.cmd('startinsert')
    end
    return
  end

  reset_state()

  M.on_submit = opts.on_submit
  M.on_cancel = opts.on_cancel
  M.buf = vim.api.nvim_create_buf(false, false)

  setup_buffer()
  open_window()
  setup_keymaps()
  setup_autocmds()

  if window_valid() then
    vim.api.nvim_set_current_win(M.win)
    vim.cmd('startinsert')
  end
end

function M.close(opts)
  opts = opts or {}

  if not buffer_valid() then
    reset_state()
    return true
  end

  if not opts.force and draft_is_dirty() and not confirm_discard() then
    if not window_valid() then
      open_window()
    end
    M.focus()
    return false
  end

  local on_cancel = M.on_cancel
  local win = M.win
  local buf = M.buf

  M.closing = true
  M.suppress_win_closed = true
  pcall(vim.api.nvim_clear_autocmds, { group = AUGROUP })

  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  reset_state()

  if opts.notify_cancel ~= false and on_cancel then
    on_cancel()
  end

  return true
end

return M
