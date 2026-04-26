local config = require('glance.config')
local filetree = require('glance.filetree')
local pane_navigation = require('glance.pane_navigation')

local M = {}
local SEPARATOR_HL = 'GlanceSeparatorHover'
local WELCOME_FRAME_MS = 150

local ns = vim.api.nvim_create_namespace('glance_welcome')
local LOGO_TEXT = 'glance'

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
M.separator_hover_win = nil

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
  local logo = (palette and palette.logo) or '#FD971F'

  vim.api.nvim_set_hl(0, 'GlanceWelcomeLogo', {
    fg = logo,
    italic = true,
  })

  vim.api.nvim_set_hl(0, 'GlanceWelcomeStar0', { fg = blend(base, bright, 0.10) })
  vim.api.nvim_set_hl(0, 'GlanceWelcomeStar1', { fg = blend(base, bright, 0.45) })
  vim.api.nvim_set_hl(0, 'GlanceWelcomeStar2', { fg = bright, bold = true })
end

local function select_logo()
  return {
    text = LOGO_TEXT,
    width = #LOGO_TEXT,
    height = 1,
  }
end

local function filetree_options()
  return config.options.windows.filetree
end

local function welcome_config()
  return config.options.welcome
end

local function apply_window_options(win, options)
  vim.api.nvim_win_set_option(win, 'number', options.number)
  vim.api.nvim_win_set_option(win, 'relativenumber', options.relativenumber)
  vim.api.nvim_win_set_option(win, 'signcolumn', options.signcolumn)
  vim.api.nvim_win_set_option(win, 'cursorline', options.cursorline)
  if options.winfixwidth ~= nil then
    vim.api.nvim_win_set_option(win, 'winfixwidth', options.winfixwidth)
  end
end

local function hoverable_separator_windows()
  local diffview = require('glance.diffview')
  local wins = {}

  for _, win in ipairs(diffview.hoverable_separator_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      wins[win] = true
    end
  end

  return wins
end

local function encode_winhighlight(items)
  local encoded = {}
  local keys = vim.tbl_keys(items)
  table.sort(keys)

  for _, key in ipairs(keys) do
    encoded[#encoded + 1] = key .. ':' .. items[key]
  end

  return table.concat(encoded, ',')
end

local function apply_separator_hover(win, active)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local current = vim.api.nvim_get_option_value('winhighlight', { win = win })
  local parsed = {}

  for part in current:gmatch('[^,]+') do
    local from, to = part:match('([^:]+):(.+)')
    if from and to then
      parsed[from] = to
    end
  end

  if active then
    parsed.WinSeparator = SEPARATOR_HL
  elseif parsed.WinSeparator == SEPARATOR_HL then
    parsed.WinSeparator = nil
  end

  vim.api.nvim_win_set_option(win, 'winhighlight', encode_winhighlight(parsed))
end

function M.clear_separator_hover()
  if M.separator_hover_win and vim.api.nvim_win_is_valid(M.separator_hover_win) then
    apply_separator_hover(M.separator_hover_win, false)
  end
  M.separator_hover_win = nil
end

local function hovered_separator_win(mouse)
  if type(mouse) ~= 'table' or mouse.winid == 0 or mouse.line ~= 0 or mouse.column ~= 0 then
    return nil
  end

  if not hoverable_separator_windows()[mouse.winid] then
    return nil
  end

  local pos = vim.fn.win_screenpos(mouse.winid)
  local top = pos[1]
  local left = pos[2]
  if top == nil or left == nil or top <= 0 or left <= 0 then
    return nil
  end

  local right_separator = left + vim.api.nvim_win_get_width(mouse.winid)
  if mouse.screencol ~= right_separator then
    return nil
  end

  return mouse.winid
end

function M.update_separator_hover(mouse)
  local win = hovered_separator_win(mouse or vim.fn.getmousepos())
  if win == M.separator_hover_win then
    return
  end

  M.clear_separator_hover()
  if win then
    apply_separator_hover(win, true)
    M.separator_hover_win = win
  end
end

function M.setup_separator_hover()
  vim.opt.mousemoveevent = true
  vim.keymap.set('n', '<MouseMove>', function()
    M.update_separator_hover()
  end, { silent = true })
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
  if not welcome_config().animate then
    return
  end

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
  pane_navigation.bind(M.welcome_buf)

  vim.api.nvim_set_current_win(filetree.win)
  vim.cmd('rightbelow vnew')
  M.welcome_win = vim.api.nvim_get_current_win()
  local scratch_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(M.welcome_win, M.welcome_buf)
  if vim.api.nvim_buf_is_valid(scratch_buf) and scratch_buf ~= M.welcome_buf then
    vim.api.nvim_buf_delete(scratch_buf, { force = true })
  end

  vim.api.nvim_win_set_option(M.welcome_win, 'number', false)
  vim.api.nvim_win_set_option(M.welcome_win, 'relativenumber', false)
  vim.api.nvim_win_set_option(M.welcome_win, 'signcolumn', 'no')
  vim.api.nvim_win_set_option(M.welcome_win, 'cursorline', false)

  -- Constrain filetree to its fixed width after the split
  vim.api.nvim_win_set_width(filetree.win, filetree_options().width)

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
  M.update_separator_hover()
end

--- Close the welcome pane.
function M.close_welcome()
  M.clear_separator_hover()
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
  local tree = filetree_options()
  apply_window_options(win, tree)
  vim.api.nvim_win_set_width(win, tree.width)
  M.setup_separator_hover()

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

local function infer_kind(file)
  if type(file) ~= 'table' then
    return 'unsupported'
  end

  if file.kind then
    return file.kind
  end

  if file.is_binary then
    return 'binary'
  end

  if file.section == 'conflicts' or file.status == 'U' then
    return 'conflicted'
  end
  if file.status == '?' then
    return 'untracked'
  end
  if file.status == 'D' then
    return 'deleted'
  end
  if file.status == 'R' then
    return 'renamed'
  end
  if file.status == 'C' then
    return 'copied'
  end
  if file.status == 'T' then
    return 'type_changed'
  end
  if file.status == 'A' then
    return 'added'
  end
  if file.status == 'M' then
    return 'modified'
  end

  return 'unsupported'
end

--- Open a file based on its classified git state.
function M.open_file(file)
  local diffview = require('glance.diffview')
  local git = require('glance.git')
  local is_binary = git.ensure_file_binary(file)
  local kind = infer_kind(file)

  -- Close any existing diff first
  if M.diff_open then
    diffview.close()
  end

  -- Close welcome pane to make room for diff
  M.close_welcome()

  if is_binary then
    diffview.open_binary(file)
  elseif kind == 'deleted' then
    diffview.open_deleted(file)
  elseif kind == 'untracked' then
    diffview.open_untracked(file)
  elseif kind == 'added' and file.section ~= 'staged' then
    diffview.open_untracked(file)
  elseif kind == 'conflicted' then
    diffview.open_conflict(file)
  elseif kind == 'copied' then
    diffview.open_copied(file)
  elseif kind == 'type_changed' then
    diffview.open_type_changed(file)
  elseif kind == 'unsupported' then
    diffview.open_placeholder(file)
  else
    diffview.open(file)
  end

  M.diff_open = true
  filetree.highlight_active(file)
  filetree.note_repo_activity()
  M.update_separator_hover()
end

--- Close diff panes and restore the file tree + welcome pane.
function M.close_diff()
  M.diff_open = false
  filetree.highlight_active(nil)

  -- Re-focus and resize the file tree
  if filetree.win and vim.api.nvim_win_is_valid(filetree.win) then
    vim.api.nvim_set_current_win(filetree.win)
    local tree = filetree_options()
    vim.api.nvim_win_set_width(filetree.win, tree.width)
    if tree.winfixwidth ~= nil then
      vim.api.nvim_win_set_option(filetree.win, 'winfixwidth', tree.winfixwidth)
    end
  end

  -- Show welcome pane again
  M.show_welcome()

  -- Refresh the file tree to reflect any changes from editing
  filetree.refresh()
  M.update_separator_hover()
end

return M
