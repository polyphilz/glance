local M = {}
local theme_presets = require('glance.theme_presets')

local VALID_SIGNCOLUMN = {
  no = true,
  yes = true,
  auto = true,
  number = true,
}

local ALLOWED_TOP_LEVEL = {
  app = true,
  theme = true,
  windows = true,
  filetree = true,
  log = true,
  keymaps = true,
  pane_navigation = true,
  hunk_navigation = true,
  signs = true,
  welcome = true,
  minimap = true,
  watch = true,
}

local ALLOWED_APP = {
  hide_statusline = true,
  colorscheme = true,
  termguicolors = true,
  smoothscroll = true,
  mousescroll = true,
  checktime = true,
  autoread = true,
  hidden = true,
}

local ALLOWED_THEME = {
  preset = true,
  palette = true,
}

local ALLOWED_THEME_PALETTE = {
  bg = true,
  fg = true,
  muted = true,
  string = true,
  keyword = true,
  func = true,
  type = true,
  number = true,
  accent = true,
  selection = true,
  line_highlight = true,
  logo = true,
  added = true,
  deleted = true,
  changed = true,
  minimap_bg = true,
  minimap_viewport_bg = true,
  minimap_cursor = true,
  statusline_bg = true,
  split = true,
  split_hover = true,
  deleted_old = true,
  deleted_old_text = true,
  added_new = true,
  added_new_text = true,
  diff_change = true,
  diff_text = true,
  untracked = true,
  line_nr = true,
  folded = true,
}

local ALLOWED_WINDOWS = {
  filetree = true,
  diff = true,
}

local ALLOWED_FILETREE = {
  show_legend = true,
}

local ALLOWED_LOG = {
  max_commits = true,
}

local ALLOWED_FILETREE_WINDOW = {
  width = true,
  number = true,
  relativenumber = true,
  signcolumn = true,
  cursorline = true,
  winfixwidth = true,
}

local ALLOWED_DIFF_WINDOW = {
  number = true,
  relativenumber = true,
  signcolumn = true,
  cursorline = true,
  foldenable = true,
}

local ALLOWED_KEYMAPS = {
  open_file = true,
  quit = true,
  refresh = true,
  next_section = true,
  prev_section = true,
  toggle_filetree = true,
  commit = true,
  log = true,
  stage_file = true,
  stage_all = true,
  unstage_file = true,
  unstage_all = true,
  discard_file = true,
  discard_all = true,
}

local KEYMAP_ORDER = {
  'open_file',
  'quit',
  'refresh',
  'next_section',
  'prev_section',
  'toggle_filetree',
  'commit',
  'log',
  'stage_file',
  'stage_all',
  'unstage_file',
  'unstage_all',
  'discard_file',
  'discard_all',
}

local ALLOWED_PANE_NAVIGATION = {
  left = true,
  down = true,
  up = true,
  right = true,
}

local PANE_NAVIGATION_ORDER = {
  'left',
  'down',
  'up',
  'right',
}

local ALLOWED_HUNK_NAVIGATION = {
  next = true,
  prev = true,
}

local ALLOWED_SIGNS = {
  modified = true,
  added = true,
  deleted = true,
  renamed = true,
  copied = true,
  type_changed = true,
  conflicted = true,
  untracked = true,
}

local ALLOWED_WELCOME = {
  animate = true,
}

local ALLOWED_MINIMAP = {
  enabled = true,
  width = true,
  winblend = true,
  zindex = true,
  debounce_ms = true,
}

local ALLOWED_WATCH = {
  enabled = true,
  poll = true,
  interval_ms = true,
}

local BASE_DEFAULTS = {
  app = {
    hide_statusline = false,
    colorscheme = 'default',
    termguicolors = true,
    smoothscroll = true,
    mousescroll = 'ver:1,hor:1',
    checktime = true,
    autoread = true,
    hidden = false,
  },
  theme = {
    preset = 'seti_black',
    palette = {},
  },
  windows = {
    filetree = {
      width = 30,
      number = false,
      relativenumber = false,
      signcolumn = 'no',
      cursorline = true,
      winfixwidth = true,
    },
    diff = {
      number = true,
      relativenumber = true,
      signcolumn = 'no',
      cursorline = false,
      foldenable = false,
    },
  },
  filetree = {
    show_legend = true,
  },
  log = {
    max_commits = 200,
  },
  keymaps = {
    open_file = '<CR>',
    quit = 'q',
    refresh = 'r',
    next_section = 'J',
    prev_section = 'K',
    toggle_filetree = '<Tab>',
    commit = 'c',
    log = 'L',
    stage_file = 's',
    stage_all = 'S',
    unstage_file = 'u',
    unstage_all = 'U',
    discard_file = 'd',
    discard_all = 'D',
  },
  pane_navigation = {},
  hunk_navigation = {},
  signs = {
    modified = 'M',
    added = 'A',
    deleted = 'D',
    renamed = 'R',
    copied = 'C',
    type_changed = 'T',
    conflicted = 'U',
    untracked = '?',
  },
  welcome = {
    animate = true,
  },
  minimap = {
    enabled = true,
    width = 1,
    winblend = 0,
    zindex = 50,
    debounce_ms = 16,
  },
  watch = {
    enabled = true,
    poll = true,
    interval_ms = 200,
  },
}

local function fail(message)
  error('glance: ' .. message)
end

local function resolve_theme(options)
  local theme = options.theme or {}
  local preset_name = theme.preset

  if type(preset_name) ~= 'string' then
    fail('theme.preset must be a string')
  end

  local preset = theme_presets[preset_name]
  if not preset then
    fail('unknown theme preset ' .. preset_name)
  end

  theme.palette = vim.tbl_deep_extend('force', vim.deepcopy(preset), theme.palette or {})
  return options
end

local function validate_known_keys(tbl, allowed, prefix)
  for key in pairs(tbl) do
    if not allowed[key] then
      fail('unknown config key ' .. prefix .. '.' .. key)
    end
  end
end

local function validate_boolean(value, name)
  if type(value) ~= 'boolean' then
    fail(name .. ' must be a boolean')
  end
end

local function validate_string(value, name)
  if type(value) ~= 'string' then
    fail(name .. ' must be a string')
  end
end

local function validate_hex_color(value, name)
  if type(value) ~= 'string' or not value:match('^#%x%x%x%x%x%x$') then
    fail(name .. ' must be a hex color like #RRGGBB')
  end
end

local function validate_integer(value, name, min_value)
  if type(value) ~= 'number' or value < min_value or value % 1 ~= 0 then
    if min_value == 0 then
      fail(name .. ' must be a non-negative integer')
    else
      fail(name .. ' must be an integer >= ' .. min_value)
    end
  end
end

local function validate_signcolumn(value, name)
  if VALID_SIGNCOLUMN[value] then
    return
  end
  if type(value) == 'string' and value:match('^yes:%d+$') then
    return
  end
  if type(value) == 'string' and value:match('^auto:%d+$') then
    return
  end
  if type(value) == 'string' and value:match('^auto:%d+%-%d+$') then
    return
  end
  fail(name .. ' must be a valid signcolumn value')
end

local function validate_window_options(window_name, options, allowed)
  validate_known_keys(options, allowed, window_name)
  validate_boolean(options.number, window_name .. '.number')
  validate_boolean(options.relativenumber, window_name .. '.relativenumber')
  validate_signcolumn(options.signcolumn, window_name .. '.signcolumn')
  validate_boolean(options.cursorline, window_name .. '.cursorline')
end

local function validate_app(options)
  local app = options.app
  validate_known_keys(app, ALLOWED_APP, 'app')
  validate_boolean(app.hide_statusline, 'app.hide_statusline')
  if app.colorscheme ~= nil then
    validate_string(app.colorscheme, 'app.colorscheme')
  end
  validate_boolean(app.termguicolors, 'app.termguicolors')
  validate_boolean(app.smoothscroll, 'app.smoothscroll')
  validate_string(app.mousescroll, 'app.mousescroll')
  validate_boolean(app.checktime, 'app.checktime')
  validate_boolean(app.autoread, 'app.autoread')
  validate_boolean(app.hidden, 'app.hidden')
end

local function validate_theme(options)
  local theme = options.theme
  validate_known_keys(theme, ALLOWED_THEME, 'theme')
  validate_string(theme.preset, 'theme.preset')
  if not theme_presets[theme.preset] then
    fail('unknown theme preset ' .. theme.preset)
  end
  validate_known_keys(theme.palette, ALLOWED_THEME_PALETTE, 'theme.palette')
  for key, value in pairs(theme.palette) do
    validate_hex_color(value, 'theme.palette.' .. key)
  end
end

local function validate_windows(options)
  local windows = options.windows
  validate_known_keys(windows, ALLOWED_WINDOWS, 'windows')

  local filetree = windows.filetree
  validate_window_options('windows.filetree', filetree, ALLOWED_FILETREE_WINDOW)
  validate_integer(filetree.width, 'windows.filetree.width', 1)
  validate_boolean(filetree.winfixwidth, 'windows.filetree.winfixwidth')

  local diff = windows.diff
  validate_window_options('windows.diff', diff, ALLOWED_DIFF_WINDOW)
  validate_boolean(diff.foldenable, 'windows.diff.foldenable')

end

local function validate_filetree(options)
  local filetree = options.filetree
  validate_known_keys(filetree, ALLOWED_FILETREE, 'filetree')
  validate_boolean(filetree.show_legend, 'filetree.show_legend')
end

local function validate_log(options)
  local log = options.log
  validate_known_keys(log, ALLOWED_LOG, 'log')
  validate_integer(log.max_commits, 'log.max_commits', 1)
end

local function validate_keymaps(options)
  local keymaps = options.keymaps
  local seen = {}

  validate_known_keys(keymaps, ALLOWED_KEYMAPS, 'keymaps')
  for key, value in pairs(keymaps) do
    validate_string(value, 'keymaps.' .. key)
  end

  for _, key in ipairs(KEYMAP_ORDER) do
    local value = keymaps[key]
    if seen[value] then
      fail('keymaps.' .. key .. ' conflicts with keymaps.' .. seen[value])
    end
    seen[value] = key
  end
end

local function validate_pane_navigation(options)
  local pane = options.pane_navigation or {}
  local seen = {}

  validate_known_keys(pane, ALLOWED_PANE_NAVIGATION, 'pane_navigation')

  for _, key in ipairs(PANE_NAVIGATION_ORDER) do
    local value = pane[key]
    if value == nil then
      goto continue
    end

    if type(value) ~= 'string' then
      fail('pane_navigation.' .. key .. ' must be a string or nil')
    end

    if seen[value] then
      fail('pane_navigation.' .. key .. ' conflicts with pane_navigation.' .. seen[value])
    end
    seen[value] = key

    ::continue::
  end

  for direction, lhs in pairs(pane) do
    for key, value in pairs(options.keymaps or {}) do
      if value == lhs then
        fail('pane_navigation.' .. direction .. ' conflicts with keymaps.' .. key)
      end
    end

    for key, value in pairs(options.hunk_navigation or {}) do
      if value == lhs then
        fail('pane_navigation.' .. direction .. ' conflicts with hunk_navigation.' .. key)
      end
    end
  end
end

local function validate_hunk_navigation(options)
  local hunk = options.hunk_navigation or {}
  local next_key = hunk.next
  local prev_key = hunk.prev
  local toggle_key = options.keymaps and options.keymaps.toggle_filetree or nil

  validate_known_keys(hunk, ALLOWED_HUNK_NAVIGATION, 'hunk_navigation')

  if next_key ~= nil and type(next_key) ~= 'string' then
    fail('hunk_navigation.next must be a string or nil')
  end
  if prev_key ~= nil and type(prev_key) ~= 'string' then
    fail('hunk_navigation.prev must be a string or nil')
  end
  if next_key ~= nil and prev_key ~= nil and next_key == prev_key then
    fail('hunk_navigation.next and hunk_navigation.prev must be different')
  end
  if next_key ~= nil and next_key == toggle_key then
    fail('hunk_navigation.next conflicts with keymaps.toggle_filetree')
  end
  if prev_key ~= nil and prev_key == toggle_key then
    fail('hunk_navigation.prev conflicts with keymaps.toggle_filetree')
  end
end

local function validate_signs(options)
  local signs = options.signs
  validate_known_keys(signs, ALLOWED_SIGNS, 'signs')
  for key, value in pairs(signs) do
    validate_string(value, 'signs.' .. key)
  end
end

local function validate_welcome(options)
  local welcome = options.welcome
  validate_known_keys(welcome, ALLOWED_WELCOME, 'welcome')
  validate_boolean(welcome.animate, 'welcome.animate')
end

local function validate_minimap(options)
  local minimap = options.minimap
  validate_known_keys(minimap, ALLOWED_MINIMAP, 'minimap')
  validate_boolean(minimap.enabled, 'minimap.enabled')
  validate_integer(minimap.width, 'minimap.width', 1)
  validate_integer(minimap.winblend, 'minimap.winblend', 0)
  if minimap.winblend > 100 then
    fail('minimap.winblend must be <= 100')
  end
  validate_integer(minimap.zindex, 'minimap.zindex', 1)
  validate_integer(minimap.debounce_ms, 'minimap.debounce_ms', 0)
end

local function validate_watch(options)
  local watch = options.watch
  validate_known_keys(watch, ALLOWED_WATCH, 'watch')
  validate_boolean(watch.enabled, 'watch.enabled')
  validate_boolean(watch.poll, 'watch.poll')
  validate_integer(watch.interval_ms, 'watch.interval_ms', 0)
end

local function validate_options(options)
  validate_known_keys(options, ALLOWED_TOP_LEVEL, 'config')
  validate_app(options)
  validate_theme(options)
  validate_windows(options)
  validate_filetree(options)
  validate_log(options)
  validate_keymaps(options)
  validate_pane_navigation(options)
  validate_hunk_navigation(options)
  validate_signs(options)
  validate_welcome(options)
  validate_minimap(options)
  validate_watch(options)
end

function M.merge(opts)
  local merged = vim.tbl_deep_extend('force', vim.deepcopy(BASE_DEFAULTS), opts or {})
  resolve_theme(merged)
  validate_options(merged)
  return merged
end

M.defaults = M.merge()
M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = M.merge(opts)
end

return M
