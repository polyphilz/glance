--- Diff minimap for glance.nvim
--- Renders a 1-column floating window on the right edge of the new (right) diff pane,
--- showing colored indicators at proportional positions for additions (green),
--- deletions (red), and changes (yellow).
---
--- Uses the half-block technique (▀/█) with separate fg/bg colors to achieve
--- 2x vertical resolution per terminal row.

local M = {}
local config = require('glance.config')
local logic = require('glance.minimap_logic')

local ns = vim.api.nvim_create_namespace('glance_minimap')
local CONTENT_DEBOUNCE_MS = 120

-- State
M.buf = nil
M.win = nil
M.target_win = nil
M.mode = nil
M.old_lines = nil       -- cached old content for vim.diff()
M.merge_model = nil
M.active_conflict_index = nil
M.cached_pixels = nil   -- cached pixel states (only recomputed on content change)
M.pixel_count = 0
M.total_logical = 0
M.augroup = vim.api.nvim_create_augroup('GlanceMinimap', { clear = true })
M.debounce_timer = nil
M.content_timer = nil
M.content_dirty = false
M.full_update_pending = false
M.full_update_running = false
M.last_changedtick = nil
M.last_new_line_count = 0
M.last_pixel_count = 0

-- Diff state constants
local NONE = logic.states.NONE
local ADD = logic.states.ADD
local DELETE = logic.states.DELETE
local CHANGE = logic.states.CHANGE
local CURSOR = logic.states.CURSOR
local MERGE_UNRESOLVED = logic.states.MERGE_UNRESOLVED
local MERGE_HANDLED = logic.states.MERGE_HANDLED
local MERGE_MANUAL = logic.states.MERGE_MANUAL
local MERGE_ACTIVE = logic.states.MERGE_ACTIVE

-- Dynamic highlight group cache
local hl_cache = {}

local function minimap_config()
  return config.options.minimap
end

local function content_debounce_ms()
  return math.max(minimap_config().debounce_ms, CONTENT_DEBOUNCE_MS)
end

local function colors()
  local palette = config.options.theme.palette
  local manual = palette.manual or palette.number or palette.keyword
  return {
    [NONE] = palette.minimap_bg,
    [ADD] = palette.added,
    [DELETE] = palette.deleted,
    [CHANGE] = palette.changed,
    [CURSOR] = palette.minimap_cursor,
    [MERGE_UNRESOLVED] = palette.changed,
    [MERGE_HANDLED] = palette.added,
    [MERGE_MANUAL] = manual,
    [MERGE_ACTIVE] = palette.minimap_cursor,
  }, {
    [NONE] = palette.minimap_viewport_bg,
    [ADD] = palette.added,
    [DELETE] = palette.deleted,
    [CHANGE] = palette.changed,
    [CURSOR] = palette.minimap_cursor,
    [MERGE_UNRESOLVED] = palette.changed,
    [MERGE_HANDLED] = palette.added,
    [MERGE_MANUAL] = manual,
    [MERGE_ACTIVE] = palette.minimap_cursor,
  }
end

local function close_debounce_timer()
  if M.debounce_timer then
    M.debounce_timer:stop()
    M.debounce_timer:close()
    M.debounce_timer = nil
  end
end

local function close_content_timer()
  if M.content_timer then
    M.content_timer:stop()
    M.content_timer:close()
    M.content_timer = nil
  end
end

--- Get or create a highlight group for a half-block cell.
--- fg = top pixel color, bg = bottom pixel color.
local function get_hl(top_state, bot_state, top_vp, bot_vp)
  local key = top_state .. bot_state .. (top_vp and 1 or 0) .. (bot_vp and 1 or 0)
  if hl_cache[key] then return hl_cache[key] end

  local name = 'GlanceMm' .. key
  local base_colors, viewport_colors = colors()
  local fg_pal = top_vp and viewport_colors or base_colors
  local bg_pal = bot_vp and viewport_colors or base_colors

  vim.api.nvim_set_hl(0, name, {
    fg = fg_pal[top_state],
    bg = bg_pal[bot_state],
  })

  hl_cache[key] = name
  return name
end

--- Get visible line range in the target window.
local function get_viewport()
  if not M.target_win or not vim.api.nvim_win_is_valid(M.target_win) then
    return 1, 1
  end
  local top = vim.api.nvim_win_call(M.target_win, function() return vim.fn.line('w0') end)
  local bot = vim.api.nvim_win_call(M.target_win, function() return vim.fn.line('w$') end)
  return top, bot
end

--- Get the cursor line in the target window, mapped to a pixel index.
local function get_cursor_pixel(total_lines, pixel_count)
  if not M.target_win or not vim.api.nvim_win_is_valid(M.target_win) then return nil end
  if total_lines == 0 or pixel_count == 0 then return nil end
  local cursor_line = vim.api.nvim_win_call(M.target_win, function()
    return vim.fn.line('.')
  end)
  return logic.cursor_pixel(cursor_line, total_lines, pixel_count)
end

local function has_valid_state()
  return M.buf and vim.api.nvim_buf_is_valid(M.buf)
    and M.win and vim.api.nvim_win_is_valid(M.win)
    and M.target_win and vim.api.nvim_win_is_valid(M.target_win)
    and (
      (M.mode == 'diff' and M.old_lines ~= nil)
      or (M.mode == 'merge' and M.merge_model ~= nil)
    )
end

local function target_buf()
  if not M.target_win or not vim.api.nvim_win_is_valid(M.target_win) then
    return nil
  end

  local buf = vim.api.nvim_win_get_buf(M.target_win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  return buf
end

local function sync_float_geometry()
  if not M.win or not vim.api.nvim_win_is_valid(M.win) then
    return nil
  end
  if not M.target_win or not vim.api.nvim_win_is_valid(M.target_win) then
    return nil
  end

  local wh = vim.api.nvim_win_get_height(M.target_win)
  local ww = vim.api.nvim_win_get_width(M.target_win)
  pcall(vim.api.nvim_win_set_config, M.win, {
    relative = 'win',
    win = M.target_win,
    anchor = 'NE',
    row = 0,
    col = ww,
    width = minimap_config().width,
    height = wh,
  })

  return wh
end

--- Render the minimap buffer using half-block characters.
local function render(pixels, pixel_count, vp_start_px, vp_end_px, cursor_px)
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then return end

  local row_count = math.ceil(pixel_count / 2)
  local lines = {}
  local hls = {}

  for row = 1, row_count do
    local ti = (row - 1) * 2 + 1
    local bi = ti + 1

    local ts = (cursor_px and ti == cursor_px) and CURSOR or (pixels[ti] or NONE)
    local bs = (cursor_px and bi == cursor_px) and CURSOR or (pixels[bi] or NONE)
    local tv = ti >= vp_start_px and ti <= vp_end_px
    local bv = bi >= vp_start_px and bi <= vp_end_px

    local char, hl
    if ts == bs and tv == bv then
      char = '█'
      hl = get_hl(ts, bs, tv, bv)
    else
      char = '▀'
      hl = get_hl(ts, bs, tv, bv)
    end

    lines[row] = char
    hls[row] = hl
  end

  vim.api.nvim_buf_set_option(M.buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, 'modifiable', false)

  vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
  for i, hl in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(M.buf, ns, hl, i - 1, 0, -1)
  end
end

local function render_from_cache()
  if not M.cached_pixels or not has_valid_state() then
    return
  end

  local wh = sync_float_geometry()
  if not wh then
    return
  end

  local needed = wh * 2
  if needed ~= M.pixel_count then
    M.full_update()
    return
  end

  local vp_top, vp_bot = get_viewport()
  local vps, vpe = logic.viewport_pixels(vp_top, vp_bot, M.total_logical, M.pixel_count)
  local cpx = get_cursor_pixel(M.total_logical, M.pixel_count)
  render(M.cached_pixels, M.pixel_count, vps, vpe, cpx)
end

local function run_full_update(opts)
  opts = opts or {}
  if M.full_update_running then
    M.full_update_pending = true
    return
  end

  M.full_update_running = true
  local ok, err = xpcall(function()
    M.full_update(opts)
  end, debug.traceback)
  M.full_update_running = false

  local rerun = M.full_update_pending
  M.full_update_pending = false
  if rerun and has_valid_state() then
    vim.schedule(function()
      if has_valid_state() then
        run_full_update()
      end
    end)
  end

  if not ok then
    error(err)
  end
end

--- Viewport-only update: re-render with current scroll position but cached pixels.
function M.update_viewport()
  render_from_cache()
end

function M.request_viewport_update()
  close_debounce_timer()
  M.debounce_timer = vim.uv.new_timer()
  if not M.debounce_timer then
    return
  end

  M.debounce_timer:start(minimap_config().debounce_ms, 0, vim.schedule_wrap(function()
    M.update_viewport()
    close_debounce_timer()
  end))
end

function M.flush_content_update(opts)
  opts = opts or {}
  if not opts.run_even_if_clean and not M.content_dirty then
    return
  end

  close_content_timer()
  run_full_update({ force_recompute = opts.force_recompute })
end

function M.request_content_update(opts)
  opts = opts or {}
  M.content_dirty = true

  if opts.immediate then
    M.flush_content_update({ run_even_if_clean = true, force_recompute = opts.force_recompute })
    return
  end

  close_content_timer()
  M.content_timer = vim.uv.new_timer()
  if not M.content_timer then
    return
  end

  M.content_timer:start(content_debounce_ms(), 0, vim.schedule_wrap(function()
    close_content_timer()
    M.flush_content_update()
  end))
end

--- Full update: recompute diff hunks, downsample, and render.
function M.full_update(opts)
  opts = opts or {}
  if not has_valid_state() then
    return
  end

  local new_buf = target_buf()
  if not new_buf then
    return
  end

  local wh = vim.api.nvim_win_get_height(M.target_win)
  local pixel_count = wh * 2
  local changedtick = vim.api.nvim_buf_get_changedtick(new_buf)
  local line_count = vim.api.nvim_buf_line_count(new_buf)

  M.pixel_count = pixel_count

  if not opts.force_recompute
    and M.cached_pixels
    and M.last_changedtick == changedtick
    and M.last_pixel_count == pixel_count
    and M.last_new_line_count == line_count
  then
    M.content_dirty = false
    render_from_cache()
    return
  end

  local new_lines = vim.api.nvim_buf_get_lines(new_buf, 0, -1, false)
  local line_types, total_lines
  if M.mode == 'merge' then
    line_types, total_lines = logic.compute_merge_line_types(
      M.merge_model.conflicts,
      math.max(#new_lines, vim.api.nvim_buf_line_count(new_buf)),
      M.active_conflict_index
    )
  else
    line_types, total_lines = logic.compute_line_types(M.old_lines, new_lines)
  end
  M.total_logical = total_lines
  M.cached_pixels = logic.downsample(line_types, total_lines, pixel_count)
  M.last_changedtick = changedtick
  M.last_new_line_count = line_count
  M.last_pixel_count = pixel_count
  M.content_dirty = false

  render_from_cache()
end

local function open_window(target_win)
  if not minimap_config().enabled then return end
  if not target_win or not vim.api.nvim_win_is_valid(target_win) then return end

  M.target_win = target_win

  -- Create scratch buffer
  M.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(M.buf, 'swapfile', false)
  vim.api.nvim_buf_set_option(M.buf, 'bufhidden', 'wipe')

  local wh = vim.api.nvim_win_get_height(target_win)
  local ww = vim.api.nvim_win_get_width(target_win)

  -- Create floating window anchored to right edge
  M.win = vim.api.nvim_open_win(M.buf, false, {
    relative = 'win',
    win = target_win,
    anchor = 'NE',
    row = 0,
    col = ww,
    width = minimap_config().width,
    height = wh,
    style = 'minimal',
    focusable = false,
    zindex = minimap_config().zindex,
  })

  vim.api.nvim_win_set_option(M.win, 'winhighlight', 'Normal:GlanceMinimapBg,EndOfBuffer:GlanceMinimapBg')
  vim.api.nvim_win_set_option(M.win, 'winblend', minimap_config().winblend)

  -- Initial render
  M.full_update({ force_recompute = true })
  M.setup_autocmds()
end

--- Create the floating window and buffer, then do initial render.
--- @param target_win number  The new (right) diff pane window
--- @param old_lines string[]  Old file content for diff computation
function M.open(target_win, old_lines)
  M.close()
  M.mode = 'diff'
  M.old_lines = old_lines
  M.merge_model = nil
  M.active_conflict_index = nil
  open_window(target_win)
end

--- Create a merge minimap on the Result pane.
--- @param target_win number
--- @param merge_model table
--- @param active_conflict_index integer|nil
function M.open_merge(target_win, merge_model, active_conflict_index)
  M.close()
  M.mode = 'merge'
  M.old_lines = nil
  M.merge_model = merge_model
  M.active_conflict_index = active_conflict_index
  open_window(target_win)
end

--- Update merge minimap state after conflict actions, edits, or active conflict changes.
function M.update_merge(merge_model, active_conflict_index)
  if M.mode ~= 'merge' or not M.win or not vim.api.nvim_win_is_valid(M.win) then
    return
  end

  M.merge_model = merge_model
  M.active_conflict_index = active_conflict_index
  M.full_update({ force_recompute = true })
end

--- Set up autocmds for scroll sync and content change tracking.
function M.setup_autocmds()
  vim.api.nvim_clear_autocmds({ group = M.augroup })
  close_debounce_timer()
  close_content_timer()

  -- Scroll / cursor move / resize -> cheap viewport update
  vim.api.nvim_create_autocmd({ 'WinScrolled', 'CursorMoved', 'CursorMovedI' }, {
    group = M.augroup,
    callback = function()
      M.request_viewport_update()
    end,
  })

  vim.api.nvim_create_autocmd('VimResized', {
    group = M.augroup,
    callback = function()
      M.request_viewport_update()
    end,
  })

  -- Content changes -> debounced full recompute
  if M.target_win and vim.api.nvim_win_is_valid(M.target_win) then
    local target_buf = vim.api.nvim_win_get_buf(M.target_win)
    if vim.api.nvim_buf_is_valid(target_buf) then
      vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
        group = M.augroup,
        buffer = target_buf,
        callback = function()
          M.request_content_update()
        end,
      })
    end
  end
end

--- Close and clean up the minimap.
function M.close()
  vim.api.nvim_clear_autocmds({ group = M.augroup })
  close_debounce_timer()
  close_content_timer()

  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  -- buf has bufhidden=wipe, so closing the window wipes it.
  -- But if the window was already gone, clean up manually.
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    pcall(vim.api.nvim_buf_delete, M.buf, { force = true })
  end

  M.win = nil
  M.buf = nil
  M.target_win = nil
  M.mode = nil
  M.old_lines = nil
  M.merge_model = nil
  M.active_conflict_index = nil
  M.cached_pixels = nil
  M.pixel_count = 0
  M.total_logical = 0
  M.content_dirty = false
  M.full_update_pending = false
  M.full_update_running = false
  M.last_changedtick = nil
  M.last_new_line_count = 0
  M.last_pixel_count = 0
end

--- Reset the highlight cache (e.g. after colorscheme change).
function M.reset_highlights()
  hl_cache = {}
end

--- Define the background highlight for empty minimap regions.
function M.setup_highlights()
  vim.api.nvim_set_hl(0, 'GlanceMinimapBg', { bg = config.options.theme.palette.minimap_bg })
end

return M
