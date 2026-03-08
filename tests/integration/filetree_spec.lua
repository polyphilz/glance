local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

return {
  name = 'filetree-integration',
  cases = {
    {
      name = 'buffer options and initial cursor are correct',
      run = function()
        N.with_repo('repo_modified', function(repo)
          require('glance').start()
          local filetree = require('glance.filetree')
          local selected = filetree.get_selected_file()

          A.equal(vim.api.nvim_get_option_value('buftype', { buf = filetree.buf }), 'nofile')
          A.equal(vim.api.nvim_get_option_value('swapfile', { buf = filetree.buf }), false)
          A.equal(vim.api.nvim_get_option_value('filetype', { buf = filetree.buf }), 'glance')
          A.equal(filetree.selected_line, 2)
          A.equal(selected.path, repo.files.tracked)
        end)
      end,
    },
    {
      name = 'movement mappings skip headers honor sections and counts',
      run = function()
        N.with_repo('repo_untracked', function(repo)
          repo:write(repo.files.tracked, 'alpha\nbeta changed\ngamma\n')
          repo.files.staged_add = 'staged-only.txt'
          repo:write(repo.files.staged_add, 'staged only\n')
          repo:stage(repo.files.staged_add)
          require('glance').start()
          local filetree = require('glance.filetree')

          vim.api.nvim_set_current_win(filetree.win)
          A.equal(filetree.selected_line, 2)
          N.press('j')
          A.equal(filetree.selected_line, 5)
          N.press('j')
          A.equal(filetree.selected_line, 8)
          N.press('k')
          A.equal(filetree.selected_line, 5)
          N.press('K')
          A.equal(filetree.selected_line, 2)
          N.press('J')
          A.equal(filetree.selected_line, 5)
          N.press('2j')
          A.equal(filetree.selected_line, 8)
        end)
      end,
    },
    {
      name = 'refresh preserves selection where possible',
      run = function()
        N.with_repo('repo_untracked', function(repo)
          repo:write(repo.files.tracked, 'alpha\nbeta changed\ngamma\n')
          repo.files.staged_add = 'staged-only.txt'
          repo:write(repo.files.staged_add, 'staged only\n')
          repo:stage(repo.files.staged_add)
          require('glance').start()
          local filetree = require('glance.filetree')

          vim.api.nvim_set_current_win(filetree.win)
          N.press('j')
          A.equal(filetree.get_selected_file().path, 'tracked.txt')

          local file = assert(io.open(repo.root .. '/later.txt', 'w'))
          file:write('later\n')
          file:close()

          filetree.refresh()
          A.equal(filetree.get_selected_file().path, 'tracked.txt')
        end)
      end,
    },
    {
      name = 'highlight active adds and clears the active extmark',
      run = function()
        N.with_repo('repo_modified', function(repo)
          require('glance').start()
          local filetree = require('glance.filetree')
          local ns = vim.api.nvim_create_namespace('glance_active')

          filetree.highlight_active({
            path = repo.files.tracked,
            section = 'changes',
          })
          local marks = vim.api.nvim_buf_get_extmarks(filetree.buf, ns, 0, -1, {})
          A.length(marks, 1)

          filetree.highlight_active(nil)
          marks = vim.api.nvim_buf_get_extmarks(filetree.buf, ns, 0, -1, {})
          A.length(marks, 0)
        end)
      end,
    },
    {
      name = 'toggle hides and restores the sidebar and returns focus to diff',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          local diffview = require('glance.diffview')

          ui.open_file(filetree.files.changes[1])
          A.truthy(diffview.new_win and vim.api.nvim_win_is_valid(diffview.new_win))
          filetree.toggle()
          A.equal(filetree.win, nil)

          filetree.toggle()
          A.truthy(filetree.win and vim.api.nvim_win_is_valid(filetree.win))
          A.equal(vim.api.nvim_get_current_win(), diffview.new_win)
        end)
      end,
    },
  },
}
