local actions = require('glance.merge.actions')
local config = require('glance.config')
local filetree = require('glance.filetree')
local git = require('glance.git')
local layout = require('glance.merge.layout')
local model = require('glance.merge.model')
local render = require('glance.merge.render')
local workspace = require('glance.workspace')

local M = {}

local state = {
  active = false,
  file = nil,
  model = nil,
  active_conflict_index = nil,
  write_in_progress = false,
  sync_in_progress = false,
}

local function panes(diffview)
  return {
    theirs = {
      win = workspace.get_win(diffview.workspace, layout.THEIRS_ROLE),
      buf = workspace.get_buf(diffview.workspace, layout.THEIRS_ROLE),
    },
    ours = {
      win = workspace.get_win(diffview.workspace, layout.OURS_ROLE),
      buf = workspace.get_buf(diffview.workspace, layout.OURS_ROLE),
    },
    result = {
      win = workspace.get_win(diffview.workspace, layout.RESULT_ROLE),
      buf = workspace.get_buf(diffview.workspace, layout.RESULT_ROLE),
    },
  }
end

local function refresh_decorations(diffview)
  if not state.model then
    return
  end

  render.decorate(panes(diffview), state.model, state.active_conflict_index)
  require('glance.minimap').update_merge(state.model, state.active_conflict_index)
end

local function result_win(diffview)
  local win = workspace.get_win(diffview.workspace, layout.RESULT_ROLE)
  if win and vim.api.nvim_win_is_valid(win) then
    return win
  end
  return nil
end

local function result_buf(diffview)
  local buf = workspace.get_buf(diffview.workspace, layout.RESULT_ROLE)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  return nil
end

local function result_modified(diffview)
  local buf = result_buf(diffview)
  if not buf then
    return false
  end

  if vim.api.nvim_get_option_value('buftype', { buf = buf }) ~= '' then
    return false
  end

  return vim.api.nvim_get_option_value('modified', { buf = buf })
end

local function unresolved_indices()
  local indices = {}
  if not state.model then
    return indices
  end

  for index, conflict in ipairs(state.model.conflicts) do
    if not conflict.handled then
      indices[#indices + 1] = index
    end
  end

  return indices
end

local function first_unresolved_index()
  local unresolved = unresolved_indices()
  return unresolved[1]
end

local function conflict_index_for_result_line(line)
  if not state.model then
    return nil
  end

  for index, conflict in ipairs(state.model.conflicts) do
    local start = conflict.result_range.start
    local count = conflict.result_range.count
    if count == 0 then
      if line == start then
        return index
      end
    elseif line >= start and line < (start + count) then
      return index
    end
  end

  return nil
end

local function update_active_conflict_from_cursor(diffview)
  local win = result_win(diffview)
  if not win or vim.api.nvim_get_current_win() ~= win then
    return state.active_conflict_index
  end

  local index = conflict_index_for_result_line(vim.api.nvim_win_get_cursor(win)[1])
  if index then
    state.active_conflict_index = index
  end

  return state.active_conflict_index
end

local function current_conflict_index(diffview)
  local index = update_active_conflict_from_cursor(diffview)
  if index and state.model and state.model.conflicts[index] then
    return index
  end

  return state.active_conflict_index or first_unresolved_index() or 1
end

local function focus_result(diffview)
  local win = result_win(diffview)
  if not win then
    return false
  end

  vim.api.nvim_set_current_win(win)
  return true
end

local function write_text(path, text)
  local file = assert(io.open(path, 'w'))
  file:write(text or '')
  file:close()
end

local function edit_result_buffer(diffview, file)
  local root = git.repo_root()
  if not root then
    return nil
  end

  local current = panes(diffview).result
  if not current.win or not vim.api.nvim_win_is_valid(current.win) then
    return nil
  end

  local scratch = current.buf
  vim.api.nvim_set_current_win(current.win)
  vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. file.path))

  local buf = vim.api.nvim_get_current_buf()
  workspace.set_pane(diffview.workspace, layout.RESULT_ROLE, {
    win = current.win,
    buf = buf,
  })

  if scratch and vim.api.nvim_buf_is_valid(scratch) and scratch ~= buf then
    vim.api.nvim_buf_delete(scratch, { force = true })
  end

  return buf
end

local function bind_write_command(diffview, file)
  local buf = result_buf(diffview)
  if not buf then
    return
  end

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = diffview.autocmd_group,
    buffer = buf,
    callback = function()
      if state.write_in_progress then
        return
      end

      local root = git.repo_root()
      if not root then
        vim.notify('glance: not inside a git repository', vim.log.levels.WARN)
        return
      end

      local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local prepared, err = model.prepare_write(file, current_lines, {
        current_ends_with_newline = vim.api.nvim_get_option_value('endofline', { buf = buf }),
        previous_model = state.model,
      })
      if not prepared then
        vim.notify('glance: failed to save merge result: ' .. err, vim.log.levels.WARN)
        return
      end

      state.write_in_progress = true
      local ok, write_err = xpcall(function()
        write_text(root .. '/' .. file.path, prepared.persisted_text)
        vim.api.nvim_set_option_value('modified', false, { buf = buf })
        filetree.note_repo_activity()
        M.refresh(diffview, file)
      end, debug.traceback)
      state.write_in_progress = false

      if not ok then
        vim.notify('glance: failed to save merge result: ' .. tostring(write_err), vim.log.levels.WARN)
        vim.api.nvim_set_option_value('modified', true, { buf = buf })
        return
      end
    end,
  })
end

local function sync_from_result_buffer(diffview, file, previous_model)
  local buf = result_buf(diffview)
  if not buf then
    return nil, 'merge result buffer is not available'
  end

  local merge_model, err = model.build(file, {
    current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    current_ends_with_newline = vim.api.nvim_get_option_value('endofline', { buf = buf }),
    previous_model = previous_model or state.model,
    manual_clean_state = 'manual_unresolved',
  })
  if not merge_model then
    return nil, err
  end

  state.file = file
  state.model = merge_model
  render.apply(diffview, panes(diffview), merge_model, file, {
    refresh_sources = false,
    refresh_result = false,
    active_conflict_index = state.active_conflict_index,
  })
  update_active_conflict_from_cursor(diffview)
  refresh_decorations(diffview)
  return merge_model
end

local function apply_action(diffview, action)
  local buf = result_buf(diffview)
  if not buf then
    return false
  end

  local index = current_conflict_index(diffview)
  local conflict = state.model and state.model.conflicts[index] or nil
  if not conflict then
    return false
  end

  local start_line = conflict.result_range.start - 1
  local stop_line = conflict.result_range.start + conflict.result_range.count - 1
  local previous_model = state.model
  local updated, err = actions.apply(previous_model, index, action)
  if not updated then
    vim.notify('glance: failed to apply merge action: ' .. err, vim.log.levels.WARN)
    return false
  end

  state.sync_in_progress = true
  vim.api.nvim_buf_set_lines(buf, start_line, stop_line, false, updated.current_result_lines or updated.current_lines or {})
  state.sync_in_progress = false

  local merge_model, sync_err = sync_from_result_buffer(diffview, state.file, previous_model)
  if not merge_model then
    vim.notify('glance: failed to refresh merge state: ' .. sync_err, vim.log.levels.WARN)
    return false
  end

  M.jump_to_conflict(diffview, index)
  return true
end

local function bind_navigation_keymaps(diffview)
  for _, role in ipairs({ layout.THEIRS_ROLE, layout.OURS_ROLE, layout.RESULT_ROLE }) do
    local buf = workspace.get_buf(diffview.workspace, role)
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.keymap.set('n', ']x', function()
        M.jump_next(diffview)
      end, {
        buffer = buf,
        silent = true,
      })
      vim.keymap.set('n', '[x', function()
        M.jump_prev(diffview)
      end, {
        buffer = buf,
        silent = true,
      })
    end
  end
end

local function bind_action_keymaps(diffview)
  local keymaps = config.options.merge.keymaps or {}
  for _, role in ipairs({ layout.THEIRS_ROLE, layout.OURS_ROLE, layout.RESULT_ROLE }) do
    local buf = workspace.get_buf(diffview.workspace, role)
    if buf and vim.api.nvim_buf_is_valid(buf) then
      for action, lhs in pairs(keymaps) do
        vim.keymap.set('n', lhs, function()
          apply_action(diffview, action)
        end, {
          buffer = buf,
          silent = true,
        })
      end
    end
  end
end

local function bind_result_tracking(diffview, file)
  local buf = result_buf(diffview)
  if not buf then
    return
  end

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = diffview.autocmd_group,
    buffer = buf,
    callback = function()
      if state.write_in_progress or state.sync_in_progress then
        return
      end

      local previous_model = state.model
      local merge_model = sync_from_result_buffer(diffview, file, previous_model)
      if not merge_model then
        state.model = previous_model
      end
    end,
  })

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = diffview.autocmd_group,
    buffer = buf,
    callback = function()
      local previous = state.active_conflict_index
      local current = update_active_conflict_from_cursor(diffview)
      if current ~= previous then
        refresh_decorations(diffview)
      end
    end,
  })
end

function M.is_active()
  return state.active == true
end

function M.jump_to_conflict(diffview, index)
  if not state.model or not state.model.conflicts[index] then
    return false
  end

  local conflict = state.model.conflicts[index]
  local win = result_win(diffview)
  if not win then
    return false
  end

  local line = conflict.result_range.start
  if conflict.result_range.count == 0 then
    local buf = result_buf(diffview)
    local line_count = buf and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_line_count(buf) or 1
    line = math.min(math.max(line, 1), math.max(line_count, 1))
  end

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { math.max(line, 1), 0 })
  state.active_conflict_index = index
  refresh_decorations(diffview)
  return true
end

function M.jump_next(diffview)
  local unresolved = unresolved_indices()
  if #unresolved == 0 then
    return false
  end

  local target = unresolved[1]
  if state.active_conflict_index then
    for index, conflict_index in ipairs(unresolved) do
      if conflict_index > state.active_conflict_index then
        target = conflict_index
        break
      end
      if index == #unresolved then
        target = unresolved[1]
      end
    end
  end

  return M.jump_to_conflict(diffview, target)
end

function M.jump_prev(diffview)
  local unresolved = unresolved_indices()
  if #unresolved == 0 then
    return false
  end

  local target = unresolved[#unresolved]
  if state.active_conflict_index then
    for index = #unresolved, 1, -1 do
      if unresolved[index] < state.active_conflict_index then
        target = unresolved[index]
        break
      end
      if index == 1 then
        target = unresolved[#unresolved]
      end
    end
  end

  return M.jump_to_conflict(diffview, target)
end

function M.equalize_panes(diffview)
  if not state.active then
    return false
  end

  layout.equalize(diffview)
  return true
end

function M.hoverable_separator_wins(diffview)
  if not state.active then
    return nil
  end

  return layout.hoverable_separator_wins(diffview)
end

local function rebuild(diffview, file)
  local merge_model, err = model.build(file)
  if not merge_model then
    return nil, err
  end

  state.file = file
  state.model = merge_model
  render.apply(diffview, panes(diffview), merge_model, file, {
    active_conflict_index = state.active_conflict_index,
  })
  layout.equalize(diffview)
  require('glance.minimap').update_merge(state.model, state.active_conflict_index)
  return merge_model
end

function M.open(diffview, file)
  local merge_model, err = model.build(file)
  if not merge_model then
    state.active = false
    state.file = nil
    state.model = nil
    state.active_conflict_index = nil
    diffview.open_placeholder(file, err)
    return
  end

  state.active = true
  state.file = file
  state.model = merge_model
  state.active_conflict_index = nil

  layout.open(diffview)
  local buf = edit_result_buffer(diffview, file)
  if not buf then
    return
  end

  rebuild(diffview, file)

  local win = result_win(diffview)
  if win then
    require('glance.minimap').open_merge(win, state.model, state.active_conflict_index)
  end

  local root = git.repo_root()
  if root and config.options.watch.enabled then
    diffview.watch_file(root .. '/' .. file.path)
  end

  diffview.setup_autocmds(file)
  bind_write_command(diffview, file)
  diffview.bind_buffer_keymaps()
  bind_navigation_keymaps(diffview)
  bind_action_keymaps(diffview)
  bind_result_tracking(diffview, file)

  local first = first_unresolved_index() or 1
  if not M.jump_to_conflict(diffview, first) then
    focus_result(diffview)
  end
end

function M.refresh(diffview, file)
  if not state.active then
    return false
  end

  file = file or state.file
  if not file then
    return false
  end

  if result_modified(diffview) then
    return false
  end

  local previous_active = state.active_conflict_index
  local merge_model, err = rebuild(diffview, file)
  if not merge_model then
    vim.notify('glance: failed to refresh merge view: ' .. err, vim.log.levels.WARN)
    return false
  end

  if previous_active and merge_model.conflicts[previous_active] then
    if M.jump_to_conflict(diffview, previous_active) then
      return true
    end
  end

  local first = first_unresolved_index() or 1
  if not M.jump_to_conflict(diffview, first) then
    focus_result(diffview)
  end
  return true
end

function M.reset()
  state.active = false
  state.file = nil
  state.model = nil
  state.active_conflict_index = nil
  state.write_in_progress = false
  state.sync_in_progress = false
end

return M
