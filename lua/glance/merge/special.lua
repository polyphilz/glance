local config = require('glance.config')
local filetree = require('glance.filetree')
local git = require('glance.git')
local help = require('glance.merge.help')
local layout = require('glance.merge.layout')
local workspace = require('glance.workspace')

local M = {}

local NS = vim.api.nvim_create_namespace('glance_merge_special')

local state = {
  active = false,
  file = nil,
  info = nil,
  selection = nil,
}

local function panel_buf(diffview)
  return workspace.get_buf(diffview.workspace, layout.SPECIAL_ROLE)
end

local function panel_win(diffview)
  return workspace.get_win(diffview.workspace, layout.SPECIAL_ROLE)
end

local function set_lines(buf, lines)
  vim.api.nvim_buf_set_option(buf, 'readonly', false)
  vim.api.nvim_buf_set_option(buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(buf, 'readonly', true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'swapfile', false)
  vim.api.nvim_set_option_value('modified', false, { buf = buf })
end

local function add_highlight(buf, line, group)
  if line >= 0 and line < vim.api.nvim_buf_line_count(buf) then
    vim.api.nvim_buf_add_highlight(buf, NS, group, line, 0, -1)
  end
end

local function display_key(lhs)
  if type(lhs) ~= 'string' then
    return ''
  end
  return lhs:gsub('<Leader>', '\\'):gsub('<leader>', '\\')
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

local function notify_post_complete(context, files)
  files = files or {}
  local conflicts = files.conflicts or {}
  if #conflicts > 0 then
    local noun = #conflicts == 1 and 'file' or 'files'
    local verb = #conflicts == 1 and 'remains' or 'remain'
    vim.notify(
      string.format('glance: merge result staged; %d conflicted %s %s', #conflicts, noun, verb),
      vim.log.levels.INFO
    )
    return
  end

  if context and context.kind == 'merge' then
    vim.notify('glance: all merge conflicts are resolved; press c to commit the merge', vim.log.levels.INFO)
    return
  end

  if context and context.kind then
    local key = display_key(config.options.merge.keymaps.continue_operation)
    if key ~= '' then
      vim.notify(
        string.format('glance: all %s conflicts are resolved; press %s to continue', operation_label(context), key),
        vim.log.levels.INFO
      )
    else
      vim.notify(
        string.format('glance: all %s conflicts are resolved; continue the Git operation from the filetree', operation_label(context)),
        vim.log.levels.INFO
      )
    end
    return
  end

  vim.notify('glance: merge result staged', vim.log.levels.INFO)
end

local function class_title(class)
  local titles = {
    modify_delete = 'Modify/Delete Conflict',
    rename_delete = 'Rename/Delete Conflict',
    rename_rename = 'Rename/Rename Conflict',
    non_text_add_add = 'Non-Text Add/Add Conflict',
    binary = 'Binary Conflict',
  }
  return titles[class] or 'Special Conflict'
end

local function side_entry(info, side)
  local stage = side == 'ours' and 2 or 3
  return info.stage_entries and info.stage_entries[stage] or nil
end

local function side_status(info, side)
  local entry = side_entry(info, side)
  if not entry then
    return 'deleted'
  end
  if info.class == 'rename_delete' or info.class == 'rename_rename' then
    return 'renamed path'
  end
  if info.class == 'modify_delete' then
    return 'modified'
  end
  if info.class == 'non_text_add_add' then
    return 'added non-text'
  end
  return 'binary'
end

local function side_detail(info, side)
  local label = side == 'ours' and 'Ours' or 'Theirs'
  local entry = side_entry(info, side)
  local parts = { label }
  if entry then
    parts[#parts + 1] = 'stage ' .. tostring(entry.stage)
    parts[#parts + 1] = side_status(info, side)
    parts[#parts + 1] = entry.path
  else
    parts[#parts + 1] = 'deleted'
  end
  return '  ' .. table.concat(parts, ' | ')
end

local function side_action_label(info, side)
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

local function selection_label(info, side)
  if not side then
    return 'no choice selected'
  end
  return 'selected: ' .. side_action_label(info, side)
end

local function destructive_choice(info, side)
  if not side_entry(info, side) then
    return true
  end
  return info.class == 'rename_rename'
end

local function confirm_choice(info, side)
  if not destructive_choice(info, side) then
    return true
  end

  local message = side_action_label(info, side) .. '?'
  return vim.fn.confirm(message, '&Apply\n&Cancel', 2) == 1
end

local function render_lines(info)
  local km = config.options.merge.keymaps or {}
  local ours_key = display_key(km.accept_ours)
  local theirs_key = display_key(km.accept_theirs)
  local complete_key = display_key(km.complete_merge)
  local continue_key = display_key(km.continue_operation)
  local lines = {
    '  ' .. class_title(info.class),
    '',
  }

  if info.base_path then
    lines[#lines + 1] = '  Base | stage 1 | ' .. info.base_path
  end
  lines[#lines + 1] = side_detail(info, 'ours')
  lines[#lines + 1] = side_detail(info, 'theirs')
  lines[#lines + 1] = ''
  lines[#lines + 1] = '  ' .. selection_label(info, state.selection)
  lines[#lines + 1] = ''

  if ours_key ~= '' then
    lines[#lines + 1] = '  [' .. ours_key .. '] ' .. side_action_label(info, 'ours')
  end
  if theirs_key ~= '' then
    lines[#lines + 1] = '  [' .. theirs_key .. '] ' .. side_action_label(info, 'theirs')
  end
  if complete_key ~= '' then
    lines[#lines + 1] = '  [' .. complete_key .. '] complete merge'
  end
  if continue_key ~= '' then
    lines[#lines + 1] = '  [' .. continue_key .. '] continue operation'
  end

  if info.class == 'rename_rename' or info.class == 'non_text_add_add' then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '  Keep both needs another output path. Resolve that manually, then refresh Glance.'
  end

  return lines
end

local function render(diffview)
  local buf = panel_buf(diffview)
  local win = panel_win(diffview)
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not state.info then
    return
  end

  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  set_lines(buf, render_lines(state.info))
  add_highlight(buf, 0, 'GlanceAccentText')
  for line = 2, 4 do
    add_highlight(buf, line, 'Comment')
  end

  if win and vim.api.nvim_win_is_valid(win) then
    local context = git.get_operation_context()
    local parts = {}
    if context.prefix then
      parts[#parts + 1] = context.prefix
    end
    parts[#parts + 1] = class_title(state.info.class)
    parts[#parts + 1] = selection_label(state.info, state.selection)
    local label = table.concat(parts, ' | ')
    local hint = help.winbar_hint()
    if hint ~= '' then
      label = label .. '%=' .. hint
    end
    vim.api.nvim_set_option_value('winbar', label, { win = win })
  end
end

local function bind_keymaps(diffview)
  local buf = panel_buf(diffview)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local km = config.options.merge.keymaps or {}
  local opts = {
    buffer = buf,
    silent = true,
  }

  if km.accept_ours then
    vim.keymap.set('n', km.accept_ours, function()
      M.choose(diffview, 'ours')
    end, opts)
  end
  if km.accept_theirs then
    vim.keymap.set('n', km.accept_theirs, function()
      M.choose(diffview, 'theirs')
    end, opts)
  end
  if km.complete_merge then
    vim.keymap.set('n', km.complete_merge, function()
      M.complete(diffview)
    end, opts)
  end
  if km.show_help then
    vim.keymap.set('n', km.show_help, function()
      help.toggle({
        kind = 'special',
        info = state.info,
        selection = state.selection,
        context = git.get_operation_context(),
      })
    end, opts)
  end
  if km.continue_operation then
    vim.keymap.set('n', km.continue_operation, function()
      filetree.continue_operation()
    end, opts)
  end
end

function M.supports(info)
  if type(info) ~= 'table' then
    return false
  end
  return info.class == 'modify_delete'
    or info.class == 'rename_delete'
    or info.class == 'rename_rename'
    or info.class == 'non_text_add_add'
    or info.class == 'binary'
end

function M.is_active()
  return state.active == true
end

function M.open(diffview, file, info)
  info = info or git.get_conflict_info(file)
  if not M.supports(info) then
    return false
  end

  state.active = true
  state.file = file
  state.info = info
  state.selection = nil

  layout.open_special(diffview)
  local buf = panel_buf(diffview)
  if buf then
    pcall(vim.api.nvim_buf_set_name, buf, 'glance://merge/special/' .. (info.display_path or file.path))
  end
  render(diffview)
  layout.equalize_special(diffview)
  diffview.setup_autocmds(file)
  diffview.bind_buffer_keymaps()
  bind_keymaps(diffview)

  local win = panel_win(diffview)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end

  return true
end

function M.choose(diffview, side)
  if not state.active or not state.info then
    return false
  end
  if side ~= 'ours' and side ~= 'theirs' then
    return false
  end
  if not confirm_choice(state.info, side) then
    return false
  end

  local ok, err = git.apply_special_conflict_choice(state.info, side)
  if not ok then
    vim.notify('glance: failed to apply conflict choice: ' .. tostring(err), vim.log.levels.WARN)
    return false
  end

  state.selection = side
  render(diffview)
  filetree.note_repo_activity()
  vim.notify('glance: ' .. side_action_label(state.info, side), vim.log.levels.INFO)
  return true
end

function M.complete(diffview)
  if not state.active or not state.info then
    return false
  end
  if not state.selection then
    vim.notify('glance: choose a conflict resolution before completing this file', vim.log.levels.WARN)
    return false
  end

  local context = git.get_operation_context()
  local ok, err = git.complete_special_conflict_choice(state.info, state.selection)
  if not ok then
    vim.notify('glance: failed to stage merge result: ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  local snapshot = git.get_status_snapshot()
  filetree.note_repo_activity()
  diffview.close(false)
  notify_post_complete(context, snapshot.files)
  return true
end

function M.refresh(diffview, file)
  if not state.active then
    return false
  end

  file = file or state.file
  local info, err = git.get_conflict_info(file)
  if not info then
    vim.notify('glance: failed to refresh conflict panel: ' .. tostring(err), vim.log.levels.WARN)
    return false
  end

  state.file = file
  state.info = info
  render(diffview)
  return true
end

function M.equalize_panes(diffview)
  if not state.active then
    return false
  end
  layout.equalize_special(diffview)
  return true
end

function M.hoverable_separator_wins()
  if not state.active then
    return nil
  end
  return layout.special_hoverable_separator_wins()
end

function M.reset()
  state.active = false
  state.file = nil
  state.info = nil
  state.selection = nil
end

return M
