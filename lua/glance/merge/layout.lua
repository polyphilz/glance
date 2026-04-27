local filetree = require('glance.filetree')
local workspace = require('glance.workspace')

local M = {}

M.FILETREE_ROLE = 'filetree'
M.THEIRS_ROLE = 'merge_theirs'
M.OURS_ROLE = 'merge_ours'
M.RESULT_ROLE = 'merge_result'
M.SPECIAL_ROLE = 'merge_special'

function M.workspace_spec()
  return {
    roles = {
      { role = M.FILETREE_ROLE, kind = 'sidebar' },
      { role = M.THEIRS_ROLE, kind = 'content' },
      { role = M.OURS_ROLE, kind = 'content' },
      { role = M.RESULT_ROLE, kind = 'content' },
    },
    preferred_focus_role = M.RESULT_ROLE,
    editable_role = M.RESULT_ROLE,
  }
end

function M.open(diffview)
  diffview.configure_workspace(M.workspace_spec())

  local result_win, result_buf = diffview.open_workspace_pane(M.RESULT_ROLE)

  vim.cmd('leftabove new')
  local theirs_win = vim.api.nvim_get_current_win()
  local theirs_buf = vim.api.nvim_get_current_buf()
  workspace.set_pane(diffview.workspace, M.THEIRS_ROLE, {
    win = theirs_win,
    buf = theirs_buf,
  })
  diffview.set_win_options(theirs_win)

  vim.cmd('rightbelow vnew')
  local ours_win = vim.api.nvim_get_current_win()
  local ours_buf = vim.api.nvim_get_current_buf()
  workspace.set_pane(diffview.workspace, M.OURS_ROLE, {
    win = ours_win,
    buf = ours_buf,
  })
  diffview.set_win_options(ours_win)

  return {
    result = { win = result_win, buf = result_buf },
    theirs = { win = theirs_win, buf = theirs_buf },
    ours = { win = ours_win, buf = ours_buf },
  }
end

function M.special_workspace_spec()
  return {
    roles = {
      { role = M.FILETREE_ROLE, kind = 'sidebar' },
      { role = M.SPECIAL_ROLE, kind = 'content' },
    },
    preferred_focus_role = M.SPECIAL_ROLE,
    editable_role = M.SPECIAL_ROLE,
  }
end

function M.open_special(diffview)
  diffview.configure_workspace(M.special_workspace_spec())
  local win, buf = diffview.open_workspace_pane(M.SPECIAL_ROLE)
  return {
    special = { win = win, buf = buf },
  }
end

function M.equalize_special(diffview)
  local tree_visible = filetree.win and vim.api.nvim_win_is_valid(filetree.win)
  if tree_visible then
    vim.api.nvim_win_set_width(filetree.win, require('glance.config').options.windows.filetree.width)
  end
end

function M.special_hoverable_separator_wins()
  local wins = {}
  if filetree.win and vim.api.nvim_win_is_valid(filetree.win) then
    wins[#wins + 1] = filetree.win
  end
  return wins
end

function M.equalize(diffview)
  local tree_visible = filetree.win and vim.api.nvim_win_is_valid(filetree.win)
  local tree_width = 0

  if tree_visible then
    tree_width = require('glance.config').options.windows.filetree.width
    vim.api.nvim_win_set_width(filetree.win, tree_width)
  end

  local theirs_win = workspace.get_win(diffview.workspace, M.THEIRS_ROLE)
  local ours_win = workspace.get_win(diffview.workspace, M.OURS_ROLE)

  if not theirs_win or not vim.api.nvim_win_is_valid(theirs_win) then
    return
  end
  if not ours_win or not vim.api.nvim_win_is_valid(ours_win) then
    return
  end

  local separators = (tree_visible and 1 or 0) + 1
  local available = math.max(vim.o.columns - tree_width - separators, 2)
  local left_width = math.max(math.floor(available / 2), 1)
  local right_width = math.max(available - left_width, 1)

  vim.api.nvim_win_set_width(theirs_win, left_width)
  vim.api.nvim_win_set_width(ours_win, right_width)
end

function M.hoverable_separator_wins(diffview)
  local wins = {}

  if filetree.win and vim.api.nvim_win_is_valid(filetree.win) then
    wins[#wins + 1] = filetree.win
  end

  local theirs_win = workspace.get_win(diffview.workspace, M.THEIRS_ROLE)
  if theirs_win and vim.api.nvim_win_is_valid(theirs_win) then
    wins[#wins + 1] = theirs_win
  end

  return wins
end

return M
