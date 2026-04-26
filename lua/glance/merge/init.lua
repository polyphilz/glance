local actions = require('glance.merge.actions')
local config = require('glance.config')
local filetree = require('glance.filetree')
local git = require('glance.git')
local help = require('glance.merge.help')
local layout = require('glance.merge.layout')
local model = require('glance.merge.model')
local render = require('glance.merge.render')
local special = require('glance.merge.special')
local workspace = require('glance.workspace')

local M = {}

local RESULT_SYNC_DEBOUNCE_MS = 120

local state = {
  active = false,
  file = nil,
  model = nil,
  active_conflict_index = nil,
  write_in_progress = false,
  sync_in_progress = false,
  result_sync_pending = false,
  result_sync_token = 0,
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

local function manual_unresolved_count()
  local count = 0
  if not state.model then
    return count
  end

  for _, conflict in ipairs(state.model.conflicts) do
    if conflict.state == 'manual_unresolved' then
      count = count + 1
    end
  end

  return count
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

local function confirm_action(message, accept_label)
  return vim.fn.confirm(message, '&' .. accept_label .. '\n&Cancel', 2) == 1
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

local function set_result_from_model(diffview, merge_model, opts)
  opts = opts or {}
  local buf = result_buf(diffview)
  if not buf then
    return false
  end

  state.sync_in_progress = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, merge_model.result_lines or {})
  vim.api.nvim_set_option_value('endofline', merge_model.result_ends_with_newline ~= false, { buf = buf })
  if opts.modified ~= nil then
    vim.api.nvim_set_option_value('modified', opts.modified, { buf = buf })
  end
  state.sync_in_progress = false

  state.model = merge_model
  render.apply(diffview, panes(diffview), merge_model, state.file, {
    refresh_sources = false,
    refresh_result = false,
    active_conflict_index = state.active_conflict_index,
  })
  refresh_decorations(diffview)
  return true
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

local function set_buffer_lines_for_write(buf, lines, ends_with_newline)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  vim.api.nvim_set_option_value('endofline', ends_with_newline ~= false, { buf = buf })
end

local function write_prepared_result(buf, prepared, visible_lines, visible_ends_with_newline)
  local persisted_ends_with_newline = prepared.model and prepared.model.current_ends_with_newline
  local previous_fixendofline = vim.api.nvim_get_option_value('fixendofline', { buf = buf })

  state.sync_in_progress = true
  local ok, err = xpcall(function()
    set_buffer_lines_for_write(buf, prepared.persisted_lines, persisted_ends_with_newline)
    if persisted_ends_with_newline == false then
      vim.api.nvim_set_option_value('fixendofline', false, { buf = buf })
    end

    vim.api.nvim_buf_call(buf, function()
      vim.cmd('silent noautocmd write')
    end)
  end, debug.traceback)

  local restore_ok, restore_err = pcall(function()
    vim.api.nvim_set_option_value('fixendofline', previous_fixendofline, { buf = buf })
    set_buffer_lines_for_write(buf, visible_lines, visible_ends_with_newline)
    vim.api.nvim_set_option_value('modified', not ok, { buf = buf })
  end)
  state.sync_in_progress = false

  if not ok then
    return false, err
  end
  if not restore_ok then
    return false, restore_err
  end
  return true
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

      if not git.repo_root() then
        vim.notify('glance: not inside a git repository', vim.log.levels.WARN)
        return
      end

      local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local current_ends_with_newline = vim.api.nvim_get_option_value('endofline', { buf = buf })
      local prepared, err = model.prepare_write(file, current_lines, {
        current_ends_with_newline = current_ends_with_newline,
        previous_model = state.model,
      })
      if not prepared then
        vim.notify('glance: failed to save merge result: ' .. err, vim.log.levels.WARN)
        return
      end

      state.write_in_progress = true
      local ok, write_err = xpcall(function()
        local wrote, write_result_err = write_prepared_result(buf, prepared, current_lines, current_ends_with_newline)
        if not wrote then
          error(write_result_err)
        end
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

local function cancel_result_sync()
  state.result_sync_token = state.result_sync_token + 1
  state.result_sync_pending = false
end

local function run_result_sync(diffview, file)
  if state.write_in_progress or state.sync_in_progress then
    return true
  end
  if not state.active or not file or not state.file or state.file.path ~= file.path then
    return true
  end

  local previous_model = state.model
  local merge_model, err = sync_from_result_buffer(diffview, file, previous_model)
  if not merge_model then
    state.model = previous_model
    return false, err
  end

  return true
end

local function schedule_result_sync(diffview, file)
  state.result_sync_token = state.result_sync_token + 1
  state.result_sync_pending = true
  local token = state.result_sync_token

  vim.defer_fn(function()
    if token ~= state.result_sync_token or not state.result_sync_pending then
      return
    end

    state.result_sync_pending = false
    run_result_sync(diffview, file)
  end, RESULT_SYNC_DEBOUNCE_MS)
end

local function flush_result_sync(diffview)
  if not state.result_sync_pending then
    return true
  end

  local file = state.file
  cancel_result_sync()
  return run_result_sync(diffview, file)
end

local function flush_result_sync_or_notify(diffview)
  local synced, sync_err = flush_result_sync(diffview)
  if not synced then
    vim.notify('glance: failed to refresh merge state: ' .. tostring(sync_err), vim.log.levels.WARN)
    return false
  end

  return true
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

local function apply_all(diffview, action)
  if not state.model then
    return false
  end

  local applied, err = actions.apply_all(state.model, action)
  if not applied then
    vim.notify('glance: failed to apply merge action: ' .. tostring(err), vim.log.levels.WARN)
    return false
  end

  if not set_result_from_model(diffview, applied.model, { modified = true }) then
    return false
  end

  vim.notify(
    string.format('glance: applied %d conflict%s, skipped %d', applied.applied, applied.applied == 1 and '' or 's', applied.skipped),
    vim.log.levels.INFO
  )

  local first = first_unresolved_index()
  if first then
    M.jump_to_conflict(diffview, first)
  else
    focus_result(diffview)
  end
  return true
end

local function reset_result(diffview)
  if not state.file then
    return false
  end

  if not confirm_action('Reset merge result for ' .. state.file.path .. '?', 'Reset') then
    return false
  end

  local reset_model, err = model.reset_result(state.file)
  if not reset_model then
    vim.notify('glance: failed to reset merge result: ' .. tostring(err), vim.log.levels.WARN)
    return false
  end

  state.active_conflict_index = nil
  if not set_result_from_model(diffview, reset_model, { modified = true }) then
    return false
  end

  local first = first_unresolved_index() or 1
  if not M.jump_to_conflict(diffview, first) then
    focus_result(diffview)
  end
  return true
end

local function write_result_if_modified(diffview)
  local buf = result_buf(diffview)
  if not buf then
    return false, 'merge result buffer is not available'
  end

  if not result_modified(diffview) then
    return true
  end

  local ok, err = xpcall(function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('write')
    end)
  end, debug.traceback)
  if not ok then
    return false, tostring(err)
  end

  if vim.api.nvim_get_option_value('modified', { buf = buf }) then
    return false, 'merge result still has unsaved changes'
  end

  return true
end

local function handle_action_keymap(diffview, action)
  if not flush_result_sync_or_notify(diffview) then
    return
  end

  if action == 'show_help' then
    help.toggle({
      kind = 'text',
      model = state.model,
      active_conflict_index = state.active_conflict_index,
      context = state.model and state.model.operation or git.get_operation_context(),
    })
    return
  end
  if action == 'accept_all_ours' then
    apply_all(diffview, 'accept_ours')
    return
  end
  if action == 'accept_all_theirs' then
    apply_all(diffview, 'accept_theirs')
    return
  end
  if action == 'reset_result' then
    reset_result(diffview)
    return
  end
  if action == 'complete_merge' then
    M.complete(diffview)
    return
  end
  if action == 'continue_operation' then
    filetree.continue_operation()
    return
  end

  apply_action(diffview, action)
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
          handle_action_keymap(diffview, action)
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

      schedule_result_sync(diffview, file)
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
  return state.active == true or special.is_active()
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
  if not flush_result_sync_or_notify(diffview) then
    return false
  end

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
  if not flush_result_sync_or_notify(diffview) then
    return false
  end

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
  if special.is_active() then
    return special.equalize_panes(diffview)
  end
  if not state.active then
    return false
  end

  layout.equalize(diffview)
  return true
end

function M.hoverable_separator_wins(diffview)
  if special.is_active() then
    return special.hoverable_separator_wins(diffview)
  end
  if not state.active then
    return nil
  end

  return layout.hoverable_separator_wins(diffview)
end

local function rebuild(diffview, file, existing_model)
  local merge_model = existing_model
  if not merge_model then
    local err
    merge_model, err = model.build(file)
    if not merge_model then
      return nil, err
    end
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
  cancel_result_sync()

  local info = git.get_conflict_info(file)
  if special.open(diffview, file, info) then
    state.active = false
    state.file = nil
    state.model = nil
    state.active_conflict_index = nil
    return
  end

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

  rebuild(diffview, file, merge_model)

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
  if special.is_active() then
    return special.refresh(diffview, file)
  end

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

function M.complete(diffview)
  if special.is_active() then
    return special.complete(diffview)
  end

  if not state.active or not state.file then
    return false
  end

  local wrote, write_err = write_result_if_modified(diffview)
  if not wrote then
    local manual_count = manual_unresolved_count()
    if manual_count > 0 then
      vim.notify(
        string.format('glance: cannot complete merge; mark %d manual conflict%s resolved first', manual_count, manual_count == 1 and '' or 's'),
        vim.log.levels.WARN
      )
    else
      vim.notify('glance: failed to complete merge: ' .. tostring(write_err), vim.log.levels.WARN)
    end
    return false
  end

  local merge_model, sync_err = sync_from_result_buffer(diffview, state.file, state.model)
  if not merge_model then
    vim.notify('glance: failed to complete merge: ' .. tostring(sync_err), vim.log.levels.WARN)
    return false
  end

  if merge_model.unresolved_count > 0 then
    local manual_count = manual_unresolved_count()
    if manual_count > 0 then
      vim.notify(
        string.format('glance: cannot complete merge; mark %d manual conflict%s resolved first', manual_count, manual_count == 1 and '' or 's'),
        vim.log.levels.WARN
      )
    else
      vim.notify(
        string.format('glance: cannot complete merge; %d unresolved conflict%s remain', merge_model.unresolved_count, merge_model.unresolved_count == 1 and '' or 's'),
        vim.log.levels.WARN
      )
    end
    return false
  end

  local completed_file = state.file
  local context = git.get_operation_context()
  local ok, err = git.stage_merge_result(completed_file)
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

function M.reset()
  cancel_result_sync()
  state.active = false
  state.file = nil
  state.model = nil
  state.active_conflict_index = nil
  state.write_in_progress = false
  state.sync_in_progress = false
  state.result_sync_pending = false
  help.close()
  special.reset()
end

return M
