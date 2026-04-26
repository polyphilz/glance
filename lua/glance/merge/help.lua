local actions = require('glance.merge.actions')
local config = require('glance.config')

local M = {}
local AUGROUP = vim.api.nvim_create_augroup('GlanceMergeHelp', { clear = true })

local state = {
  buf = nil,
  win = nil,
  return_win = nil,
}

local ACTION_LABELS = {
  accept_ours = 'accept ours',
  accept_theirs = 'accept theirs',
  accept_both_ours_then_theirs = 'accept both (ours -> theirs)',
  accept_both_theirs_then_ours = 'accept both (theirs -> ours)',
  keep_base = 'keep base',
  reset_conflict = 'reset conflict',
  mark_resolved = 'mark resolved',
  accept_all_ours = 'accept all ours',
  accept_all_theirs = 'accept all theirs',
  reset_result = 'reset result',
  complete_merge = 'complete file',
  continue_operation = 'continue operation',
}

local function display_key(lhs)
  if type(lhs) ~= 'string' then
    return ''
  end
  return lhs:gsub('<Leader>', '\\'):gsub('<leader>', '\\')
end

local function help_key()
  return display_key(config.options.merge.keymaps.show_help)
end

local function buffer_valid()
  return state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

local function window_valid()
  return state.win and vim.api.nvim_win_is_valid(state.win)
end

local function close_window()
  local return_win = state.return_win
  local win = state.win
  local buf = state.buf

  pcall(vim.api.nvim_clear_autocmds, { group = AUGROUP })
  state.buf = nil
  state.win = nil
  state.return_win = nil

  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if return_win and vim.api.nvim_win_is_valid(return_win) then
    pcall(vim.api.nvim_set_current_win, return_win)
  end
end

local function float_config(line_count)
  local width = math.min(78, math.max(vim.o.columns - 8, 38))
  local editor_height = math.max(vim.o.lines - vim.o.cmdheight, 8)
  local height = math.min(math.max(line_count, 8), math.max(editor_height - 6, 6))

  return {
    relative = 'editor',
    row = math.max(0, math.floor((editor_height - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' Merge Actions ',
    title_pos = 'center',
    zindex = math.max((config.options.minimap.zindex or 50) + 10, 60),
  }
end

local function apply_window_options(win)
  vim.api.nvim_win_set_option(win, 'wrap', false)
  vim.api.nvim_win_set_option(win, 'cursorline', false)
  vim.api.nvim_win_set_option(win, 'number', false)
  vim.api.nvim_win_set_option(win, 'relativenumber', false)
  vim.api.nvim_win_set_option(win, 'signcolumn', 'no')
  vim.api.nvim_win_set_option(win, 'winhighlight', 'FloatTitle:GlanceLegendKey')
end

local function setup_buffer(lines)
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.buf, 'glance://merge/actions')
  vim.api.nvim_buf_set_option(state.buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(state.buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(state.buf, 'swapfile', false)
  vim.api.nvim_buf_set_option(state.buf, 'filetype', 'glance')
  vim.api.nvim_buf_set_option(state.buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(state.buf, 'readonly', true)
end

local function bind_close_keys()
  local opts = { noremap = true, silent = true, buffer = state.buf }
  vim.keymap.set('n', 'q', close_window, opts)
  vim.keymap.set('n', '<Esc>', close_window, opts)

  local lhs = config.options.merge.keymaps.show_help
  if type(lhs) == 'string' and lhs ~= '' then
    vim.keymap.set('n', lhs, close_window, opts)
  end
end

local function setup_autocmds()
  vim.api.nvim_create_autocmd('WinClosed', {
    group = AUGROUP,
    pattern = tostring(state.win),
    once = true,
    callback = function()
      vim.schedule(function()
        if window_valid() then
          return
        end
        if buffer_valid() then
          pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
        end
        state.buf = nil
        state.win = nil
        state.return_win = nil
      end)
    end,
  })

  vim.api.nvim_create_autocmd('VimResized', {
    group = AUGROUP,
    callback = function()
      if window_valid() and buffer_valid() then
        local line_count = vim.api.nvim_buf_line_count(state.buf)
        pcall(vim.api.nvim_win_set_config, state.win, float_config(line_count))
      end
    end,
  })
end

local function key_line(action, detail)
  local key = display_key(config.options.merge.keymaps[action])
  local label = ACTION_LABELS[action] or action:gsub('_', ' ')
  if key ~= '' then
    label = '[' .. key .. '] ' .. label
  else
    label = '[-] ' .. label
  end
  if detail and detail ~= '' then
    label = label .. ' - ' .. detail
  end
  return '  ' .. label
end

local function custom_key_line(action, label, detail)
  local key = display_key(config.options.merge.keymaps[action])
  if key ~= '' then
    label = '[' .. key .. '] ' .. label
  else
    label = '[-] ' .. label
  end
  if detail and detail ~= '' then
    label = label .. ' - ' .. detail
  end
  return '  ' .. label
end

local function section(lines, title)
  if #lines > 0 then
    lines[#lines + 1] = ''
  end
  lines[#lines + 1] = title
end

local function operation_label(context)
  local labels = {
    merge = 'merge',
    rebase = 'rebase',
    cherry_pick = 'cherry-pick',
    revert = 'revert',
  }
  return labels[context and context.kind] or 'operation'
end

local function add_text_conflict_actions(lines, conflict)
  section(lines, 'Current conflict')
  if not conflict then
    lines[#lines + 1] = '  No active conflict. Use ]x and [x to move between conflicts.'
    return
  end

  for _, definition in ipairs(actions.available(conflict)) do
    lines[#lines + 1] = key_line(definition.id)
  end
end

local function add_text_file_actions(lines, model)
  section(lines, 'File')
  lines[#lines + 1] = key_line('accept_all_ours', 'apply to default unresolved conflicts')
  lines[#lines + 1] = key_line('accept_all_theirs', 'apply to default unresolved conflicts')
  lines[#lines + 1] = key_line('reset_result', 'rebuild from Git stages')

  local unresolved = model and model.unresolved_count or 0
  if unresolved > 0 then
    lines[#lines + 1] = key_line('complete_merge', string.format('blocked: %d unresolved', unresolved))
  else
    lines[#lines + 1] = key_line('complete_merge', 'stage this resolved file')
  end
end

local function side_entry(info, side)
  local stage = side == 'ours' and 2 or 3
  return info and info.stage_entries and info.stage_entries[stage] or nil
end

local function special_side_label(info, side)
  local label = side == 'ours' and 'Ours' or 'Theirs'
  local entry = side_entry(info, side)
  if not entry then
    return 'accept ' .. label .. ' deletion'
  end
  if info.class == 'modify_delete' then
    return 'keep ' .. label .. ' modified version'
  end
  if info.class == 'rename_delete' then
    return 'keep ' .. label .. ' renamed path'
  end
  if info.class == 'rename_rename' then
    return 'keep ' .. label .. ' path'
  end
  return 'take ' .. label
end

local function add_special_conflict_actions(lines, info)
  section(lines, 'Current conflict')
  lines[#lines + 1] = custom_key_line('accept_ours', special_side_label(info, 'ours'))
  lines[#lines + 1] = custom_key_line('accept_theirs', special_side_label(info, 'theirs'))

  if info and (info.class == 'rename_rename' or info.class == 'non_text_add_add') then
    lines[#lines + 1] = '  Keep both requires choosing another output path manually.'
  end
end

local function add_special_file_actions(lines, selection)
  section(lines, 'File')
  if selection then
    lines[#lines + 1] = key_line('complete_merge', 'stage the selected resolution')
  else
    lines[#lines + 1] = key_line('complete_merge', 'blocked: choose ours or theirs first')
  end
end

local function add_operation_actions(lines, context)
  section(lines, 'Operation')
  if not context or not context.kind then
    lines[#lines + 1] = '  No active Git operation was detected.'
    return
  end

  if context.kind == 'merge' then
    lines[#lines + 1] = '  After all conflicted files are complete, press [c] in the filetree to commit the merge.'
    return
  end

  lines[#lines + 1] = key_line(
    'continue_operation',
    'available after all conflicted files are complete'
  ):gsub('continue operation', 'continue ' .. operation_label(context), 1)
end

local function text_lines(opts)
  local model = opts.model or {}
  local conflict = opts.active_conflict_index and model.conflicts and model.conflicts[opts.active_conflict_index] or nil
  local lines = {
    'Merge actions for the current conflict file.',
  }

  add_text_conflict_actions(lines, conflict)
  add_text_file_actions(lines, model)
  add_operation_actions(lines, opts.context or model.operation)
  return lines
end

local function special_lines(opts)
  local lines = {
    'Merge actions for this special conflict.',
  }

  add_special_conflict_actions(lines, opts.info)
  add_special_file_actions(lines, opts.selection)
  add_operation_actions(lines, opts.context)
  return lines
end

function M.winbar_hint()
  local key = help_key()
  if key == '' then
    return ''
  end
  return '%#GlanceAccentText#' .. key .. ' actions%*'
end

function M.complete_hint()
  local key = display_key(config.options.merge.keymaps.complete_merge)
  if key == '' then
    return ''
  end
  return key .. ' complete'
end

function M.open(opts)
  opts = opts or {}
  if window_valid() then
    vim.api.nvim_set_current_win(state.win)
    return true
  end

  close_window()
  state.return_win = vim.api.nvim_get_current_win()

  local lines
  if opts.kind == 'special' then
    lines = special_lines(opts)
  else
    lines = text_lines(opts)
  end

  setup_buffer(lines)
  state.win = vim.api.nvim_open_win(state.buf, true, float_config(#lines))
  apply_window_options(state.win)
  bind_close_keys()
  setup_autocmds()
  return true
end

function M.toggle(opts)
  if window_valid() then
    close_window()
    return false
  end
  M.open(opts)
  return true
end

function M.close()
  close_window()
end

function M.is_open()
  return window_valid()
end

return M
