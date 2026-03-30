local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

return {
  name = 'log-view-integration',
  cases = {
    {
      name = 'filetree log key opens history, previews a commit, copies its hash, and restores focus on close',
      run = function()
        N.with_repo('repo_history', function()
          require('glance').start()

          local filetree = require('glance.filetree')
          local log_view = require('glance.log_view')
          local filetree_win = filetree.win

          vim.api.nvim_set_current_win(filetree.win)
          N.press('L')

          A.truthy(log_view.is_open())
          A.equal(vim.api.nvim_get_current_win(), log_view.win)
          A.equal(log_view.mode, 'list')
          A.equal(log_view.entries[1].subject, 'Add notes')

          local selected_hash = log_view.entries[1].hash
          N.press('<CR>')

          A.equal(log_view.mode, 'preview')
          local preview_text = table.concat(vim.api.nvim_buf_get_lines(log_view.buf, 0, -1, false), '\n')
          A.contains(preview_text, 'commit ' .. selected_hash)
          A.contains(preview_text, 'Add notes')

          N.press('y')
          A.equal(vim.fn.getreg('"'), selected_hash)

          N.press('q')
          A.equal(log_view.mode, 'list')
          A.truthy(log_view.is_open())

          N.press('q')
          A.falsy(log_view.is_open())
          A.equal(vim.api.nvim_get_current_win(), filetree_win)
        end)
      end,
    },
    {
      name = 'opening log over an active diff preserves the underlying diff after the modal closes',
      run = function()
        N.with_repo('repo_history', function(repo)
          repo:append(repo.files.tracked, 'delta\n')
          require('glance').start()

          local diffview = require('glance.diffview')
          local filetree = require('glance.filetree')
          local log_view = require('glance.log_view')
          local ui = require('glance.ui')

          ui.open_file(filetree.files.changes[1])
          A.truthy(ui.diff_open)
          A.truthy(diffview.new_win and vim.api.nvim_win_is_valid(diffview.new_win))

          vim.api.nvim_set_current_win(filetree.win)
          N.press('L')
          A.truthy(log_view.is_open())

          N.press('q')

          A.falsy(log_view.is_open())
          A.truthy(ui.diff_open)
          A.truthy(diffview.new_win and vim.api.nvim_win_is_valid(diffview.new_win))
          A.equal(vim.api.nvim_get_current_win(), filetree.win)
        end)
      end,
    },
    {
      name = 'empty repos with no commits show a friendly log empty state',
      run = function()
        N.with_repo('repo_unborn_clean', function()
          require('glance').start()

          local filetree = require('glance.filetree')
          local log_view = require('glance.log_view')

          vim.api.nvim_set_current_win(filetree.win)
          N.press('L')

          A.truthy(log_view.is_open())
          A.same(vim.api.nvim_buf_get_lines(log_view.buf, 0, -1, false), {
            '  [Enter] preview  [y] copy hash  [r] refresh  [q] close',
            '',
            '  No commits found',
          })

          N.press('q')
          A.falsy(log_view.is_open())
          A.equal(vim.api.nvim_get_current_win(), filetree.win)
        end)
      end,
    },
  },
}
