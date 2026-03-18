local config = require('glance.config')
local pane_navigation = require('glance.pane_navigation')

local M = {}
local FILETREE_NS = vim.api.nvim_create_namespace('glance_filetree')

-- State
M.buf = nil
M.win = nil
M.files = nil        -- The full files table { staged, changes, untracked, conflicts }
M.line_map = {}      -- Maps buffer line number -> file object (nil for headers/blanks)
M.active_file = nil  -- Currently viewed file in diff mode
M.selected_line = nil -- Tracks the cursor line set by j/k/J/K navigation
M.last_cursor_line = nil -- Tracks the previous cursor line for arrow-key snapping
M.repo_watchers = {}
M.repo_watch_signature = nil
M.repo_refresh_pending = false
M.repo_refresh_inflight = false
M.repo_refresh_generation = 0
M.repo_refresh_options = nil
M.repo_head_oid = nil
M.repo_root = nil
M.repo_snapshot_key = ''
M.repo_status_output = ''
M.repo_poll_timer = nil
M.repo_poll_backoff_index = 1
M.repo_poll_delay_ms = nil

local function filetree_options()
  return config.options.windows.filetree
end

local function filetree_config()
  return config.options.filetree
end

local function watch_options()
  return config.options.watch
end

local function repo_poll_enabled()
  return watch_options().enabled
    and watch_options().poll
end

local function repo_fs_watch_enabled()
  return watch_options().enabled
end

local function apply_window_options(win)
  local options = filetree_options()
  vim.api.nvim_win_set_option(win, 'number', options.number)
  vim.api.nvim_win_set_option(win, 'relativenumber', options.relativenumber)
  vim.api.nvim_win_set_option(win, 'signcolumn', options.signcolumn)
  vim.api.nvim_win_set_option(win, 'cursorline', options.cursorline)
  vim.api.nvim_win_set_option(win, 'winfixwidth', options.winfixwidth)
end

local function status_text(status)
  local signs = config.options.signs
  local map = {
    M = signs.modified,
    A = signs.added,
    D = signs.deleted,
    R = signs.renamed,
    C = signs.copied,
    T = signs.type_changed,
    U = signs.conflicted,
    ['?'] = signs.untracked,
  }
  return map[status] or status
end

local function display_path(file)
  if file.old_path then
    return file.old_path .. ' → ' .. file.path
  end
  return file.path
end

local function add_highlight(highlights, line, col_start, col_end, group)
  highlights[#highlights + 1] = { line, col_start, col_end, group }
end

local function legend_line_count()
  if filetree_config().show_legend then
    return 4
  end
  return 0
end

local function close_handle(handle)
  if not handle then
    return
  end

  pcall(function()
    handle:stop()
  end)
  pcall(function()
    handle:close()
  end)
end

local function files_empty(files)
  files = files or {}
  return #(files.conflicts or {}) == 0
    and #(files.staged or {}) == 0
    and #(files.changes or {}) == 0
    and #(files.untracked or {}) == 0
end

local function same_file_identity(left, right)
  return type(left) == 'table'
    and type(right) == 'table'
    and left.path == right.path
    and left.old_path == right.old_path
    and left.section == right.section
    and left.raw_status == right.raw_status
end

local function find_matching_file(files, target)
  if type(target) ~= 'table' then
    return nil
  end

  for _, section in ipairs({ 'conflicts', 'staged', 'changes', 'untracked' }) do
    for _, file in ipairs((files and files[section]) or {}) do
      if same_file_identity(file, target) then
        return file
      end
    end
  end

  return nil
end

local function restore_selection(saved_line)
  if not saved_line or not M.win or not vim.api.nvim_win_is_valid(M.win) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(M.buf)
  if line_count == 0 then
    M.selected_line = nil
    return
  end

  local target_line = math.min(saved_line, line_count)
  M.selected_line = target_line
  vim.api.nvim_win_set_cursor(M.win, { target_line, 4 })
  if M.line_map[target_line] then
    return
  end

  M.move_down()
  if not M.get_selected_file() then
    M.move_up()
  end
  if not M.get_selected_file() then
    M.selected_line = nil
  end
end

local function new_buffer_is_modified()
  local diffview = require('glance.diffview')
  if not diffview.new_buf or not vim.api.nvim_buf_is_valid(diffview.new_buf) then
    return false
  end

  if vim.api.nvim_buf_get_option(diffview.new_buf, 'buftype') ~= '' then
    return false
  end

  return vim.api.nvim_buf_get_option(diffview.new_buf, 'modified')
end

local function stop_repo_poll()
  if M.repo_poll_timer then
    pcall(function()
      M.repo_poll_timer:stop()
    end)
    pcall(function()
      M.repo_poll_timer:close()
    end)
    M.repo_poll_timer = nil
  end
  M.repo_poll_delay_ms = nil
end

local function repo_poll_intervals()
  local base = math.max(watch_options().interval_ms, 250)
  local max_delay = 3000
  local delays = {
    base,
    math.min(base * 2, max_delay),
    math.min(base * 4, max_delay),
    math.min(base * 8, max_delay),
    max_delay,
  }

  local deduped = {}
  for _, delay in ipairs(delays) do
    if deduped[#deduped] ~= delay then
      deduped[#deduped + 1] = delay
    end
  end

  return deduped
end

local function reset_repo_poll_backoff()
  M.repo_poll_backoff_index = 1
end

local function advance_repo_poll_backoff()
  local delays = repo_poll_intervals()
  M.repo_poll_backoff_index = math.min((M.repo_poll_backoff_index or 1) + 1, #delays)
end

local function current_repo_poll_delay()
  local delays = repo_poll_intervals()
  local index = math.min(math.max(M.repo_poll_backoff_index or 1, 1), #delays)
  M.repo_poll_backoff_index = index
  return delays[index]
end

local function repo_poll_backoff_exhausted()
  local delays = repo_poll_intervals()
  return (M.repo_poll_backoff_index or 1) >= #delays
end

local function schedule_repo_poll(reset_backoff)
  if not repo_poll_enabled() then
    stop_repo_poll()
    reset_repo_poll_backoff()
    return
  end

  if reset_backoff then
    reset_repo_poll_backoff()
  end

  if not M.repo_poll_timer then
    M.repo_poll_timer = vim.uv.new_timer()
  end
  if not M.repo_poll_timer then
    return
  end

  local delay = current_repo_poll_delay()
  M.repo_poll_delay_ms = delay

  pcall(function()
    M.repo_poll_timer:stop()
  end)

  local ok = pcall(function()
    M.repo_poll_timer:start(delay, 0, function()
      if not M.buf then
        return
      end
      M.schedule_repo_refresh({ source = 'poll' })
    end)
  end)

  if not ok then
    close_handle(M.repo_poll_timer)
    M.repo_poll_timer = nil
    M.repo_poll_delay_ms = nil
  end
end

local function stop_repo_watchers()
  for _, watcher in ipairs(M.repo_watchers) do
    close_handle(watcher)
  end
  M.repo_watchers = {}
  M.repo_watch_signature = nil
end

local function finalize_repo_poll(changed, opts)
  if not repo_poll_enabled() then
    stop_repo_poll()
    reset_repo_poll_backoff()
    return
  end

  opts = opts or {}
  if changed or opts.reset_poll then
    reset_repo_poll_backoff()
  elseif opts.source == 'poll' then
    if repo_poll_backoff_exhausted() then
      stop_repo_poll()
      return
    end
    advance_repo_poll_backoff()
  end

  schedule_repo_poll(false)
end

local function snap_to_nearest_file(line, prefer_up)
  local total = vim.api.nvim_buf_line_count(M.buf)

  local function scan(start_line, end_line, step)
    for i = start_line, end_line, step do
      if M.line_map[i] then
        M.selected_line = i
        vim.api.nvim_win_set_cursor(M.win, { i, 4 })
        return true
      end
    end
    return false
  end

  if prefer_up then
    if scan(line - 1, 1, -1) then
      return
    end
    scan(line + 1, total, 1)
    return
  end

  if scan(line + 1, total, 1) then
    return
  end
  scan(line - 1, 1, -1)
end

local function add_legend(lines, highlights)
  local km = config.options.keymaps
  local title = '  discard'
  local actions = '  [' .. km.discard_file .. '] file   [' .. km.discard_all .. '] all'
  local resize_hint = '  drag divider to resize'

  lines[#lines + 1] = title
  lines[#lines + 1] = actions
  lines[#lines + 1] = resize_hint
  lines[#lines + 1] = ''

  add_highlight(highlights, 1, 2, #title, 'GlanceLegendTitle')
  add_highlight(highlights, 2, 0, #actions, 'GlanceLegendText')
  add_highlight(highlights, 2, 2, 3, 'GlanceLegendBracket')
  add_highlight(highlights, 2, 3, 4, 'GlanceLegendKey')
  add_highlight(highlights, 2, 4, 5, 'GlanceLegendBracket')
  add_highlight(highlights, 2, 13, 14, 'GlanceLegendBracket')
  add_highlight(highlights, 2, 14, 15, 'GlanceLegendKey')
  add_highlight(highlights, 2, 15, 16, 'GlanceLegendBracket')
  add_highlight(highlights, 3, 0, #resize_hint, 'GlanceLegendHint')
end

--- Create the file tree buffer with appropriate settings.
function M.create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'swapfile', false)
  vim.api.nvim_buf_set_option(buf, 'filetype', 'glance')
  vim.api.nvim_buf_set_name(buf, 'glance://files')
  M.buf = buf
  M.setup_keymaps()
  pane_navigation.bind(buf)

  -- Snap cursor to nearest file entry whenever it lands on a header/blank
  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = function()
      if not M.win or not vim.api.nvim_win_is_valid(M.win) then return end
      local line = vim.api.nvim_win_get_cursor(M.win)[1]
      local previous_line = M.last_cursor_line
      M.last_cursor_line = line
      if M.line_map[line] then
        M.selected_line = line
        return
      end
      snap_to_nearest_file(line, previous_line ~= nil and line < previous_line)
    end,
  })

  return buf
end

--- Render the file list with section headers into the buffer.
function M.render(files)
  files = files or {}
  files = {
    conflicts = files.conflicts or {},
    staged = files.staged or {},
    changes = files.changes or {},
    untracked = files.untracked or {},
  }

  M.files = files
  M.line_map = {}
  M.selected_line = nil

  local lines = {}
  local highlights = {} -- { line, col_start, col_end, hl_group }
  if filetree_config().show_legend then
    add_legend(lines, highlights)
  end

  local function add_section(title, file_list)
    if #file_list == 0 then
      return
    end

    -- Blank line before section (except at the very start)
    if #lines > legend_line_count() then
      table.insert(lines, '')
      -- line_map entry is nil by default (no action needed)
    end

    -- Section header
    local header = '  ' .. title
    table.insert(lines, header)
    add_highlight(highlights, #lines, 0, #header, 'GlanceSectionHeader')
    -- line_map entry is nil by default (no action needed)

    -- File entries
    for _, file in ipairs(file_list) do
      local line = '    ' .. status_text(file.status) .. ' ' .. display_path(file)
      table.insert(lines, line)
      M.line_map[#lines] = file

      -- Highlight the status character
      local hl_group = M.status_highlight(file.status)
      if hl_group then
        add_highlight(highlights, #lines, 4, 5, hl_group)
      end
    end
  end

  add_section('Conflicts', files.conflicts)
  add_section('Staged Changes', files.staged)
  add_section('Changes', files.changes)
  add_section('Untracked', files.untracked)

  -- Handle empty state
  if #lines == legend_line_count() then
    lines[#lines + 1] = '  No changes found'
    add_highlight(highlights, #lines, 0, 20, 'Comment')
  end

  -- Write to buffer
  vim.api.nvim_buf_set_option(M.buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, 'modifiable', false)

  -- Apply highlights
  vim.api.nvim_buf_clear_namespace(M.buf, FILETREE_NS, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(M.buf, FILETREE_NS, hl[4], hl[1] - 1, hl[2], hl[3])
  end

  -- Place cursor on the first file entry
  M.move_to_first_file()
end

--- Get the highlight group for a status character.
function M.status_highlight(status)
  local map = {
    M = 'GlanceStatusM',
    A = 'GlanceStatusA',
    D = 'GlanceStatusD',
    R = 'GlanceStatusR',
    C = 'GlanceStatusC',
    T = 'GlanceStatusT',
    U = 'GlanceStatusConflict',
    ['?'] = 'GlanceStatusU',
  }
  return map[status]
end

--- Get the file object under the cursor.
function M.get_selected_file()
  if not M.selected_line then
    return nil
  end
  return M.line_map[M.selected_line]
end

--- Move cursor to the next file entry (skip headers and blanks).
function M.move_down()
  local current = M.selected_line or 0
  local total = vim.api.nvim_buf_line_count(M.buf)

  for i = current + 1, total do
    if M.line_map[i] then
      M.selected_line = i
      vim.api.nvim_win_set_cursor(M.win, { i, 4 })
      return
    end
  end
end

--- Move cursor to the previous file entry (skip headers and blanks).
function M.move_up()
  local current = M.selected_line or 2

  for i = current - 1, 1, -1 do
    if M.line_map[i] then
      M.selected_line = i
      vim.api.nvim_win_set_cursor(M.win, { i, 4 })
      return
    end
  end
end

--- Jump to the first file in the next section.
function M.next_section()
  local current = M.selected_line or 0
  local total = vim.api.nvim_buf_line_count(M.buf)
  local found_blank = false

  for i = current + 1, total do
    if M.line_map[i] == nil then
      found_blank = true
    elseif found_blank and M.line_map[i] then
      M.selected_line = i
      vim.api.nvim_win_set_cursor(M.win, { i, 4 })
      return
    end
  end
end

--- Jump to the first file in the previous section.
function M.prev_section()
  local current = M.selected_line or 2

  -- First, find the start of the current section (go up to the header)
  local current_section_start = nil
  for i = current - 1, 1, -1 do
    if M.line_map[i] == nil then
      current_section_start = i
      break
    end
  end

  if not current_section_start then
    return
  end

  -- Now find the first file in the previous section
  local found_file_in_prev = false
  for i = current_section_start - 1, 1, -1 do
    if M.line_map[i] then
      found_file_in_prev = true
    elseif found_file_in_prev and M.line_map[i] == nil then
      for j = i + 1, current_section_start - 1 do
        if M.line_map[j] then
          M.selected_line = j
          vim.api.nvim_win_set_cursor(M.win, { j, 4 })
          return
        end
      end
    end
  end

  if found_file_in_prev then
    for i = 1, current_section_start - 1 do
      if M.line_map[i] then
        M.selected_line = i
        vim.api.nvim_win_set_cursor(M.win, { i, 4 })
        return
      end
    end
  end
end

--- Move cursor to the first file entry in the buffer.
function M.move_to_first_file()
  if not M.win or not vim.api.nvim_win_is_valid(M.win) then
    return
  end
  local total = vim.api.nvim_buf_line_count(M.buf)
  for i = 1, total do
    if M.line_map[i] then
      M.selected_line = i
      vim.api.nvim_win_set_cursor(M.win, { i, 4 })
      return
    end
  end
end

--- Highlight the currently active file (being viewed in diff).
function M.highlight_active(file)
  M.active_file = file
  local ns = vim.api.nvim_create_namespace('glance_active')
  vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)

  if not file then
    return
  end

  local total = vim.api.nvim_buf_line_count(M.buf)
  for i = 1, total do
    local f = M.line_map[i]
    if f and f.path == file.path and f.section == file.section then
      vim.api.nvim_buf_add_highlight(M.buf, ns, 'GlanceActiveFile', i - 1, 0, -1)
      break
    end
  end
end

function M.apply_status_snapshot(snapshot)
  local saved_line = M.selected_line
  snapshot = snapshot or {
    output = '',
    head_oid = nil,
    key = '',
    files = nil,
  }

  M.repo_head_oid = snapshot.head_oid
  M.repo_snapshot_key = snapshot.key or ''
  M.repo_status_output = snapshot.output or ''
  M.render(snapshot.files)
  restore_selection(saved_line)
end

local function sync_repo_watchers()
  local git = require('glance.git')
  local paths = {}
  local signature = ''
  local watch_enabled = repo_fs_watch_enabled()

  if watch_enabled then
    paths = git.repo_watch_paths()
    signature = table.concat(paths, '\n')
  end

  if signature == M.repo_watch_signature then
    return
  end

  stop_repo_watchers()
  M.repo_watch_signature = signature

  for _, path in ipairs(paths) do
    local watcher = vim.uv.new_fs_poll()
    if watcher then
      local ok = pcall(function()
        watcher:start(path, watch_options().interval_ms, function(err)
          if err then
            return
          end
          M.schedule_repo_refresh({
            source = 'watch',
            reset_poll = true,
            resync_watchers = true,
          })
        end)
      end)

      if ok then
        M.repo_watchers[#M.repo_watchers + 1] = watcher
      else
        close_handle(watcher)
      end
    end
  end
end

function M.stop_repo_watch()
  M.repo_refresh_generation = M.repo_refresh_generation + 1
  stop_repo_poll()
  stop_repo_watchers()
  M.repo_refresh_pending = false
  M.repo_refresh_inflight = false
  M.repo_refresh_options = nil
  reset_repo_poll_backoff()
end

function M.handle_repo_status_change(snapshot, opts)
  local ui = require('glance.ui')
  local diffview = require('glance.diffview')
  local active_before = M.active_file
  local previous_head_oid = M.repo_head_oid

  opts = opts or {}
  snapshot = snapshot or require('glance.git').get_status_snapshot()
  if (snapshot.key or '') == M.repo_snapshot_key then
    if opts.resync_watchers then
      sync_repo_watchers()
    end
    finalize_repo_poll(false, opts)
    return false
  end

  local head_changed = snapshot.head_oid ~= previous_head_oid
  local active_after = find_matching_file(snapshot.files, active_before)
  if ui.diff_open and active_before and not active_after then
    if new_buffer_is_modified() then
      M.apply_status_snapshot(snapshot)
      M.highlight_active(nil)
      vim.notify(
        'glance: active diff changed in Git; keeping the current buffer open because it has unsaved edits',
        vim.log.levels.WARN
      )
      sync_repo_watchers()
      finalize_repo_poll(true, opts)
      return true
    end

    M.apply_status_snapshot(snapshot)
    diffview.close(false)
    sync_repo_watchers()
    finalize_repo_poll(true, opts)
    return true
  end

  M.apply_status_snapshot(snapshot)
  if ui.diff_open and active_after then
    M.highlight_active(active_after)
    if head_changed and active_after.section == 'staged' then
      diffview.refresh(active_after)
    end
  end

  if not ui.diff_open and files_empty(snapshot.files) then
    M.highlight_active(nil)
  end

  sync_repo_watchers()
  finalize_repo_poll(true, opts)
  return true
end

function M.schedule_repo_refresh(opts)
  opts = opts or {}
  local pending_opts = M.repo_refresh_options or {}
  pending_opts.reset_poll = pending_opts.reset_poll or opts.reset_poll
  pending_opts.resync_watchers = pending_opts.resync_watchers or opts.resync_watchers
  if pending_opts.source == nil or pending_opts.source == 'poll' then
    pending_opts.source = opts.source or pending_opts.source
  end
  M.repo_refresh_options = pending_opts

  if M.repo_refresh_pending or M.repo_refresh_inflight then
    return
  end

  if pending_opts.source == 'poll'
    and not pending_opts.reset_poll
    and not pending_opts.resync_watchers
  then
    local refresh_generation = M.repo_refresh_generation
    M.repo_refresh_options = nil
    M.repo_refresh_inflight = true

    require('glance.git').get_status_snapshot_async(function(snapshot)
      if refresh_generation ~= M.repo_refresh_generation then
        M.repo_refresh_inflight = false
        return
      end

      if (snapshot.key or '') == M.repo_snapshot_key then
        M.repo_refresh_inflight = false
        finalize_repo_poll(false, pending_opts)
        if M.repo_refresh_options ~= nil then
          M.schedule_repo_refresh()
        end
        return
      end

      vim.schedule(function()
        if refresh_generation ~= M.repo_refresh_generation then
          M.repo_refresh_inflight = false
          return
        end
        if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
          M.repo_refresh_inflight = false
          return
        end

        M.repo_refresh_inflight = false
        M.handle_repo_status_change(snapshot, pending_opts)
        if M.repo_refresh_options ~= nil then
          M.schedule_repo_refresh()
        end
      end)
    end, {
      root = M.repo_root,
      schedule_callback = false,
    })
    return
  end

  M.repo_refresh_pending = true
  vim.schedule(function()
    M.repo_refresh_pending = false
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
      M.repo_refresh_options = nil
      return
    end

    local pending_opts = M.repo_refresh_options or {}
    M.repo_refresh_options = nil
    M.repo_refresh_inflight = true
    local refresh_generation = M.repo_refresh_generation

    require('glance.git').get_status_snapshot_async(function(snapshot)
      if refresh_generation ~= M.repo_refresh_generation then
        M.repo_refresh_inflight = false
        return
      end

      M.repo_refresh_inflight = false
      if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then
        return
      end

      M.handle_repo_status_change(snapshot, pending_opts)
      if M.repo_refresh_options ~= nil then
        M.schedule_repo_refresh()
      end
    end)
  end)
end

function M.start_repo_watch()
  M.repo_root = require('glance.git').repo_root()
  sync_repo_watchers()
  schedule_repo_poll(true)
end

function M.note_repo_activity(opts)
  opts = opts or {}
  if opts.resync_watchers then
    sync_repo_watchers()
  end
  schedule_repo_poll(opts.reset_poll ~= false)
end

--- Re-fetch git status and re-render the file tree.
function M.refresh()
  M.handle_repo_status_change(require('glance.git').get_status_snapshot(), {
    source = 'manual',
    reset_poll = true,
    resync_watchers = true,
  })
end

--- Toggle the file tree sidebar visibility.
function M.toggle()
  local ui = require('glance.ui')
  if not ui.diff_open then
    return
  end

  local diffview = require('glance.diffview')

  if M.win and vim.api.nvim_win_is_valid(M.win) then
    -- Hide: close the window but keep the buffer
    vim.api.nvim_win_hide(M.win)
    M.win = nil
    diffview.equalize_panes()
  else
    -- Show: create a left split and put the filetree buffer in it
    vim.cmd('topleft vnew')
    local new_win = vim.api.nvim_get_current_win()
    local scratch_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_buf(new_win, M.buf)
    -- Delete the scratch buffer created by vnew
    if vim.api.nvim_buf_is_valid(scratch_buf) and scratch_buf ~= M.buf then
      vim.api.nvim_buf_delete(scratch_buf, { force = true })
    end
    M.win = new_win

    -- Reapply window options
    apply_window_options(M.win)
    vim.api.nvim_win_set_width(M.win, filetree_options().width)

    diffview.equalize_panes()

    -- Return focus to a diff pane
    if diffview.new_win and vim.api.nvim_win_is_valid(diffview.new_win) then
      vim.api.nvim_set_current_win(diffview.new_win)
    elseif diffview.old_win and vim.api.nvim_win_is_valid(diffview.old_win) then
      vim.api.nvim_set_current_win(diffview.old_win)
    end
  end
end

local function confirm_action(message, accept_label)
  return vim.fn.confirm(message, '&' .. accept_label .. '\n&Cancel', 2) == 1
end

local function notify_discard_file_error(file, err)
  local git = require('glance.git')
  if err == git.UNSUPPORTED_DISCARD_MESSAGE then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  vim.notify(
    'glance: failed to discard ' .. display_path(file) .. ': ' .. tostring(err),
    vim.log.levels.ERROR
  )
end

local function notify_discard_all_error(err)
  local git = require('glance.git')
  if err == git.UNSUPPORTED_DISCARD_MESSAGE then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  vim.notify('glance: failed to discard all changes: ' .. tostring(err), vim.log.levels.ERROR)
end

local function refresh_after_discard(active_file)
  local ui = require('glance.ui')
  M.refresh()
  if ui.diff_open and active_file then
    M.highlight_active(active_file)
  end
end

function M.discard_selected_file()
  local file = M.get_selected_file()
  if not file then
    return
  end

  local git = require('glance.git')
  local allowed, err = git.can_discard_file(file)
  if not allowed then
    notify_discard_file_error(file, err)
    return
  end

  if not confirm_action('Discard changes for ' .. display_path(file) .. '?', 'Discard') then
    return
  end

  local ui = require('glance.ui')
  local diffview = require('glance.diffview')
  local active_file = M.active_file
  if ui.diff_open and active_file and active_file.path == file.path then
    diffview.close(true)
    active_file = nil
  end

  local ok
  ok, err = git.discard_file(file)
  if not ok then
    notify_discard_file_error(file, err)
    return
  end

  refresh_after_discard(active_file)
end

function M.discard_all()
  local git = require('glance.git')
  local allowed, err = git.can_discard_all(M.files)
  if not allowed then
    notify_discard_all_error(err)
    return
  end

  if not confirm_action(
    'Discard all changes in this repository? This will also remove untracked files.',
    'Discard All'
  ) then
    return
  end

  local ui = require('glance.ui')
  if ui.diff_open then
    require('glance.diffview').close(true)
  end

  local ok
  ok, err = git.discard_all()
  if not ok then
    notify_discard_all_error(err)
    return
  end

  M.refresh()
end

--- Set up buffer-local keymaps for the file tree.
function M.setup_keymaps()
  local opts = { noremap = true, silent = true, buffer = M.buf }
  local km = config.options.keymaps

  vim.keymap.set('n', 'j', function() for _ = 1, vim.v.count1 do M.move_down() end end, opts)
  vim.keymap.set('n', 'k', function() for _ = 1, vim.v.count1 do M.move_up() end end, opts)
  vim.keymap.set('n', '<Down>', function() for _ = 1, vim.v.count1 do M.move_down() end end, opts)
  vim.keymap.set('n', '<Up>', function() for _ = 1, vim.v.count1 do M.move_up() end end, opts)
  vim.keymap.set('n', km.next_section, function() M.next_section() end, opts)
  vim.keymap.set('n', km.prev_section, function() M.prev_section() end, opts)
  vim.keymap.set('n', km.quit, function() vim.cmd('qa!') end, opts)
  vim.keymap.set('n', km.refresh, function() M.refresh() end, opts)
  vim.keymap.set('n', km.toggle_filetree, function() M.toggle() end, opts)
  vim.keymap.set('n', km.discard_file, function() M.discard_selected_file() end, opts)
  vim.keymap.set('n', km.discard_all, function() M.discard_all() end, opts)
  vim.keymap.set('n', km.open_file, function()
    local file = M.get_selected_file()
    if file then
      local ui = require('glance.ui')
      ui.open_file(file)
    end
  end, opts)
end

return M
