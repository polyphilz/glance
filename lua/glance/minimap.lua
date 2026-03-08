--- Diff minimap for glance.nvim
--- Renders a 1-column floating window on the right edge of the new (right) diff pane,
--- showing colored indicators at proportional positions for additions (green),
--- deletions (red), and changes (yellow).
---
--- Uses the half-block technique (▀/█) with separate fg/bg colors to achieve
--- 2x vertical resolution per terminal row.

local M = {}
local logic = require('glance.minimap_logic')

local ns = vim.api.nvim_create_namespace('glance_minimap')

-- State
M.buf = nil
M.win = nil
M.target_win = nil
M.old_lines = nil       -- cached old content for vim.diff()
M.cached_pixels = nil   -- cached pixel states (only recomputed on content change)
M.pixel_count = 0
M.total_logical = 0
M.augroup = vim.api.nvim_create_augroup('GlanceMinimap', { clear = true })

-- Diff state constants
local NONE = logic.states.NONE
local ADD = logic.states.ADD
local DELETE = logic.states.DELETE
local CHANGE = logic.states.CHANGE
local CURSOR = logic.states.CURSOR

-- Colors: muted for out-of-viewport, brighter for in-viewport
local COLORS = {
  [NONE]   = '#111111',
  [ADD]    = '#2ea043',
  [DELETE] = '#f85149',
  [CHANGE] = '#d29922',
  [CURSOR] = '#C8C8C8',
}

local VP_COLORS = {
  [NONE]   = '#2a2a2a',
  [ADD]    = '#2ea043',
  [DELETE] = '#f85149',
  [CHANGE] = '#d29922',
  [CURSOR] = '#C8C8C8',
}

-- Dynamic highlight group cache
local hl_cache = {}

--- Get or create a highlight group for a half-block cell.
--- fg = top pixel color, bg = bottom pixel color.
local function get_hl(top_state, bot_state, top_vp, bot_vp)
  local key = top_state .. bot_state .. (top_vp and 1 or 0) .. (bot_vp and 1 or 0)
  if hl_cache[key] then return hl_cache[key] end

  local name = 'GlanceMm' .. key
  local fg_pal = top_vp and VP_COLORS or COLORS
  local bg_pal = bot_vp and VP_COLORS or COLORS

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

--- Viewport-only update: re-render with current scroll position but cached pixels.
function M.update_viewport()
  if not M.cached_pixels or not M.win or not vim.api.nvim_win_is_valid(M.win) then return end
  if not M.target_win or not vim.api.nvim_win_is_valid(M.target_win) then return end

  -- Reposition float in case of resize
  local wh = vim.api.nvim_win_get_height(M.target_win)
  local ww = vim.api.nvim_win_get_width(M.target_win)
  pcall(vim.api.nvim_win_set_config, M.win, {
    relative = 'win',
    win = M.target_win,
    anchor = 'NE',
    row = 0,
    col = ww,
    width = 1,
    height = wh,
  })

  -- Recompute pixels if height changed
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

--- Full update: recompute diff hunks, downsample, and render.
function M.full_update()
  if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then return end
  if not M.win or not vim.api.nvim_win_is_valid(M.win) then return end
  if not M.target_win or not vim.api.nvim_win_is_valid(M.target_win) then return end
  if not M.old_lines then return end

  local new_buf = vim.api.nvim_win_get_buf(M.target_win)
  local wh = vim.api.nvim_win_get_height(M.target_win)
  M.pixel_count = wh * 2

  local new_lines = vim.api.nvim_buf_get_lines(new_buf, 0, -1, false)
  local line_types, total_lines = logic.compute_line_types(M.old_lines, new_lines)
  M.total_logical = total_lines
  M.cached_pixels = logic.downsample(line_types, total_lines, M.pixel_count)

  local vp_top, vp_bot = get_viewport()
  local vps, vpe = logic.viewport_pixels(vp_top, vp_bot, total_lines, M.pixel_count)
  local cpx = get_cursor_pixel(total_lines, M.pixel_count)
  render(M.cached_pixels, M.pixel_count, vps, vpe, cpx)
end

--- Create the floating window and buffer, then do initial render.
--- @param target_win number  The new (right) diff pane window
--- @param old_lines string[]  Old file content for diff computation
function M.open(target_win, old_lines)
  M.close()

  if not target_win or not vim.api.nvim_win_is_valid(target_win) then return end

  M.target_win = target_win
  M.old_lines = old_lines

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
    width = 1,
    height = wh,
    style = 'minimal',
    focusable = false,
    zindex = 50,
  })

  vim.api.nvim_win_set_option(M.win, 'winhighlight', 'Normal:GlanceMinimapBg,EndOfBuffer:GlanceMinimapBg')
  vim.api.nvim_win_set_option(M.win, 'winblend', 0)

  -- Initial render
  M.full_update()
  M.setup_autocmds()
end

--- Set up autocmds for scroll sync and content change tracking.
function M.setup_autocmds()
  vim.api.nvim_clear_autocmds({ group = M.augroup })

  local timer = nil
  local DEBOUNCE = 16 -- ~60fps

  local function debounced_viewport()
    if timer then timer:stop() end
    timer = vim.uv.new_timer()
    timer:start(DEBOUNCE, 0, vim.schedule_wrap(function()
      M.update_viewport()
    end))
  end

  -- Scroll / cursor move / resize -> cheap viewport update
  vim.api.nvim_create_autocmd({ 'WinScrolled', 'CursorMoved', 'CursorMovedI' }, {
    group = M.augroup,
    callback = debounced_viewport,
  })

  vim.api.nvim_create_autocmd('VimResized', {
    group = M.augroup,
    callback = function()
      vim.schedule(function() M.full_update() end)
    end,
  })

  -- Content changes -> full recompute
  if M.target_win and vim.api.nvim_win_is_valid(M.target_win) then
    local target_buf = vim.api.nvim_win_get_buf(M.target_win)
    if vim.api.nvim_buf_is_valid(target_buf) then
      vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost' }, {
        group = M.augroup,
        buffer = target_buf,
        callback = function()
          vim.schedule(function() M.full_update() end)
        end,
      })
    end
  end
end

--- Close and clean up the minimap.
function M.close()
  vim.api.nvim_clear_autocmds({ group = M.augroup })

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
  M.old_lines = nil
  M.cached_pixels = nil
  M.pixel_count = 0
  M.total_logical = 0
end

--- Reset the highlight cache (e.g. after colorscheme change).
function M.reset_highlights()
  hl_cache = {}
end

--- Define the background highlight for empty minimap regions.
function M.setup_highlights()
  vim.api.nvim_set_hl(0, 'GlanceMinimapBg', { bg = '#111111' })
end

return M
