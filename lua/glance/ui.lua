local config = require('glance.config')
local filetree = require('glance.filetree')

local M = {}

-- State
M.diff_open = false
M.welcome_buf = nil
M.welcome_win = nil

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

  local text = 'glance'
  local pad_left = math.max(0, math.floor((width - #text) / 2))
  local pad_top = math.max(0, math.floor(height / 2))

  local lines = {}
  for _ = 1, pad_top do
    table.insert(lines, '')
  end
  table.insert(lines, string.rep(' ', pad_left) .. text)

  vim.api.nvim_buf_set_option(M.welcome_buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.welcome_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.welcome_buf, 'modifiable', false)

  -- Highlight the text
  local ns = vim.api.nvim_create_namespace('glance_welcome')
  vim.api.nvim_buf_clear_namespace(M.welcome_buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(M.welcome_buf, ns, 'Comment', pad_top, pad_left, pad_left + #text)
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

  -- Re-render on resize
  vim.api.nvim_create_autocmd('VimResized', {
    buffer = M.welcome_buf,
    callback = function() vim.schedule(render_welcome) end,
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
