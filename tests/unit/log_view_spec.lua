local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

local function entries()
  return {
    {
      hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      short_hash = 'aaaaaaa',
      decorations = 'HEAD -> main',
      author_name = 'Glance Tests',
      relative_date = '2 hours ago',
      subject = 'Add history browser',
    },
    {
      hash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      short_hash = 'bbbbbbb',
      decorations = 'tag: v0.1.0',
      author_name = 'Glance Tests',
      relative_date = '3 days ago',
      subject = 'Handle preview reload',
    },
  }
end

return {
  name = 'log-view',
  cases = {
    {
      name = 'open and close manage the floating log lifecycle',
      run = function()
        local git = require('glance.git')
        local log_view = require('glance.log_view')
        local initial_win = vim.api.nvim_get_current_win()
        local original_get_log_entries = git.get_log_entries

        local ok, err = xpcall(function()
          git.get_log_entries = function()
            return entries()
          end

          log_view.open()

          A.truthy(log_view.is_open())
          A.equal(vim.api.nvim_get_current_win(), log_view.win)
          A.equal(vim.api.nvim_get_option_value('buftype', { buf = log_view.buf }), 'nofile')
          A.equal(vim.api.nvim_get_option_value('bufhidden', { buf = log_view.buf }), 'wipe')
          A.equal(vim.api.nvim_get_option_value('swapfile', { buf = log_view.buf }), false)
          A.equal(vim.api.nvim_get_option_value('winhighlight', { win = log_view.win }),
            'FloatTitle:GlanceLegendKey,CursorLine:GlanceActiveFile')

          log_view.close()

          A.falsy(log_view.is_open())
          A.equal(vim.api.nvim_get_current_win(), initial_win)
        end, debug.traceback)

        git.get_log_entries = original_get_log_entries

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'list render shows two-line entries with metadata',
      run = function()
        local git = require('glance.git')
        local log_view = require('glance.log_view')
        local original_get_log_entries = git.get_log_entries

        local ok, err = xpcall(function()
          git.get_log_entries = function()
            return entries()
          end

          log_view.open()

          A.same(vim.api.nvim_buf_get_lines(log_view.buf, 0, -1, false), {
            '  [Enter] preview  [y] copy hash  [r] refresh  [q] close',
            '',
            '  aaaaaaa  Add history browser',
            '    HEAD -> main  |  Glance Tests  |  2 hours ago',
            '',
            '  bbbbbbb  Handle preview reload',
            '    tag: v0.1.0  |  Glance Tests  |  3 days ago',
          })
          A.equal(log_view.selected_index, 1)
          A.equal(vim.api.nvim_win_get_cursor(log_view.win)[1], 3)

          log_view.close()
        end, debug.traceback)

        git.get_log_entries = original_get_log_entries

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'empty history renders a friendly empty state',
      run = function()
        local git = require('glance.git')
        local log_view = require('glance.log_view')
        local original_get_log_entries = git.get_log_entries

        local ok, err = xpcall(function()
          git.get_log_entries = function()
            return {}
          end

          log_view.open()

          A.same(vim.api.nvim_buf_get_lines(log_view.buf, 0, -1, false), {
            '  [Enter] preview  [y] copy hash  [r] refresh  [q] close',
            '',
            '  No commits found',
          })
          A.equal(vim.api.nvim_get_option_value('cursorline', { win = log_view.win }), false)

          log_view.close()
        end, debug.traceback)

        git.get_log_entries = original_get_log_entries

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'preview render and q return to the list without closing the modal',
      run = function()
        local git = require('glance.git')
        local log_view = require('glance.log_view')
        local original_get_log_entries = git.get_log_entries
        local original_get_commit_preview = git.get_commit_preview

        local ok, err = xpcall(function()
          git.get_log_entries = function()
            return entries()
          end
          git.get_commit_preview = function()
            return {
              'commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              'Author:     Glance Tests <glance-tests@example.com>',
              'AuthorDate: Sun Mar 29 12:00:00 2026 -0400',
              '',
              '    Add history browser',
            }
          end

          log_view.open()
          log_view.open_preview()

          A.equal(log_view.mode, 'preview')
          A.same(vim.api.nvim_buf_get_lines(log_view.buf, 0, 7, false), {
            '  [q] back  [y] copy hash  [r] reload',
            '',
            'commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'Author:     Glance Tests <glance-tests@example.com>',
            'AuthorDate: Sun Mar 29 12:00:00 2026 -0400',
            '',
            '    Add history browser',
          })

          N.press('q')

          A.truthy(log_view.is_open())
          A.equal(log_view.mode, 'list')
          A.equal(vim.api.nvim_win_get_cursor(log_view.win)[1], 3)

          log_view.close()
        end, debug.traceback)

        git.get_log_entries = original_get_log_entries
        git.get_commit_preview = original_get_commit_preview

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'refresh uses the configured max_commits value',
      run = function()
        local config = require('glance.config')
        local git = require('glance.git')
        local log_view = require('glance.log_view')
        local original_get_log_entries = git.get_log_entries
        local seen_max_commits

        local ok, err = xpcall(function()
          config.setup({
            log = {
              max_commits = 25,
            },
          })

          git.get_log_entries = function(opts)
            seen_max_commits = opts and opts.max_commits or nil
            return entries()
          end

          log_view.open()

          A.equal(seen_max_commits, 25)

          log_view.close()
        end, debug.traceback)

        git.get_log_entries = original_get_log_entries

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'copy_selected_hash writes the current hash into the unnamed register',
      run = function()
        local git = require('glance.git')
        local log_view = require('glance.log_view')
        local original_get_log_entries = git.get_log_entries
        local messages, restore = N.capture_notifications()

        local ok, err = xpcall(function()
          git.get_log_entries = function()
            return entries()
          end

          log_view.open()
          log_view.copy_selected_hash()

          A.equal(vim.fn.getreg('"'), entries()[1].hash)
          A.equal(messages[1].msg, 'glance: copied commit hash aaaaaaa')

          log_view.close()
        end, debug.traceback)

        restore()
        git.get_log_entries = original_get_log_entries

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'copy_selected_hash tolerates clipboard register failures',
      run = function()
        local git = require('glance.git')
        local log_view = require('glance.log_view')
        local original_get_log_entries = git.get_log_entries
        local original_provider = vim.fn['provider#clipboard#Executable']
        local original_setreg = vim.fn.setreg
        local messages, restore = N.capture_notifications()

        local ok, err = xpcall(function()
          git.get_log_entries = function()
            return entries()
          end

          vim.fn['provider#clipboard#Executable'] = function()
            return 'fake-provider'
          end
          vim.fn.setreg = function(register, value)
            if register == '+' or register == '*' then
              error('clipboard unavailable')
            end
            return original_setreg(register, value)
          end

          log_view.open()
          A.truthy(log_view.copy_selected_hash())

          A.equal(vim.fn.getreg('"'), entries()[1].hash)
          A.equal(messages[1].msg, 'glance: copied commit hash aaaaaaa')

          log_view.close()
        end, debug.traceback)

        restore()
        git.get_log_entries = original_get_log_entries
        vim.fn['provider#clipboard#Executable'] = original_provider
        vim.fn.setreg = original_setreg

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'opening an existing modal focuses it instead of creating a duplicate',
      run = function()
        local git = require('glance.git')
        local log_view = require('glance.log_view')
        local original_get_log_entries = git.get_log_entries

        local ok, err = xpcall(function()
          git.get_log_entries = function()
            return entries()
          end

          log_view.open()
          local first_buf = log_view.buf
          local first_win = log_view.win

          vim.cmd('wincmd p')
          log_view.open()

          A.equal(log_view.buf, first_buf)
          A.equal(log_view.win, first_win)
          A.equal(vim.api.nvim_get_current_win(), first_win)

          log_view.close()
        end, debug.traceback)

        git.get_log_entries = original_get_log_entries

        if not ok then
          error(err)
        end
      end,
    },
  },
}
