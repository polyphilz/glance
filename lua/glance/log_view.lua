local config = require('glance.config')

local M = {}
local AUGROUP = vim.api.nvim_create_augroup('GlanceLogView', { clear = true })
local NS = vim.api.nvim_create_namespace('glance_log_view')

M.buf = nil
M.win = nil
M.mode = 'list'
M.entries = {}
M.line_map = {}
M.entry_lines = {}
M.selected_index = 1
M.selected_hash = nil
M.preview_hash = nil
M.return_win = nil
M.closing = false

local function add_highlight(highlights, line, col_start, col_end, group)
  highlights[#highlights + 1] = { line, col_start, col_end, group }
end

local function add_legend_key_highlights(highlights, line, text)
  local cursor = 1
  while true do
    local bracket_start = text:find('%[', cursor)
    if not bracket_start then
      return
    end

    local bracket_end = text:find('%]', bracket_start + 1)
    if not bracket_end then
      return
    end

    add_highlight(highlights, line, bracket_start - 1, bracket_end, 'GlanceLegendKey')
    cursor = bracket_end + 1
  end
end

local function buffer_valid()
  return M.buf and vim.api.nvim_buf_is_valid(M.buf)
end

local function window_valid()
  return M.win and vim.api.nvim_win_is_valid(M.win)
end

local function current_title()
  if M.mode == 'preview' then
    return ' Commit Preview '
  end

  return ' Git Log '
end

local function modal_zindex()
  return math.max((config.options.minimap.zindex or 50) + 15, 70)
end

local function float_config()
  local width = math.min(math.max(vim.o.columns - 6, 32), math.max(math.floor(vim.o.columns * 0.86), 72))
  local editor_height = math.max(vim.o.lines - vim.o.cmdheight, 10)
  local height = math.min(math.max(editor_height - 4, 8), math.max(math.floor(editor_height * 0.78), 12))

  return {
    relative = 'editor',
    row = math.max(0, math.floor((editor_height - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = current_title(),
    title_pos = 'center',
    zindex = modal_zindex(),
  }
end

local function clear_state()
  pcall(vim.api.nvim_clear_autocmds, { group = AUGROUP })
  M.buf = nil
  M.win = nil
  M.mode = 'list'
  M.entries = {}
  M.line_map = {}
  M.entry_lines = {}
  M.selected_index = 1
  M.selected_hash = nil
  M.preview_hash = nil
  M.return_win = nil
  M.closing = false
end

local function apply_window_options(win)
  vim.api.nvim_win_set_option(win, 'wrap', false)
  vim.api.nvim_win_set_option(win, 'linebreak', false)
  vim.api.nvim_win_set_option(win, 'spell', false)
  vim.api.nvim_win_set_option(win, 'number', false)
  vim.api.nvim_win_set_option(win, 'relativenumber', false)
  vim.api.nvim_win_set_option(win, 'signcolumn', 'no')
  vim.api.nvim_win_set_option(win, 'foldenable', false)
  vim.api.nvim_win_set_option(win, 'cursorline', M.mode == 'list' and #M.entries > 0)
  vim.api.nvim_win_set_option(win, 'winhighlight', 'FloatTitle:GlanceLegendKey,CursorLine:GlanceActiveFile')
end

local function update_window_layout()
  if not window_valid() then
    return
  end

  pcall(vim.api.nvim_win_set_config, M.win, float_config())
  apply_window_options(M.win)
end

local function set_buffer_mode(filetype)
  if not buffer_valid() then
    return
  end

  vim.api.nvim_buf_set_option(M.buf, 'filetype', filetype)
  vim.api.nvim_buf_set_option(M.buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(M.buf, 'readonly', true)
end

local function render_buffer(lines, highlights, filetype)
  if not buffer_valid() then
    return
  end

  vim.api.nvim_buf_set_option(M.buf, 'modifiable', true)
  vim.api.nvim_buf_set_option(M.buf, 'readonly', false)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(M.buf, 'readonly', true)
  vim.api.nvim_buf_set_option(M.buf, 'filetype', filetype)

  vim.api.nvim_buf_clear_namespace(M.buf, NS, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(M.buf, NS, hl[4], hl[1] - 1, hl[2], hl[3])
  end

  update_window_layout()
end

local function selected_entry()
  return M.entries[M.selected_index]
end

local function current_hash()
  if M.mode == 'preview' then
    return M.preview_hash or M.selected_hash
  end

  local entry = selected_entry()
  return entry and entry.hash or nil
end

local function find_index_by_hash(hash)
  if not hash or hash == '' then
    return nil
  end

  for index, entry in ipairs(M.entries) do
    if entry.hash == hash then
      return index
    end
  end
end

local function move_cursor_to_index(index)
  if not window_valid() then
    return
  end

  local line = M.entry_lines[index]
  if not line then
    return
  end

  pcall(vim.api.nvim_win_set_cursor, M.win, { line, 0 })
end

local function set_selected_index(index)
  if #M.entries == 0 then
    M.selected_index = 1
    M.selected_hash = nil
    return
  end

  M.selected_index = math.max(1, math.min(index, #M.entries))
  M.selected_hash = M.entries[M.selected_index].hash
end

local function find_nearest_entry_line(line, prefer_upward)
  local total = vim.api.nvim_buf_line_count(M.buf)

  local function scan(start_line, finish_line, step)
    for row = start_line, finish_line, step do
      local index = M.line_map[row]
      if index then
        return M.entry_lines[index]
      end
    end
  end

  if prefer_upward then
    return scan(line - 1, 1, -1) or scan(line + 1, total, 1)
  end

  return scan(line + 1, total, 1) or scan(line - 1, 1, -1)
end

local function render_list_message(message)
  local legend = '  [Enter] preview  [y] copy hash  [r] refresh  [q] close'
  local lines = {
    legend,
    '',
    '  ' .. message,
  }
  local highlights = {}

  add_highlight(highlights, 1, 0, #legend, 'GlanceLegendText')
  add_legend_key_highlights(highlights, 1, legend)
  add_highlight(highlights, 3, 0, #lines[3], 'Comment')

  M.line_map = {}
  M.entry_lines = {}
  render_buffer(lines, highlights, 'glancelog')

  if window_valid() then
    pcall(vim.api.nvim_win_set_cursor, M.win, { 3, 2 })
  end
end

local function render_list()
  local legend = '  [Enter] preview  [y] copy hash  [r] refresh  [q] close'
  local lines = {
    legend,
    '',
  }
  local highlights = {}

  M.mode = 'list'
  M.preview_hash = nil
  add_highlight(highlights, 1, 0, #legend, 'GlanceLegendText')
  add_legend_key_highlights(highlights, 1, legend)

  if #M.entries == 0 then
    lines[#lines + 1] = '  No commits found'
    add_highlight(highlights, #lines, 0, #lines[#lines], 'Comment')
    M.line_map = {}
    M.entry_lines = {}
    render_buffer(lines, highlights, 'glancelog')
    if window_valid() then
      pcall(vim.api.nvim_win_set_cursor, M.win, { 3, 2 })
    end
    return
  end

  M.line_map = {}
  M.entry_lines = {}
  set_selected_index(M.selected_index)

  for index, entry in ipairs(M.entries) do
    local primary = '  ' .. entry.short_hash .. '  ' .. entry.subject
    local secondary_parts = {}

    if entry.decorations ~= '' then
      secondary_parts[#secondary_parts + 1] = entry.decorations
    end
    if entry.author_name ~= '' then
      secondary_parts[#secondary_parts + 1] = entry.author_name
    end
    if entry.relative_date ~= '' then
      secondary_parts[#secondary_parts + 1] = entry.relative_date
    end

    local secondary = '    ' .. table.concat(secondary_parts, '  |  ')

    lines[#lines + 1] = primary
    M.entry_lines[index] = #lines
    M.line_map[#lines] = index
    add_highlight(highlights, #lines, 2, 2 + #entry.short_hash, 'GlanceAccentText')

    lines[#lines + 1] = secondary
    M.line_map[#lines] = index
    add_highlight(highlights, #lines, 0, #secondary, 'GlanceLegendText')

    if index < #M.entries then
      lines[#lines + 1] = ''
    end
  end

  render_buffer(lines, highlights, 'glancelog')
  move_cursor_to_index(M.selected_index)
end

local function render_preview_lines(preview_lines)
  local legend = '  [q] back  [y] copy hash  [r] reload'
  local lines = {
    legend,
    '',
  }
  local highlights = {}

  M.mode = 'preview'
  add_highlight(highlights, 1, 0, #legend, 'GlanceLegendText')
  add_legend_key_highlights(highlights, 1, legend)

  for _, line in ipairs(preview_lines) do
    lines[#lines + 1] = line
    if line:match('^commit%s+') then
      add_highlight(highlights, #lines, 0, 6, 'GlanceAccentText')
    else
      local label = line:match('^(Author:)' )
        or line:match('^(AuthorDate:)')
        or line:match('^(Commit:)')
        or line:match('^(CommitDate:)')
      if label then
        add_highlight(highlights, #lines, 0, #label, 'GlanceAccentText')
      end
    end
  end

  render_buffer(lines, highlights, 'git')
  if window_valid() then
    pcall(vim.api.nvim_win_set_cursor, M.win, { math.min(3, #lines), 0 })
  end
end

local function restore_focus()
  if M.return_win and vim.api.nvim_win_is_valid(M.return_win) then
    vim.api.nvim_set_current_win(M.return_win)
    return
  end

  local filetree = package.loaded['glance.filetree']
  if filetree and filetree.win and vim.api.nvim_win_is_valid(filetree.win) then
    vim.api.nvim_set_current_win(filetree.win)
  end
end

local function open_window()
  if not buffer_valid() then
    return nil
  end

  M.win = vim.api.nvim_open_win(M.buf, true, float_config())
  apply_window_options(M.win)
  return M.win
end

local function setup_buffer()
  vim.api.nvim_buf_set_name(M.buf, 'glance://log')
  vim.api.nvim_buf_set_option(M.buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(M.buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(M.buf, 'swapfile', false)
  set_buffer_mode('glancelog')
end

local function move_selection(delta)
  if M.mode ~= 'list' or #M.entries == 0 then
    return
  end

  set_selected_index(M.selected_index + delta)
  move_cursor_to_index(M.selected_index)
end

local function move_to_first()
  if M.mode ~= 'list' or #M.entries == 0 then
    return
  end

  set_selected_index(1)
  move_cursor_to_index(M.selected_index)
end

local function move_to_last()
  if M.mode ~= 'list' or #M.entries == 0 then
    return
  end

  if vim.v.count > 0 then
    set_selected_index(vim.v.count)
  else
    set_selected_index(#M.entries)
  end
  move_cursor_to_index(M.selected_index)
end

local function notify_error(context, err)
  vim.notify('glance: failed to load ' .. context .. ': ' .. tostring(err), vim.log.levels.ERROR)
end

local function try_set_register(register, value)
  return pcall(vim.fn.setreg, register, value)
end

local function try_set_clipboard_register(register, value)
  local command = 'silent! call setreg(' .. vim.fn.string(register) .. ', ' .. vim.fn.string(value) .. ')'
  return pcall(vim.cmd, command)
end

local function preview_from_hash(hash)
  if not hash or hash == '' then
    return false
  end

  local preview_lines, err = require('glance.git').get_commit_preview(hash)
  if not preview_lines then
    notify_error('commit preview', err)
    return false
  end

  M.preview_hash = hash
  render_preview_lines(preview_lines)
  return true
end

local function setup_keymaps()
  local opts = { noremap = true, silent = true, buffer = M.buf }

  vim.keymap.set('n', 'j', function()
    if M.mode == 'list' then
      move_selection(vim.v.count1)
      return
    end
    vim.cmd('normal! ' .. vim.v.count1 .. 'j')
  end, opts)

  vim.keymap.set('n', 'k', function()
    if M.mode == 'list' then
      move_selection(-vim.v.count1)
      return
    end
    vim.cmd('normal! ' .. vim.v.count1 .. 'k')
  end, opts)

  vim.keymap.set('n', '<Down>', function()
    if M.mode == 'list' then
      move_selection(vim.v.count1)
      return
    end
    vim.cmd('normal! ' .. vim.v.count1 .. 'j')
  end, opts)

  vim.keymap.set('n', '<Up>', function()
    if M.mode == 'list' then
      move_selection(-vim.v.count1)
      return
    end
    vim.cmd('normal! ' .. vim.v.count1 .. 'k')
  end, opts)

  vim.keymap.set('n', 'gg', function()
    if M.mode == 'list' then
      move_to_first()
      return
    end
    vim.cmd('normal! gg')
  end, opts)

  vim.keymap.set('n', 'G', function()
    if M.mode == 'list' then
      move_to_last()
      return
    end
    if vim.v.count > 0 then
      vim.cmd('normal! ' .. vim.v.count .. 'G')
      return
    end
    vim.cmd('normal! G')
  end, opts)

  vim.keymap.set('n', '<CR>', function()
    if M.mode == 'list' then
      M.open_preview()
    end
  end, opts)

  vim.keymap.set('n', 'q', function()
    if M.mode == 'preview' then
      render_list()
      return
    end
    M.close()
  end, opts)

  vim.keymap.set('n', 'y', function()
    M.copy_selected_hash()
  end, opts)

  vim.keymap.set('n', 'r', function()
    M.refresh()
  end, opts)
end

local function setup_autocmds()
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = AUGROUP,
    buffer = M.buf,
    callback = function()
      clear_state()
    end,
  })

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = AUGROUP,
    buffer = M.buf,
    callback = function()
      if M.mode ~= 'list' or not window_valid() or #M.entries == 0 then
        return
      end

      local line = vim.api.nvim_win_get_cursor(M.win)[1]
      local index = M.line_map[line]
      if index then
        M.selected_index = index
        M.selected_hash = M.entries[index].hash
        return
      end

      local nearest = find_nearest_entry_line(line, false)
      if nearest then
        pcall(vim.api.nvim_win_set_cursor, M.win, { nearest, 0 })
      end
    end,
  })

  vim.api.nvim_create_autocmd('VimResized', {
    group = AUGROUP,
    callback = function()
      update_window_layout()
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
  update_window_layout()
  return true
end

function M.open()
  if buffer_valid() then
    return M.focus()
  end

  clear_state()
  M.return_win = vim.api.nvim_get_current_win()
  M.buf = vim.api.nvim_create_buf(false, false)

  setup_buffer()
  open_window()
  setup_keymaps()
  setup_autocmds()

  if not M.refresh() and #M.entries == 0 then
    render_list_message('Unable to load commit history')
  end

  if window_valid() then
    vim.api.nvim_set_current_win(M.win)
  end

  return true
end

function M.close()
  if not buffer_valid() then
    clear_state()
    return true
  end

  local win = M.win
  local buf = M.buf

  M.closing = true
  pcall(vim.api.nvim_clear_autocmds, { group = AUGROUP })

  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  restore_focus()
  clear_state()
  return true
end

function M.refresh()
  if M.mode == 'preview' and M.preview_hash then
    return preview_from_hash(M.preview_hash)
  end

  local previous_hash = M.selected_hash
  local entries, err = require('glance.git').get_log_entries({
    max_commits = config.options.log.max_commits,
  })

  if not entries then
    notify_error('commit history', err)
    return false
  end

  M.entries = entries
  if #entries == 0 then
    M.selected_index = 1
    M.selected_hash = nil
  else
    set_selected_index(find_index_by_hash(previous_hash) or 1)
  end

  render_list()
  return true
end

function M.open_preview(entry)
  local hash = entry
  if type(entry) == 'table' then
    hash = entry.hash
  end

  if hash == nil then
    hash = current_hash()
  end

  local index = find_index_by_hash(hash)
  if index then
    set_selected_index(index)
  end

  return preview_from_hash(hash)
end

function M.copy_selected_hash()
  local hash = current_hash()
  if not hash then
    vim.notify('glance: no commit hash to copy', vim.log.levels.WARN)
    return false
  end

  if not try_set_register('"', hash) then
    vim.notify('glance: failed to copy commit hash', vim.log.levels.ERROR)
    return false
  end

  if vim.fn['provider#clipboard#Executable']() ~= '' then
    try_set_clipboard_register('+', hash)
    try_set_clipboard_register('*', hash)
  end
  vim.notify('glance: copied commit hash ' .. hash:sub(1, 7), vim.log.levels.INFO)
  return true
end

return M
