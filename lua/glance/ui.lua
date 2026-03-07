local config = require('glance.config')
local filetree = require('glance.filetree')

local M = {}

-- State
M.diff_open = false

--- Initial layout: single full-width file tree buffer.
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
  vim.api.nvim_win_set_option(win, 'winfixwidth', false)
end

--- Open a file based on its type (modified, deleted, untracked/added).
function M.open_file(file)
  local diffview = require('glance.diffview')

  -- Close any existing diff first
  if M.diff_open then
    diffview.close()
  end

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

--- Close diff panes and restore the file tree to full width.
function M.close_diff()
  M.diff_open = false
  filetree.highlight_active(nil)

  -- Re-focus and resize the file tree
  if filetree.win and vim.api.nvim_win_is_valid(filetree.win) then
    vim.api.nvim_set_current_win(filetree.win)
    vim.api.nvim_win_set_option(filetree.win, 'winfixwidth', false)
  end

  -- Refresh the file tree to reflect any changes from editing
  filetree.refresh()
end

return M
