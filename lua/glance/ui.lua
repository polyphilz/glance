local config = require('glance.config')
local filetree = require('glance.filetree')

local M = {}

local ns = vim.api.nvim_create_namespace('glance_welcome')
local WELCOME_FRAME_MS = 150
local TEXT_LOGO = {
  text = 'glance',
  width = #'glance',
  height = 1,
}

local STAR_FRAMES = {
  { char = '.', hl = 'GlanceWelcomeStar0' },
  { char = '.', hl = 'GlanceWelcomeStar0' },
  { char = '.', hl = 'GlanceWelcomeStar1' },
  { char = '+', hl = 'GlanceWelcomeStar1' },
  { char = '*', hl = 'GlanceWelcomeStar2' },
  { char = '+', hl = 'GlanceWelcomeStar1' },
  { char = '.', hl = 'GlanceWelcomeStar1' },
  { char = '.', hl = 'GlanceWelcomeStar0' },
}

-- State
M.diff_open = false
M.welcome_buf = nil
M.welcome_win = nil
M.welcome_timer = nil
M.animation_tick = 0
M.starfield = nil
M.starfield_key = nil

local function hex_to_rgb(color)
  return tonumber(color:sub(2, 3), 16), tonumber(color:sub(4, 5), 16), tonumber(color:sub(6, 7), 16)
end

local function blend(color_a, color_b, t)
  local ar, ag, ab = hex_to_rgb(color_a)
  local br, bg, bb = hex_to_rgb(color_b)
  local r = math.floor(ar + (br - ar) * t + 0.5)
  local g = math.floor(ag + (bg - ag) * t + 0.5)
  local b = math.floor(ab + (bb - ab) * t + 0.5)
  return string.format('#%02x%02x%02x', r, g, b)
end

function M.setup_welcome_highlights(palette)
  local base = (palette and palette.base) or '#677A83'
  local bright = (palette and palette.bright) or '#D7D7D7'

  vim.api.nvim_set_hl(0, 'GlanceWelcomeLogo', {
    fg = base,
    italic = true,
  })

  vim.api.nvim_set_hl(0, 'GlanceWelcomeStar0', { fg = blend(base, bright, 0.10) })
  vim.api.nvim_set_hl(0, 'GlanceWelcomeStar1', { fg = blend(base, bright, 0.45) })
  vim.api.nvim_set_hl(0, 'GlanceWelcomeStar2', { fg = bright, bold = true })
end

local function select_logo()
  return TEXT_LOGO
end

local function fract(value)
  return value - math.floor(value)
end

local function hash(seed)
  return fract(math.sin(seed * 12.9898 + 78.233) * 43758.5453)
end

local function stop_welcome_animation()
  if M.welcome_timer then
    M.welcome_timer:stop()
    M.welcome_timer:close()
    M.welcome_timer = nil
  end
end

local function star_frame(star)
  local index = math.floor((M.animation_tick + star.offset) / star.speed) % #STAR_FRAMES + 1
  return STAR_FRAMES[index]
end

local function generate_starfield(width, height, box)
  local stars = {}
  local seen = {}
  local target = math.max(8, math.floor(width * height / 220))
  local top = math.max(1, box.top - 2)
  local bottom = math.min(height, box.top + box.height + 1)
  local left = math.max(1, box.left - 3)
  local right = math.min(width, box.left + box.width + 2)

  for attempt = 1, target * 20 do
    local row = math.floor(hash(width + attempt * 1.93) * height) + 1
    local col = math.floor(hash(height + attempt * 4.67) * width) + 1
    local key = row .. ':' .. col
    local inside_logo_box = row >= top and row <= bottom and col >= left and col <= right

    if not inside_logo_box and not seen[key] then
      seen[key] = true
      stars[#stars + 1] = {
        row = row,
        col = col,
        offset = math.floor(hash(attempt * 7.17) * (#STAR_FRAMES * 3)),
        speed = 1 + math.floor(hash(attempt * 9.91) * 3),
      }
    end

    if #stars >= target then
      break
    end
  end

  return stars
end

local function ensure_starfield(width, height, box)
  local key = table.concat({
    width,
    height,
    box.top,
    box.left,
    box.height,
    box.width,
  }, ':')

  if M.starfield_key == key and M.starfield then
    return
  end

  M.starfield = generate_starfield(width, height, box)
  M.starfield_key = key
end

--- Create a centered "glance" welcome buffer.
local function create_welcome_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'swapfile', false)
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  return buf
end

--- Fill the welcome buffer with centered "glance" text.
local function render_welcome()
  if not M.welcome_buf or not vim.api.nvim_buf_is_valid(M.welcome_buf) then return end
  if not M.welcome_win or not vim.api.nvim_win_is_valid(M.welcome_win) then return end

  local width = vim.api.nvim_win_get_width(M.welcome_win)
  local height = vim.api.nvim_win_get_height(M.welcome_win)

  local logo = select_logo()
  local logo_top = math.max(1, math.floor((height - logo.height) / 2) + 1)
  local logo_left = math.max(1, math.floor((width - logo.width) / 2) + 1)
  local logo_box = {
    top = logo_top,
    left = logo_left,
    width = logo.width,
    height = logo.height,
  }

  ensure_starfield(width, height, logo_box)

  local canvas = {}
  local highlights = {}
  for row = 1, height do
    canvas[row] = {}
    for col = 1, width do
      canvas[row][col] = ' '
    end
  end

  for _, star in ipairs(M.starfield or {}) do
    local frame = star_frame(star)
    canvas[star.row][star.col] = frame.char
    highlights[#highlights + 1] = { star.row - 1, star.col - 1, frame.hl }
  end

  local row = logo_top
  for col_idx = 1, #logo.text do
    local col = logo_left + col_idx - 1
    if col <= width then
      canvas[row][col] = logo.text:sub(col_idx, col_idx)
      highlights[#highlights + 1] = {
        row - 1,
        col - 1,
        'GlanceWelcomeLogo',
      }
    end
  end

  local lines = {}
  for row = 1, height do
    lines[row] = table.concat(canvas[row])
  end

  vim.api.nvim_buf_set_option(M.welcome_buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.welcome_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.welcome_buf, 'modifiable', false)

  vim.api.nvim_buf_clear_namespace(M.welcome_buf, ns, 0, -1)
  for _, item in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(M.welcome_buf, ns, item[3], item[1], item[2], item[2] + 1)
  end
end

local function start_welcome_animation()
  stop_welcome_animation()
  M.animation_tick = 0
  M.welcome_timer = vim.uv.new_timer()
  if not M.welcome_timer then
    return
  end

  M.welcome_timer:start(WELCOME_FRAME_MS, WELCOME_FRAME_MS, vim.schedule_wrap(function()
    if not M.welcome_buf or not vim.api.nvim_buf_is_valid(M.welcome_buf) then
      stop_welcome_animation()
      return
    end
    if not M.welcome_win or not vim.api.nvim_win_is_valid(M.welcome_win) then
      stop_welcome_animation()
      return
    end

    M.animation_tick = M.animation_tick + 1
    render_welcome()
  end))
end

--- Show the welcome pane to the right of the filetree.
function M.show_welcome()
  if M.welcome_win and vim.api.nvim_win_is_valid(M.welcome_win) then return end

  M.welcome_buf = create_welcome_buf()

  vim.api.nvim_set_current_win(filetree.win)
  vim.cmd('rightbelow vnew')
  M.welcome_win = vim.api.nvim_get_current_win()
  local scratch_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(M.welcome_win, M.welcome_buf)
  if vim.api.nvim_buf_is_valid(scratch_buf) and scratch_buf ~= M.welcome_buf then
    vim.api.nvim_buf_delete(scratch_buf, { force = true })
  end

  -- Window options
  vim.api.nvim_win_set_option(M.welcome_win, 'number', false)
  vim.api.nvim_win_set_option(M.welcome_win, 'relativenumber', false)
  vim.api.nvim_win_set_option(M.welcome_win, 'signcolumn', 'no')
  vim.api.nvim_win_set_option(M.welcome_win, 'cursorline', false)

  -- Constrain filetree to its fixed width after the split
  vim.api.nvim_win_set_width(filetree.win, config.options.filetree_width)

  render_welcome()
  start_welcome_animation()

  -- Re-render on resize
  vim.api.nvim_create_autocmd('VimResized', {
    buffer = M.welcome_buf,
    callback = function()
      M.starfield = nil
      M.starfield_key = nil
      vim.schedule(render_welcome)
    end,
  })

  -- Bounce focus back to filetree if user navigates into welcome pane
  vim.api.nvim_create_autocmd('WinEnter', {
    buffer = M.welcome_buf,
    callback = function()
      if filetree.win and vim.api.nvim_win_is_valid(filetree.win) then
        vim.schedule(function()
          if filetree.win and vim.api.nvim_win_is_valid(filetree.win) then
            vim.api.nvim_set_current_win(filetree.win)
          end
        end)
      end
    end,
  })

  -- Focus back on filetree
  vim.api.nvim_set_current_win(filetree.win)
end

--- Close the welcome pane.
function M.close_welcome()
  stop_welcome_animation()
  M.animation_tick = 0
  M.starfield = nil
  M.starfield_key = nil
  if M.welcome_win and vim.api.nvim_win_is_valid(M.welcome_win) then
    vim.api.nvim_win_close(M.welcome_win, true)
  end
  M.welcome_win = nil
  M.welcome_buf = nil
end

--- Initial layout: fixed-width file tree + welcome pane.
function M.setup_layout()
  -- Delete the initial empty buffer and use our file tree buffer
  local initial_buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()

  local buf = filetree.create_buf()
  vim.api.nvim_win_set_buf(win, buf)
  filetree.win = win

  -- Delete the initial scratch buffer
  if vim.api.nvim_buf_is_valid(initial_buf) and initial_buf ~= buf then
    vim.api.nvim_buf_delete(initial_buf, { force = true })
  end

  -- Set file tree window options
  vim.api.nvim_win_set_option(win, 'number', false)
  vim.api.nvim_win_set_option(win, 'relativenumber', false)
  vim.api.nvim_win_set_option(win, 'signcolumn', 'no')
  vim.api.nvim_win_set_option(win, 'cursorline', true)
  vim.api.nvim_win_set_width(win, config.options.filetree_width)
  vim.api.nvim_win_set_option(win, 'winfixwidth', true)

  -- Show welcome pane
  M.show_welcome()

  -- If filetree is closed while welcome pane is showing (no diff open), quit
  vim.api.nvim_create_autocmd('WinClosed', {
    buffer = filetree.buf,
    callback = function()
      if not M.diff_open then
        vim.schedule(function() vim.cmd('qa!') end)
      end
    end,
  })
end

--- Open a file based on its type (modified, deleted, untracked/added).
function M.open_file(file)
  local diffview = require('glance.diffview')

  -- Close any existing diff first
  if M.diff_open then
    diffview.close()
  end

  -- Close welcome pane to make room for diff
  M.close_welcome()

  if file.status == 'D' then
    diffview.open_deleted(file)
  elseif file.status == '?' then
    diffview.open_untracked(file)
  elseif file.status == 'A' and file.section == 'staged' then
    diffview.open(file)
  elseif file.status == 'A' and file.section ~= 'staged' then
    diffview.open_untracked(file)
  else
    diffview.open(file)
  end

  M.diff_open = true
  filetree.highlight_active(file)
end

--- Close diff panes and restore the file tree + welcome pane.
function M.close_diff()
  M.diff_open = false
  filetree.highlight_active(nil)

  -- Re-focus and resize the file tree
  if filetree.win and vim.api.nvim_win_is_valid(filetree.win) then
    vim.api.nvim_set_current_win(filetree.win)
    vim.api.nvim_win_set_width(filetree.win, config.options.filetree_width)
    vim.api.nvim_win_set_option(filetree.win, 'winfixwidth', true)
  end

  -- Show welcome pane again
  M.show_welcome()

  -- Refresh the file tree to reflect any changes from editing
  filetree.refresh()
end

return M
