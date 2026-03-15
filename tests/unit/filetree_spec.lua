local A = require('tests.helpers.assert')

local function setup_filetree()
  local filetree = require('glance.filetree')
  local buf = filetree.create_buf()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  filetree.win = win
  return filetree
end

return {
  name = 'filetree-unit',
  cases = {
    {
      name = 'render outputs staged changes and untracked sections',
      run = function()
        local filetree = setup_filetree()
        filetree.render({
          staged = {
            { path = 'staged.txt', status = 'M', section = 'staged' },
          },
          changes = {
            { path = 'changed.txt', status = 'D', section = 'changes' },
          },
          untracked = {
            { path = 'new.txt', status = '?', section = 'untracked' },
          },
        })

        A.same(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false), {
          '  discard',
          '  [d] file   [D] all',
          '',
          '  Staged Changes',
          '    M staged.txt',
          '',
          '  Changes',
          '    D changed.txt',
          '',
          '  Untracked',
          '    ? new.txt',
        })
        A.equal(filetree.selected_line, 5)
      end,
    },
    {
      name = 'render outputs conflicts as a dedicated section',
      run = function()
        local filetree = setup_filetree()
        filetree.render({
          conflicts = {
            { path = 'conflict.txt', status = 'U', section = 'conflicts' },
          },
          changes = {
            { path = 'typed.txt', status = 'T', section = 'changes' },
          },
        })

        A.same(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false), {
          '  discard',
          '  [d] file   [D] all',
          '',
          '  Conflicts',
          '    U conflict.txt',
          '',
          '  Changes',
          '    T typed.txt',
        })
        A.equal(filetree.selected_line, 5)
      end,
    },
    {
      name = 'render uses old path arrow for renames',
      run = function()
        local filetree = setup_filetree()
        filetree.render({
          staged = {
            {
              path = 'new/path.txt',
              old_path = 'old/path.txt',
              status = 'R',
              section = 'staged',
            },
          },
          changes = {},
          untracked = {},
        })

        A.equal(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false)[5], '    R old/path.txt → new/path.txt')
      end,
    },
    {
      name = 'render uses configured status glyphs',
      run = function()
        local config = require('glance.config')
        config.setup({
          signs = {
            copied = '>',
            conflicted = '!',
          },
        })

        local filetree = setup_filetree()
        filetree.render({
          conflicts = {
            { path = 'conflict.txt', status = 'U', section = 'conflicts' },
          },
          staged = {
            { path = 'copied.txt', status = 'C', section = 'staged' },
          },
        })

        A.equal(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false)[5], '    ! conflict.txt')
        A.equal(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false)[8], '    > copied.txt')
      end,
    },
    {
      name = 'render handles empty state',
      run = function()
        local filetree = setup_filetree()
        filetree.render({
          staged = {},
          changes = {},
          untracked = {},
        })

        A.same(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false), {
          '  discard',
          '  [d] file   [D] all',
          '',
          '  No changes found',
        })
        A.equal(filetree.get_selected_file(), nil)
      end,
    },
    {
      name = 'status highlight mapping is stable',
      run = function()
        local filetree = require('glance.filetree')
        A.equal(filetree.status_highlight('M'), 'GlanceStatusM')
        A.equal(filetree.status_highlight('A'), 'GlanceStatusA')
        A.equal(filetree.status_highlight('D'), 'GlanceStatusD')
        A.equal(filetree.status_highlight('R'), 'GlanceStatusR')
        A.equal(filetree.status_highlight('C'), 'GlanceStatusC')
        A.equal(filetree.status_highlight('T'), 'GlanceStatusT')
        A.equal(filetree.status_highlight('U'), 'GlanceStatusConflict')
        A.equal(filetree.status_highlight('?'), 'GlanceStatusU')
        A.equal(filetree.status_highlight('X'), nil)
      end,
    },
  },
}
