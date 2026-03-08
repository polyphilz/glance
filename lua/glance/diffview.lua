local git = require('glance.git')
local config = require('glance.config')
local filetree = require('glance.filetree')

local M = {}

-- State
M.old_buf = nil
M.old_win = nil
M.new_buf = nil
M.new_win = nil
M.fs_watcher = nil
M.closing = false
M.autocmd_group = vim.api.nvim_create_augroup('GlanceDiffView', { clear = true })

--- Open a standard 2-pane side-by-side diff for a modified file.
function M.open(file)
  local root = git.repo_root()
  if not root then return end

  -- Determine the ref for the old content
  local old_ref
  if file.section == 'staged' then
    old_ref = 'HEAD'
  else
    old_ref = ':' -- index
  end

  -- For staged renames, the old content lives at old_path in HEAD.
  -- For changes, the index already has the file at the new path.
  local old_content_path = file.path
  if file.section == 'staged' and file.old_path then
    old_content_path = file.old_path
  end
  local old_lines = git.get_file_content(old_content_path, old_ref)

  -- Resize file tree
  vim.api.nvim_win_set_width(filetree.win, config.options.filetree_width)
  vim.api.nvim_win_set_option(filetree.win, 'winfixwidth', true)

  -- Create the old (left) pane: vertical split to the right of file tree
  vim.api.nvim_set_current_win(filetree.win)
  vim.cmd('rightbelow vnew')
  M.old_win = vim.api.nvim_get_current_win()
  local scratch_buf = vim.api.nvim_get_current_buf()
  M.set_win_options(M.old_win)

  -- Set up old buffer: write to temp file with correct extension so
  -- syntax highlighting works identically to the right pane via edit
  local ext = vim.fn.fnamemodify(file.path, ':e')
  local tmpfile = vim.fn.tempname() .. '.' .. ext
  local f = io.open(tmpfile, 'w')
  if f then
    f:write(table.concat(old_lines, '\n'))
    f:close()
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(tmpfile))
  M.old_buf = vim.api.nvim_get_current_buf()
  vim.fn.delete(tmpfile)
  -- Clean up the scratch buffer vnew created
  if vim.api.nvim_buf_is_valid(scratch_buf) and scratch_buf ~= M.old_buf then
    vim.api.nvim_buf_delete(scratch_buf, { force = true })
  end
  -- Make it read-only and non-saveable
  vim.api.nvim_buf_set_option(M.old_buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(M.old_buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(M.old_buf, 'readonly', true)
  vim.api.nvim_buf_set_option(M.old_buf, 'swapfile', false)

  -- Create the new (right) pane: vertical split to the right of old pane
  vim.cmd('rightbelow vnew')
  M.new_win = vim.api.nvim_get_current_win()
  M.set_win_options(M.new_win)

  -- Open the actual file on disk (editable)
  local full_path = root .. '/' .. file.path
  if file.section == 'staged' then
    -- For staged files, show the index version via temp file (for syntax highlighting)
    local index_lines = git.get_file_content(file.path, ':')
    local new_scratch = vim.api.nvim_get_current_buf()
    local new_ext = vim.fn.fnamemodify(file.path, ':e')
    local new_tmpfile = vim.fn.tempname() .. '.' .. new_ext
    local nf = io.open(new_tmpfile, 'w')
    if nf then
      nf:write(table.concat(index_lines, '\n'))
      nf:close()
    end
    vim.cmd('edit ' .. vim.fn.fnameescape(new_tmpfile))
    M.new_buf = vim.api.nvim_get_current_buf()
    vim.fn.delete(new_tmpfile)
    if vim.api.nvim_buf_is_valid(new_scratch) and new_scratch ~= M.new_buf then
      vim.api.nvim_buf_delete(new_scratch, { force = true })
    end
    vim.api.nvim_buf_set_option(M.new_buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(M.new_buf, 'modifiable', false)
    vim.api.nvim_buf_set_option(M.new_buf, 'readonly', true)
    vim.api.nvim_buf_set_option(M.new_buf, 'swapfile', false)
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(full_path))
    M.new_buf = vim.api.nvim_get_current_buf()
  end

  -- Enable diff mode on both panes
  vim.api.nvim_set_current_win(M.old_win)
  vim.cmd('diffthis')
  vim.api.nvim_set_current_win(M.new_win)
  vim.cmd('diffthis')

  -- Disable diff folding (must be after diffthis which forces foldenable=true)
  vim.api.nvim_win_set_option(M.old_win, 'foldenable', false)
  vim.api.nvim_win_set_option(M.new_win, 'foldenable', false)

  -- Per-pane diff colors: old=red tones, new=green tones (like VS Code/Cursor)
  vim.api.nvim_win_set_option(M.old_win, 'winhighlight',
    'DiffChange:GlanceDiffChangeOld,DiffText:GlanceDiffTextOld')
  vim.api.nvim_win_set_option(M.new_win, 'winhighlight',
    'DiffChange:GlanceDiffChangeNew,DiffText:GlanceDiffTextNew')

  -- Explicitly size all panes: file tree fixed, diff panes split the rest
  M.equalize_panes()

  -- Focus the new (right) pane
  vim.api.nvim_set_current_win(M.new_win)

  -- Watch for external changes to the file
  if file.section ~= 'staged' then
    M.watch_file(full_path)
  end

  -- Set up autocmds and keymaps
  M.setup_autocmds(file)
  M.bind_toggle_keymap()

  -- Open diff minimap on the new (right) pane
  local minimap = require('glance.minimap')
  minimap.open(M.new_win, old_lines)
end

--- Open a single read-only pane for a deleted file.
function M.open_deleted(file)
  local old_ref
  if file.section == 'staged' then
    old_ref = 'HEAD'
  else
    old_ref = ':'
  end

  local lines = git.get_file_content(file.path, old_ref)

  -- Resize file tree
  vim.api.nvim_win_set_width(filetree.win, config.options.filetree_width)
  vim.api.nvim_win_set_option(filetree.win, 'winfixwidth', true)

  -- Create a single pane
  vim.api.nvim_set_current_win(filetree.win)
  vim.cmd('rightbelow vnew')
  M.new_win = vim.api.nvim_get_current_win()
  M.new_buf = vim.api.nvim_get_current_buf()
  M.set_win_options(M.new_win)

  local buf_name = 'glance://deleted/' .. file.path
  pcall(vim.api.nvim_buf_set_name, M.new_buf, buf_name)
  vim.api.nvim_buf_set_lines(M.new_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.new_buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(M.new_buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(M.new_buf, 'readonly', true)
  vim.api.nvim_buf_set_option(M.new_buf, 'swapfile', false)
  M.set_filetype_from_path(M.new_buf, file.path)

  -- Highlight all lines as deleted
  local ns = vim.api.nvim_create_namespace('glance_deleted')
  for i = 0, #lines - 1 do
    vim.api.nvim_buf_add_highlight(M.new_buf, ns, 'DiffDelete', i, 0, -1)
  end

  M.equalize_panes()
  M.setup_autocmds(file)
  M.bind_toggle_keymap()
end

--- Open a single editable pane for an untracked file.
function M.open_untracked(file)
  local root = git.repo_root()
  if not root then return end

  -- Resize file tree
  vim.api.nvim_win_set_width(filetree.win, config.options.filetree_width)
  vim.api.nvim_win_set_option(filetree.win, 'winfixwidth', true)

  -- Create a single pane and open the file
  vim.api.nvim_set_current_win(filetree.win)
  vim.cmd('rightbelow vnew')
  M.new_win = vim.api.nvim_get_current_win()
  M.set_win_options(M.new_win)

  local full_path = root .. '/' .. file.path
  vim.cmd('edit ' .. vim.fn.fnameescape(full_path))
  M.new_buf = vim.api.nvim_get_current_buf()

  M.equalize_panes()
  M.setup_autocmds(file)
  M.bind_toggle_keymap()
end

--- Watch a file on disk for external changes and reload the buffer instantly.
function M.watch_file(path)
  M.stop_watching()
  local w = vim.uv.new_fs_poll()
  if not w then return end
  M.fs_watcher = w
  w:start(path, 200, function(err)
    if err then return end
    vim.schedule(function()
      if M.new_buf and vim.api.nvim_buf_is_valid(M.new_buf) then
        vim.api.nvim_buf_call(M.new_buf, function()
          vim.cmd('silent! edit!')
        end)
        vim.cmd('silent! diffupdate')
      end
    end)
  end)
end

--- Stop watching the current file.
function M.stop_watching()
  if M.fs_watcher then
    M.fs_watcher:stop()
    M.fs_watcher:close()
    M.fs_watcher = nil
  end
end

--- Bind toggle filetree keymap on diff buffers.
function M.bind_toggle_keymap()
  local km = config.options.keymaps
  local bufs = {}
  if M.old_buf and vim.api.nvim_buf_is_valid(M.old_buf) then
    table.insert(bufs, M.old_buf)
  end
  if M.new_buf and vim.api.nvim_buf_is_valid(M.new_buf) then
    table.insert(bufs, M.new_buf)
  end
  for _, buf in ipairs(bufs) do
    vim.keymap.set('n', km.toggle_filetree, function() filetree.toggle() end,
      { noremap = true, silent = true, buffer = buf })
  end
end

--- Set up autocmds for managing diff view lifecycle.
function M.setup_autocmds(file)
  vim.api.nvim_clear_autocmds({ group = M.autocmd_group })

  -- Track which windows belong to the diff view
  local diff_wins = {}
  if M.old_win then table.insert(diff_wins, M.old_win) end
  if M.new_win then table.insert(diff_wins, M.new_win) end

  -- When any diff window is closed, close them all and return to file tree
  vim.api.nvim_create_autocmd('WinClosed', {
    group = M.autocmd_group,
    callback = function(args)
      local closed_win = tonumber(args.match)
      local is_diff_win = false
      for _, w in ipairs(diff_wins) do
        if w == closed_win then
          is_diff_win = true
          break
        end
      end

      if is_diff_win and not M.closing then
        M.close()
      end
    end,
  })

  -- When the new buffer is saved, refresh the diff
  if M.new_buf and vim.api.nvim_buf_get_option(M.new_buf, 'buftype') == '' then
    vim.api.nvim_create_autocmd('BufWritePost', {
      group = M.autocmd_group,
      buffer = M.new_buf,
      callback = function()
        vim.schedule(function()
          M.refresh(file)
        end)
      end,
    })
  end
end

--- Clean up diff windows and buffers, return to file tree.
--- @param force boolean|nil  If true, discard unsaved changes. Otherwise prompt.
function M.close(force)
  if M.closing then
    return
  end
  M.closing = true
  local discard_new_changes = force == true

  -- Check for unsaved changes in the new (editable) buffer before closing
  if not force
    and M.new_buf and vim.api.nvim_buf_is_valid(M.new_buf)
    and vim.api.nvim_buf_get_option(M.new_buf, 'buftype') == ''
    and vim.api.nvim_buf_get_option(M.new_buf, 'modified')
  then
    -- Focus the new pane so the user sees the modified buffer
    if M.new_win and vim.api.nvim_win_is_valid(M.new_win) then
      vim.api.nvim_set_current_win(M.new_win)
    end
    local choice = vim.fn.confirm(
      'Save changes?',
      '&Yes\n&No\n&Cancel', 3
    )
    if choice == 1 then
      vim.api.nvim_buf_call(M.new_buf, function() vim.cmd('write') end)
    elseif choice == 3 or choice == 0 then
      M.closing = false
      return -- abort close
    else
      discard_new_changes = true
    end
    -- choice == 2: discard changes, continue closing
  end

  local old_lazyredraw = vim.o.lazyredraw
  local ok, err = xpcall(function()
    -- Suppress redraws during close to prevent filetree flash
    vim.o.lazyredraw = true

    -- Close minimap first (before closing diff windows)
    local minimap = require('glance.minimap')
    minimap.close()

    M.stop_watching()
    vim.api.nvim_clear_autocmds({ group = M.autocmd_group })

    -- Turn off diff mode in any remaining diff windows
    local function safe_diffoff(win)
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        vim.cmd('diffoff')
      end
    end
    safe_diffoff(M.old_win)
    safe_diffoff(M.new_win)

    -- Restore filetree window before closing diff panes, so we never
    -- try to close the last window (E444)
    if not filetree.win or not vim.api.nvim_win_is_valid(filetree.win) then
      vim.cmd('topleft vnew')
      local new_win = vim.api.nvim_get_current_win()
      local scratch_buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_win_set_buf(new_win, filetree.buf)
      if vim.api.nvim_buf_is_valid(scratch_buf) and scratch_buf ~= filetree.buf then
        vim.api.nvim_buf_delete(scratch_buf, { force = true })
      end
      filetree.win = new_win
    end

    -- Close old pane window and buffer
    if M.old_win and vim.api.nvim_win_is_valid(M.old_win) then
      vim.api.nvim_win_close(M.old_win, true)
    end
    if M.old_buf and vim.api.nvim_buf_is_valid(M.old_buf) then
      vim.api.nvim_buf_delete(M.old_buf, { force = true })
    end

    -- Close the editable pane window, then clean up the backing buffer if Glance
    -- is the last owner. This prevents hidden modified buffers from being reused.
    if M.new_win and vim.api.nvim_win_is_valid(M.new_win) then
      vim.api.nvim_win_close(M.new_win, true)
    end
    if M.new_buf and vim.api.nvim_buf_is_valid(M.new_buf) then
      local buftype = vim.api.nvim_buf_get_option(M.new_buf, 'buftype')
      local visible_elsewhere = vim.fn.bufwinid(M.new_buf) ~= -1
      if buftype == 'nofile' or not visible_elsewhere then
        vim.api.nvim_buf_delete(M.new_buf, {
          force = discard_new_changes or buftype == 'nofile',
        })
      end
    end

    M.old_buf = nil
    M.old_win = nil
    M.new_buf = nil
    M.new_win = nil

    -- Return to file tree
    local ui = require('glance.ui')
    ui.close_diff()
  end, debug.traceback)

  vim.o.lazyredraw = old_lazyredraw
  M.closing = false
  if not ok then
    error(err)
  end
  vim.cmd('redraw')
end

--- Refresh the diff after a save (re-read old content, update diff).
function M.refresh(file)
  if not M.old_buf or not vim.api.nvim_buf_is_valid(M.old_buf) then
    return
  end
  if not M.old_win or not vim.api.nvim_win_is_valid(M.old_win) then
    return
  end

  -- Re-read old content from git
  local old_ref = file.section == 'staged' and 'HEAD' or ':'
  local old_lines = git.get_file_content(file.path, old_ref)

  -- Update old buffer
  local old_readonly = vim.api.nvim_buf_get_option(M.old_buf, 'readonly')
  vim.api.nvim_buf_set_option(M.old_buf, 'readonly', false)
  vim.api.nvim_buf_set_option(M.old_buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.old_buf, 0, -1, false, old_lines)
  vim.api.nvim_buf_set_option(M.old_buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(M.old_buf, 'readonly', old_readonly)

  -- Refresh diff
  vim.cmd('diffupdate')

  -- Refresh minimap with new old_lines
  local minimap = require('glance.minimap')
  minimap.old_lines = old_lines
  minimap.full_update()
end

--- Explicitly size panes: file tree gets its fixed width, diff panes split the rest.
function M.equalize_panes()
  local tree_visible = filetree.win and vim.api.nvim_win_is_valid(filetree.win)
  local tree_width = 0

  if tree_visible then
    tree_width = config.options.filetree_width
    vim.api.nvim_win_set_width(filetree.win, tree_width)
  end

  -- Count separators: 1 if tree visible, plus 1 if two diff panes
  local separators = (tree_visible and 1 or 0)

  if M.old_win and vim.api.nvim_win_is_valid(M.old_win) and
     M.new_win and vim.api.nvim_win_is_valid(M.new_win) then
    -- Two diff panes: split remaining space evenly
    separators = separators + 1
    local remaining = vim.o.columns - tree_width - separators
    vim.api.nvim_win_set_width(M.old_win, math.floor(remaining / 2))
  end
end

--- Apply standard window options to a diff pane (line numbers, etc).
function M.set_win_options(win)
  vim.api.nvim_win_set_option(win, 'number', true)
  vim.api.nvim_win_set_option(win, 'relativenumber', true)
  vim.api.nvim_win_set_option(win, 'signcolumn', 'no')
  vim.api.nvim_win_set_option(win, 'cursorline', false)
end

--- Set the filetype of a buffer based on the file extension for syntax highlighting.
--- Also explicitly starts tree-sitter, which doesn't auto-attach to nofile buffers.
function M.set_filetype_from_path(buf, path)
  local ft = vim.filetype.match({ filename = path })
  if ft then
    vim.api.nvim_buf_set_option(buf, 'filetype', ft)
    -- Don't pass ft as lang; let treesitter resolve via get_lang()
    -- which handles filetype != parser name (e.g. typescriptreact -> tsx)
    pcall(vim.treesitter.start, buf)
  end
end

return M
