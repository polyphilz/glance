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
  local diffview = loaded['glance.diffview']
  local filetree = loaded['glance.filetree']
  local minimap = loaded['glance.minimap']
  local ui = loaded['glance.ui']

  if diffview and diffview.stop_watching then
    pcall(diffview.stop_watching)
  end

  clear_group(diffview and diffview.autocmd_group)
  clear_group(minimap and minimap.augroup)

  if ui then
    close_handle(ui.welcome_timer)
    ui.welcome_timer = nil
  end

  pcall(vim.cmd, 'silent! enew!')
  pcall(vim.cmd, 'silent! only')

  delete_buffer(minimap and minimap.buf)
  delete_buffer(ui and ui.welcome_buf)
  delete_buffer(diffview and diffview.old_buf)
  delete_buffer(diffview and diffview.new_buf)
  delete_buffer(filetree and filetree.buf)

  if diffview then
    diffview.old_buf = nil
    diffview.old_win = nil
    diffview.new_buf = nil
    diffview.new_win = nil
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
    ui.diff_open = false
    ui.welcome_buf = nil
    ui.welcome_win = nil
    ui.animation_tick = 0
    ui.starfield = nil
    ui.starfield_key = nil
  end

  reset_loaded_modules()
end

return M
