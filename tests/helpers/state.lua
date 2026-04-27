local M = {}

local function clear_group(group)
  if group then
    pcall(vim.api.nvim_clear_autocmds, { group = group })
  end
end

local function close_handle(handle)
  if handle then
    pcall(function()
      handle:stop()
    end)
    pcall(function()
      handle:close()
    end)
  end
end

local function delete_buffer(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function close_window(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

local function reset_loaded_modules()
  for name in pairs(package.loaded) do
    if name == 'glance' or name:match('^glance%.') then
      package.loaded[name] = nil
    end
  end
end

--- Reset Glance module state, windows, buffers, and autocmds between tests.
function M.reset()
  local loaded = package.loaded
  local commit_editor = loaded['glance.commit_editor']
  local diffview = loaded['glance.diffview']
  local filetree = loaded['glance.filetree']
  local log_view = loaded['glance.log_view']
  local minimap = loaded['glance.minimap']
  local repo_sync = loaded['glance.repo_sync']
  local ui = loaded['glance.ui']
  local workspace = loaded['glance.workspace']

  local diff_wins = {}
  local diff_bufs = {}
  if diffview and diffview.workspace and workspace and workspace.collect_windows and workspace.collect_buffers then
    diff_wins = workspace.collect_windows(diffview.workspace, { with_pane = true })
    diff_bufs = workspace.collect_buffers(diffview.workspace, { with_pane = true })
  end

  if diffview and diffview.stop_watching then
    pcall(diffview.stop_watching)
  end
  if filetree and filetree.stop_repo_watch then
    pcall(filetree.stop_repo_watch)
  end
  if repo_sync and repo_sync.stop then
    pcall(repo_sync.stop)
  end

  clear_group(diffview and diffview.autocmd_group)
  clear_group('GlanceCommitEditor')
  clear_group('GlanceLogView')
  clear_group(minimap and minimap.augroup)
  clear_group('GlanceApp')

  if ui then
    close_handle(ui.welcome_timer)
    ui.welcome_timer = nil
  end

  pcall(vim.cmd, 'silent! enew!')
  pcall(vim.cmd, 'silent! only')

  close_window(commit_editor and commit_editor.win)
  close_window(log_view and log_view.win)
  for _, win in ipairs(diff_wins) do
    close_window(win)
  end
  delete_buffer(minimap and minimap.buf)
  delete_buffer(commit_editor and commit_editor.buf)
  delete_buffer(log_view and log_view.buf)
  delete_buffer(ui and ui.welcome_buf)
  delete_buffer(diffview and diffview.old_buf)
  delete_buffer(diffview and diffview.new_buf)
  for _, buf in ipairs(diff_bufs) do
    delete_buffer(buf)
  end
  delete_buffer(filetree and filetree.buf)

  if diffview then
    diffview.old_buf = nil
    diffview.old_win = nil
    diffview.new_buf = nil
    diffview.new_win = nil
    if diffview.reset_workspace then
      diffview.reset_workspace()
    end
    diffview.fs_watcher = nil
    diffview.closing = false
  end

  if filetree then
    filetree.buf = nil
    filetree.win = nil
    filetree.files = nil
    filetree.line_map = {}
    filetree.active_file = nil
    filetree.selected_line = nil
    filetree.last_cursor_line = nil
    filetree.repo_head_oid = nil
    filetree.repo_snapshot_key = ''
    filetree.repo_status_output = ''
  end

  if commit_editor then
    commit_editor.buf = nil
    commit_editor.win = nil
    commit_editor.on_submit = nil
    commit_editor.on_cancel = nil
    commit_editor.closing = false
    commit_editor.suppress_win_closed = false
  end

  if log_view then
    log_view.buf = nil
    log_view.win = nil
    log_view.mode = 'list'
    log_view.entries = {}
    log_view.line_map = {}
    log_view.entry_lines = {}
    log_view.selected_index = 1
    log_view.selected_hash = nil
    log_view.preview_hash = nil
    log_view.return_win = nil
    log_view.closing = false
  end

  if minimap then
    close_handle(minimap.debounce_timer)
    close_handle(minimap.content_timer)
    minimap.buf = nil
    minimap.win = nil
    minimap.target_win = nil
    minimap.old_lines = nil
    minimap.cached_pixels = nil
    minimap.pixel_count = 0
    minimap.total_logical = 0
    minimap.debounce_timer = nil
    minimap.content_timer = nil
    minimap.content_dirty = false
    minimap.full_update_pending = false
    minimap.full_update_running = false
    minimap.last_changedtick = nil
    minimap.last_new_line_count = 0
    minimap.last_pixel_count = 0
  end

  if ui then
    if ui.separator_hover_key_ns then
      pcall(vim.on_key, nil, ui.separator_hover_key_ns)
    end
    ui.diff_open = false
    ui.welcome_buf = nil
    ui.welcome_win = nil
    ui.animation_tick = 0
    ui.starfield = nil
    ui.starfield_key = nil
    ui.separator_hover_win = nil
    ui.separator_hover_targets = {}
    ui.separator_hover_key_ns = nil
    ui.separator_hover_pending = false
  end

  reset_loaded_modules()
end

return M
