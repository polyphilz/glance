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
          A.equal(string.format('#%06x', logo_hl.fg), string.lower('#FD971F'))
          A.equal(vim.api.nvim_win_get_width(filetree.win), config.options.windows.filetree.width)
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
      name = 'hover highlighting marks Glance separators and preserves diff winhighlight',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')

          local filetree_pos = vim.fn.win_screenpos(filetree.win)
          ui.update_separator_hover({
            winid = filetree.win,
            line = 0,
            column = 0,
            screenrow = filetree_pos[1],
            screencol = filetree_pos[2] + vim.api.nvim_win_get_width(filetree.win),
          })

          A.match(vim.api.nvim_get_option_value('winhighlight', { win = filetree.win }), 'WinSeparator:GlanceSeparatorHover')

          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')
          local diff_pos = vim.fn.win_screenpos(diffview.old_win)
          ui.update_separator_hover({
            winid = diffview.old_win,
            line = 0,
            column = 0,
            screenrow = diff_pos[1],
            screencol = diff_pos[2] + vim.api.nvim_win_get_width(diffview.old_win),
          })

          local winhl = vim.api.nvim_get_option_value('winhighlight', { win = diffview.old_win })
          A.contains(winhl, 'DiffChange:GlanceDiffChangeOld')
          A.contains(winhl, 'DiffText:GlanceDiffTextOld')
          A.contains(winhl, 'WinSeparator:GlanceSeparatorHover')

          ui.clear_separator_hover()
          winhl = vim.api.nvim_get_option_value('winhighlight', { win = diffview.old_win })
          A.contains(winhl, 'DiffChange:GlanceDiffChangeOld')
          A.contains(winhl, 'DiffText:GlanceDiffTextOld')
          A.falsy(winhl:find('WinSeparator:GlanceSeparatorHover', 1, true))
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
            open_binary = diffview.open_binary,
            open_copied = diffview.open_copied,
            open_type_changed = diffview.open_type_changed,
            open_conflict = diffview.open_conflict,
            open_placeholder = diffview.open_placeholder,
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
          diffview.open_binary = function(file)
            calls[#calls + 1] = 'binary:' .. file.path
          end
          diffview.open_copied = function(file)
            calls[#calls + 1] = 'copied:' .. file.path
          end
          diffview.open_type_changed = function(file)
            calls[#calls + 1] = 'type_changed:' .. file.path
          end
          diffview.open_conflict = function(file)
            calls[#calls + 1] = 'conflict:' .. file.path
          end
          diffview.open_placeholder = function(file, message)
            calls[#calls + 1] = 'placeholder:' .. (file.kind or 'unknown') .. ':' .. file.path .. ':' .. tostring(message)
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
          ui.diff_open = false
          ui.show_welcome()
          ui.open_file({ path = 'conflict.txt', status = 'U', section = 'conflicts', kind = 'conflicted' })
          ui.diff_open = false
          ui.show_welcome()
          ui.open_file({ path = 'typed.txt', status = 'T', section = 'changes', kind = 'type_changed' })
          ui.diff_open = false
          ui.show_welcome()
          ui.open_file({ path = 'copied.txt', status = 'C', section = 'staged', kind = 'copied' })
          ui.diff_open = false
          ui.show_welcome()
          ui.open_file({ path = 'mystery.txt', status = 'X', section = 'changes', kind = 'unsupported' })
          ui.diff_open = false
          ui.show_welcome()
          ui.open_file({ path = 'binary.bin', status = 'M', section = 'changes', kind = 'modified', is_binary = true })

          diffview.open = original.open
          diffview.open_deleted = original.open_deleted
          diffview.open_untracked = original.open_untracked
          diffview.open_binary = original.open_binary
          diffview.open_copied = original.open_copied
          diffview.open_type_changed = original.open_type_changed
          diffview.open_conflict = original.open_conflict
          diffview.open_placeholder = original.open_placeholder
          diffview.close = original.close

          A.same(calls, {
            'deleted:gone.txt',
            'untracked:scratch.txt',
            'open:staged-add.txt',
            'untracked:worktree-add.txt',
            'conflict:conflict.txt',
            'type_changed:typed.txt',
            'copied:copied.txt',
            'placeholder:unsupported:mystery.txt:nil',
            'binary:binary.bin',
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
          A.equal(vim.api.nvim_win_get_width(filetree.win), config.options.windows.filetree.width)
          A.equal(filetree.files.changes[1].path, 'tracked.txt')
        end)
      end,
    },
    {
      name = 'repo watcher closes stale diff panes after commit and shows the empty state',
      run = function()
        N.with_repo('repo_modified', function(repo)
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')

          ui.open_file(filetree.files.changes[1])
          repo:commit_all('Commit while Glance is open')

          N.wait(1500, function()
            return not ui.diff_open and filetree.files
              and #filetree.files.conflicts == 0
              and #filetree.files.staged == 0
              and #filetree.files.changes == 0
              and #filetree.files.untracked == 0
          end)

          local lines = vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false)
          A.truthy(ui.welcome_win and vim.api.nvim_win_is_valid(ui.welcome_win))
          A.equal(lines[#lines], '  No changes found')
          A.equal(vim.api.nvim_get_option_value('cursorline', { win = filetree.win }), false)
          A.same(vim.api.nvim_win_get_cursor(filetree.win), { #lines, 4 })
        end)
      end,
    },
    {
      name = 'repo watch polling surfaces newly created untracked files while Glance is open',
      run = function()
        N.with_repo('repo_modified', function(repo)
          require('glance').setup({
            watch = {
              poll = true,
            },
          })
          require('glance').start()
          local filetree = require('glance.filetree')

          repo:write('notes/new-untracked.txt', 'hello\n')

          N.wait(1500, function()
            local files = filetree.files or {}
            return #(files.untracked or {}) == 1
              and files.untracked[1].path == 'notes/new-untracked.txt'
          end)
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
