local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

return {
  name = 'ui',
  cases = {
    {
      name = 'setup layout creates filetree and centered welcome pane',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local config = require('glance.config')
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          local lines = vim.api.nvim_buf_get_lines(ui.welcome_buf, 0, -1, false)
          local logo_line

          for _, line in ipairs(lines) do
            if line:find('glance', 1, true) then
              logo_line = line
              break
            end
          end

          local logo_hl = vim.api.nvim_get_hl(0, { name = 'GlanceWelcomeLogo', link = false })

          A.truthy(logo_line)
          A.equal(string.format('#%06x', logo_hl.fg), string.lower('#F2E94B'))
          A.equal(vim.api.nvim_win_get_width(filetree.win), config.options.filetree_width)
          A.equal(vim.api.nvim_get_current_win(), filetree.win)
        end)
      end,
    },
    {
      name = 'entering the welcome pane bounces focus back to the filetree',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')

          vim.api.nvim_set_current_win(ui.welcome_win)
          N.wait(100, function()
            return vim.api.nvim_get_current_win() == filetree.win
          end)
        end)
      end,
    },
    {
      name = 'opening a file closes welcome and routes to the correct diff opener',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local ui = require('glance.ui')
          local diffview = require('glance.diffview')
          local calls = {}
          local original = {
            open = diffview.open,
            open_deleted = diffview.open_deleted,
            open_untracked = diffview.open_untracked,
            close = diffview.close,
          }

          diffview.open = function(file)
            calls[#calls + 1] = 'open:' .. file.path
          end
          diffview.open_deleted = function(file)
            calls[#calls + 1] = 'deleted:' .. file.path
          end
          diffview.open_untracked = function(file)
            calls[#calls + 1] = 'untracked:' .. file.path
          end
          diffview.close = function()
          end

          ui.open_file({ path = 'gone.txt', status = 'D', section = 'changes' })
          ui.diff_open = false
          ui.show_welcome()
          ui.open_file({ path = 'scratch.txt', status = '?', section = 'untracked' })
          ui.diff_open = false
          ui.show_welcome()
          ui.open_file({ path = 'staged-add.txt', status = 'A', section = 'staged' })
          ui.diff_open = false
          ui.show_welcome()
          ui.open_file({ path = 'worktree-add.txt', status = 'A', section = 'changes' })

          diffview.open = original.open
          diffview.open_deleted = original.open_deleted
          diffview.open_untracked = original.open_untracked
          diffview.close = original.close

          A.same(calls, {
            'deleted:gone.txt',
            'untracked:scratch.txt',
            'open:staged-add.txt',
            'untracked:worktree-add.txt',
          })
          A.equal(ui.welcome_win, nil)
        end)
      end,
    },
    {
      name = 'close diff restores width welcome and refreshes the tree',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local config = require('glance.config')
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          local diffview = require('glance.diffview')

          ui.open_file(filetree.files.changes[1])
          diffview.close(true)

          A.falsy(ui.diff_open)
          A.truthy(ui.welcome_win and vim.api.nvim_win_is_valid(ui.welcome_win))
          A.equal(vim.api.nvim_win_get_width(filetree.win), config.options.filetree_width)
          A.equal(filetree.files.changes[1].path, 'tracked.txt')
        end)
      end,
    },
    {
      name = 'closing the filetree while only welcome is visible triggers quit',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          local original = vim.cmd
          local saw_quit = false

          vim.cmd = function(cmd)
            if cmd == 'qa!' then
              saw_quit = true
              return
            end
            return original(cmd)
          end

          vim.api.nvim_win_close(filetree.win, true)
          N.wait(100, function()
            return saw_quit
          end)
          vim.cmd = original

          A.falsy(ui.diff_open)
          A.truthy(saw_quit)
        end)
      end,
    },
  },
}
