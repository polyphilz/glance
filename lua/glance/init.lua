local M = {}
local APP_AUGROUP = vim.api.nvim_create_augroup('GlanceApp', { clear = true })

function M.setup(opts)
  require('glance.config').setup(opts)
end

local function apply_colorscheme(colorscheme)
  if colorscheme == nil then
    return
  end

  local ok, err = pcall(vim.cmd, 'colorscheme ' .. vim.fn.fnameescape(colorscheme))
  if ok then
    return
  end

  vim.notify('glance: failed to load colorscheme "' .. colorscheme .. '": ' .. err, vim.log.levels.WARN)
  if colorscheme ~= 'default' then
    pcall(vim.cmd, 'colorscheme default')
  end
end

local function enable_system_clipboard_if_available()
  if vim.fn['provider#clipboard#Executable']() == '' then
    return
  end

  vim.opt.clipboard = 'unnamedplus'
end

local function setup_app_autocmds(app, watch_enabled)
  vim.api.nvim_clear_autocmds({ group = APP_AUGROUP })

  if app.checktime then
    local checktime_events = { 'FocusGained', 'BufEnter' }
    if not watch_enabled then
      checktime_events[#checktime_events + 1] = 'CursorHold'
    end

    vim.api.nvim_create_autocmd(checktime_events, {
      group = APP_AUGROUP,
      command = 'silent! checktime',
    })
  end

  if not watch_enabled then
    return
  end

  vim.api.nvim_create_autocmd('FocusGained', {
    group = APP_AUGROUP,
    callback = function()
      local filetree = package.loaded['glance.filetree']
      if not filetree or not filetree.buf or not vim.api.nvim_buf_is_valid(filetree.buf) then
        return
      end

      filetree.schedule_repo_refresh({
        source = 'focus',
        reset_poll = true,
        resync_watchers = true,
      })
    end,
  })
end

function M.start()
  local config = require('glance.config')
  local git = require('glance.git')
  local ui = require('glance.ui')
  local filetree = require('glance.filetree')
  local app = config.options.app
  local repo_poll_enabled = config.options.watch.enabled and config.options.watch.poll
  local repo_fs_watch_enabled = config.options.watch.enabled
  local watch_enabled = repo_poll_enabled or repo_fs_watch_enabled

  -- Verify we're in a git repo
  if not git.is_repo() then
    vim.notify('glance: not a git repository', vim.log.levels.ERROR)
    vim.cmd('qa!')
    return
  end

  -- Set up essential app-owned options
  vim.opt.termguicolors = app.termguicolors
  vim.opt.autoread = app.autoread
  vim.opt.hidden = app.hidden
  vim.opt.smoothscroll = app.smoothscroll
  vim.opt.mousescroll = app.mousescroll
  enable_system_clipboard_if_available()
  if app.hide_statusline then
    vim.opt.laststatus = 0
  end

  -- Auto-detect external file changes (e.g. edits from Cursor/VS Code)
  setup_app_autocmds(app, watch_enabled)
  apply_colorscheme(app.colorscheme)

  -- Apply highlights AFTER colorscheme so they aren't overwritten
  M.setup_highlights()

  -- Try to load tree-sitter runtime paths for syntax highlighting
  M.setup_treesitter()

  -- Gather changed files
  local snapshot = git.get_status_snapshot()
  local files = snapshot.files

  -- Set up the UI and render file tree
  ui.setup_layout()
  filetree.apply_status_snapshot(snapshot)
  if watch_enabled then
    filetree.start_repo_watch()
  end
end

local function hex_to_rgb(hex)
  if type(hex) ~= 'string' then
    return nil
  end

  local value = hex:gsub('#', '')
  if #value ~= 6 then
    return nil
  end

  return tonumber(value:sub(1, 2), 16), tonumber(value:sub(3, 4), 16), tonumber(value:sub(5, 6), 16)
end

local function blend_hex(base_hex, tint_hex, alpha)
  local base_r, base_g, base_b = hex_to_rgb(base_hex)
  local tint_r, tint_g, tint_b = hex_to_rgb(tint_hex)
  if not base_r or not tint_r then
    return base_hex
  end

  local function mix(base, tint)
    return math.floor((base * (1 - alpha)) + (tint * alpha) + 0.5)
  end

  return string.format('#%02X%02X%02X', mix(base_r, tint_r), mix(base_g, tint_g), mix(base_b, tint_b))
end

function M.setup_highlights()
  local palette = require('glance.config').options.theme.palette
  local bg = palette.bg
  local fg = palette.fg
  local comment = palette.muted
  local string = palette.string
  local keyword = palette.keyword
  local func = palette.func
  local type_color = palette.type
  local manual_color = palette.manual or palette.number or palette.keyword
  local number = palette.number
  local param = palette.accent
  local selection = palette.selection
  local line_hl = palette.line_highlight
  local merge_unresolved_bg = blend_hex(bg, palette.changed, 0.2)
  local merge_handled_bg = blend_hex(bg, palette.added, 0.16)
  local merge_manual_bg = blend_hex(bg, manual_color, 0.18)

  -- Editor
  vim.api.nvim_set_hl(0, 'Normal', { bg = bg, fg = fg })
  vim.api.nvim_set_hl(0, 'NormalNC', { bg = bg, fg = fg })
  vim.api.nvim_set_hl(0, 'NormalFloat', { bg = bg, fg = fg })
  vim.api.nvim_set_hl(0, 'CursorLine', { bg = line_hl })
  vim.api.nvim_set_hl(0, 'Visual', { bg = selection })
  vim.api.nvim_set_hl(0, 'LineNr', { fg = palette.line_nr, bg = bg })
  vim.api.nvim_set_hl(0, 'CursorLineNr', { fg = param, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, 'SignColumn', { bg = bg })
  vim.api.nvim_set_hl(0, 'VertSplit', { fg = palette.split, bg = bg })
  vim.api.nvim_set_hl(0, 'WinSeparator', { fg = palette.split, bg = bg })
  vim.api.nvim_set_hl(0, 'GlanceSeparatorHover', { fg = palette.split_hover, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, 'StatusLine', { fg = fg, bg = palette.statusline_bg })
  vim.api.nvim_set_hl(0, 'StatusLineNC', { fg = comment, bg = palette.statusline_bg })
  vim.api.nvim_set_hl(0, 'EndOfBuffer', { fg = bg, bg = bg })
  vim.api.nvim_set_hl(0, 'Folded', { fg = comment, bg = palette.folded })
  vim.api.nvim_set_hl(0, 'FoldColumn', { fg = comment, bg = bg })

  -- Syntax (vim's built-in highlight groups, used by tree-sitter too)
  vim.api.nvim_set_hl(0, 'Comment', { fg = comment, italic = true })
  vim.api.nvim_set_hl(0, 'String', { fg = string })
  vim.api.nvim_set_hl(0, 'Keyword', { fg = keyword })
  vim.api.nvim_set_hl(0, 'Conditional', { fg = keyword })
  vim.api.nvim_set_hl(0, 'Repeat', { fg = keyword })
  vim.api.nvim_set_hl(0, 'Statement', { fg = keyword })
  vim.api.nvim_set_hl(0, 'Function', { fg = func })
  vim.api.nvim_set_hl(0, 'Identifier', { fg = fg })
  vim.api.nvim_set_hl(0, 'Type', { fg = type_color, italic = true })
  vim.api.nvim_set_hl(0, 'Number', { fg = number })
  vim.api.nvim_set_hl(0, 'Float', { fg = number })
  vim.api.nvim_set_hl(0, 'Boolean', { fg = number })
  vim.api.nvim_set_hl(0, 'Constant', { fg = number })
  vim.api.nvim_set_hl(0, 'Operator', { fg = keyword })
  vim.api.nvim_set_hl(0, 'PreProc', { fg = keyword })
  vim.api.nvim_set_hl(0, 'Include', { fg = keyword })
  vim.api.nvim_set_hl(0, 'Special', { fg = param })
  vim.api.nvim_set_hl(0, 'Tag', { fg = keyword })
  vim.api.nvim_set_hl(0, 'Delimiter', { fg = fg })
  vim.api.nvim_set_hl(0, 'Title', { fg = func, bold = true })
  vim.api.nvim_set_hl(0, 'gitcommitSummary', { fg = keyword })
  vim.api.nvim_set_hl(0, 'gitcommitOverflow', { fg = keyword })
  vim.api.nvim_set_hl(0, 'gitcommitBlank', { fg = fg })

  -- Tree-sitter highlight groups
  vim.api.nvim_set_hl(0, '@comment', { fg = comment, italic = true })
  vim.api.nvim_set_hl(0, '@string', { fg = string })
  vim.api.nvim_set_hl(0, '@keyword', { fg = keyword })
  vim.api.nvim_set_hl(0, '@keyword.function', { fg = keyword })
  vim.api.nvim_set_hl(0, '@keyword.return', { fg = keyword })
  vim.api.nvim_set_hl(0, '@keyword.import', { fg = keyword })
  vim.api.nvim_set_hl(0, '@function', { fg = func })
  vim.api.nvim_set_hl(0, '@function.call', { fg = func })
  vim.api.nvim_set_hl(0, '@method', { fg = func })
  vim.api.nvim_set_hl(0, '@method.call', { fg = func })
  vim.api.nvim_set_hl(0, '@constructor', { fg = func })
  vim.api.nvim_set_hl(0, '@type', { fg = type_color, italic = true })
  vim.api.nvim_set_hl(0, '@type.builtin', { fg = type_color, italic = true })
  vim.api.nvim_set_hl(0, '@variable', { fg = fg })
  vim.api.nvim_set_hl(0, '@variable.builtin', { fg = param })
  vim.api.nvim_set_hl(0, '@parameter', { fg = param, italic = true })
  vim.api.nvim_set_hl(0, '@property', { fg = fg })
  vim.api.nvim_set_hl(0, '@number', { fg = number })
  vim.api.nvim_set_hl(0, '@boolean', { fg = number })
  vim.api.nvim_set_hl(0, '@operator', { fg = keyword })
  vim.api.nvim_set_hl(0, '@punctuation', { fg = fg })
  vim.api.nvim_set_hl(0, '@constant', { fg = number })
  vim.api.nvim_set_hl(0, '@tag', { fg = keyword })
  vim.api.nvim_set_hl(0, '@tag.attribute', { fg = func })

  -- Diff highlights
  vim.api.nvim_set_hl(0, 'DiffAdd', { bg = palette.added_new })
  vim.api.nvim_set_hl(0, 'DiffDelete', { bg = palette.deleted_old })
  vim.api.nvim_set_hl(0, 'DiffChange', { bg = palette.diff_change })
  vim.api.nvim_set_hl(0, 'DiffText', { bg = palette.diff_text, bold = true })

  -- Per-pane diff highlights (old=red, new=green) applied via winhighlight
  vim.api.nvim_set_hl(0, 'GlanceDiffChangeOld', { bg = palette.deleted_old })
  vim.api.nvim_set_hl(0, 'GlanceDiffTextOld', { bg = palette.deleted_old_text, bold = true })
  vim.api.nvim_set_hl(0, 'GlanceDiffChangeNew', { bg = palette.added_new })
  vim.api.nvim_set_hl(0, 'GlanceDiffTextNew', { bg = palette.added_new_text, bold = true })

  -- File tree highlights
  vim.api.nvim_set_hl(0, 'GlanceSectionHeader', { bold = true, fg = comment })
  vim.api.nvim_set_hl(0, 'GlanceStatusM', { fg = string })
  vim.api.nvim_set_hl(0, 'GlanceStatusA', { fg = func })
  vim.api.nvim_set_hl(0, 'GlanceStatusD', { fg = keyword })
  vim.api.nvim_set_hl(0, 'GlanceStatusR', { fg = type_color })
  vim.api.nvim_set_hl(0, 'GlanceStatusC', { fg = type_color })
  vim.api.nvim_set_hl(0, 'GlanceStatusT', { fg = palette.changed })
  vim.api.nvim_set_hl(0, 'GlanceStatusConflict', { fg = keyword })
  vim.api.nvim_set_hl(0, 'GlanceStatusU', { fg = palette.untracked })
  vim.api.nvim_set_hl(0, 'GlanceActiveFile', { bg = selection })
  vim.api.nvim_set_hl(0, 'GlanceLegendTitle', { fg = comment, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, 'GlanceLegendBracket', { fg = palette.split, bg = bg })
  vim.api.nvim_set_hl(0, 'GlanceLegendKey', { fg = param, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, 'GlanceAccentText', { fg = param, bold = true })
  vim.api.nvim_set_hl(0, 'GlanceLegendText', { fg = comment, bg = bg })
  vim.api.nvim_set_hl(0, 'GlanceLegendHint', { fg = palette.accent, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, 'GlanceConflictMarkerUnresolved', { fg = palette.changed, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, 'GlanceConflictMarkerHandled', { fg = palette.added, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, 'GlanceConflictMarkerManual', { fg = manual_color, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, 'GlanceConflictStateUnresolved', { bg = merge_unresolved_bg })
  vim.api.nvim_set_hl(0, 'GlanceConflictStateHandled', { bg = merge_handled_bg })
  vim.api.nvim_set_hl(0, 'GlanceConflictStateManual', { bg = merge_manual_bg })
  vim.api.nvim_set_hl(0, 'GlanceConflictActiveNumber', { fg = palette.split_hover, bg = bg, bold = true })

  -- Minimap highlights
  require('glance.minimap').setup_highlights()
  require('glance.ui').setup_welcome_highlights({
    base = comment,
    bright = fg,
    logo = palette.logo,
  })
end

function M.setup_treesitter()
  -- Try to add common tree-sitter parser paths so syntax highlighting works in --clean mode
  -- Add paths where tree-sitter parsers are typically installed
  local data_dir = vim.fn.stdpath('data')
  local rtp_dirs = {
    -- lazy.nvim managed tree-sitter
    data_dir .. '/lazy/nvim-treesitter',
    -- packer / manual installs
    data_dir .. '/site/pack/*/start/nvim-treesitter',
  }
  for _, pattern in ipairs(rtp_dirs) do
    local expanded = vim.fn.glob(pattern)
    if expanded ~= '' then
      for dir in expanded:gmatch('[^\n]+') do
        vim.opt.runtimepath:append(dir)
      end
    end
  end

  -- In --clean mode, plugin/ files aren't sourced, so nvim-treesitter's
  -- filetype-to-language registrations (e.g. typescriptreact -> tsx) don't
  -- happen automatically. Requiring parsers triggers those register() calls.
  pcall(require, 'nvim-treesitter.parsers')
end

return M
