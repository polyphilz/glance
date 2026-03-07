local M = {}

function M.setup(opts)
  require('glance.config').setup(opts)
end

function M.start()
  local git = require('glance.git')
  local ui = require('glance.ui')
  local filetree = require('glance.filetree')

  -- Verify we're in a git repo
  if not git.is_repo() then
    vim.notify('glance: not a git repository', vim.log.levels.ERROR)
    vim.cmd('qa!')
    return
  end

  -- Set up essential options
  vim.opt.termguicolors = true
  vim.opt.number = true
  vim.opt.relativenumber = true
  vim.opt.signcolumn = 'yes'
  vim.opt.autoread = true

  -- Auto-detect external file changes (e.g. edits from Cursor/VS Code)
  vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold' }, {
    command = 'silent! checktime',
  })
  vim.cmd('colorscheme default')

  -- Apply highlights AFTER colorscheme so they aren't overwritten
  M.setup_highlights()

  -- Try to load tree-sitter runtime paths for syntax highlighting
  M.setup_treesitter()

  -- Gather changed files
  local files = git.get_changed_files()

  -- Check for empty state
  local total = #files.staged + #files.changes + #files.untracked
  if total == 0 then
    vim.notify('glance: no changes found', vim.log.levels.INFO)
    vim.cmd('qa!')
    return
  end

  -- Set up the UI and render file tree
  ui.setup_layout()
  filetree.render(files)
end

function M.setup_highlights()
  -- Seti Black palette
  local bg = '#000000'
  local fg = '#D7D7D7'
  local comment = '#677A83'
  local string = '#E6DB74'
  local keyword = '#F92672'
  local func = '#A6E22E'
  local type_color = '#66D9EF'
  local number = '#AE81FF'
  local param = '#FD971F'
  local selection = '#444444'
  local line_hl = '#333333'

  -- Editor
  vim.api.nvim_set_hl(0, 'Normal', { bg = bg, fg = fg })
  vim.api.nvim_set_hl(0, 'NormalNC', { bg = bg, fg = fg })
  vim.api.nvim_set_hl(0, 'CursorLine', { bg = line_hl })
  vim.api.nvim_set_hl(0, 'Visual', { bg = selection })
  vim.api.nvim_set_hl(0, 'LineNr', { fg = '#555555', bg = bg })
  vim.api.nvim_set_hl(0, 'CursorLineNr', { fg = param, bg = bg, bold = true })
  vim.api.nvim_set_hl(0, 'SignColumn', { bg = bg })
  vim.api.nvim_set_hl(0, 'VertSplit', { fg = '#333333', bg = bg })
  vim.api.nvim_set_hl(0, 'WinSeparator', { fg = '#333333', bg = bg })
  vim.api.nvim_set_hl(0, 'StatusLine', { fg = fg, bg = '#101010' })
  vim.api.nvim_set_hl(0, 'StatusLineNC', { fg = comment, bg = '#101010' })
  vim.api.nvim_set_hl(0, 'EndOfBuffer', { fg = bg, bg = bg })
  vim.api.nvim_set_hl(0, 'Folded', { fg = comment, bg = '#1a1a1a' })
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
  vim.api.nvim_set_hl(0, 'DiffAdd', { bg = '#1a3d1a' })     -- added lines: green
  vim.api.nvim_set_hl(0, 'DiffDelete', { bg = '#3d1a1a' })   -- deleted lines: red
  vim.api.nvim_set_hl(0, 'DiffChange', { bg = '#2b2b00' })   -- changed lines: dim yellow
  vim.api.nvim_set_hl(0, 'DiffText', { bg = '#4a4a00', bold = true }) -- changed text: bright yellow

  -- File tree highlights
  vim.api.nvim_set_hl(0, 'GlanceSectionHeader', { bold = true, fg = comment })
  vim.api.nvim_set_hl(0, 'GlanceStatusM', { fg = string })
  vim.api.nvim_set_hl(0, 'GlanceStatusA', { fg = func })
  vim.api.nvim_set_hl(0, 'GlanceStatusD', { fg = keyword })
  vim.api.nvim_set_hl(0, 'GlanceStatusR', { fg = type_color })
  vim.api.nvim_set_hl(0, 'GlanceStatusU', { fg = '#808080' })
  vim.api.nvim_set_hl(0, 'GlanceActiveFile', { bg = selection })
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
end

return M
