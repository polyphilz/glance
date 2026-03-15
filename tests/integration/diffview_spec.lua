local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

local function open_first_changed()
  local filetree = require('glance.filetree')
  local ui = require('glance.ui')
  ui.open_file(filetree.files.staged[1] or filetree.files.changes[1] or filetree.files.untracked[1])
  return require('glance.diffview')
end

return {
  name = 'diffview',
  cases = {
    {
      name = 'modified file opens a diff layout with editable right pane',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')

          A.truthy(diffview.old_win and vim.api.nvim_win_is_valid(diffview.old_win))
          A.truthy(diffview.new_win and vim.api.nvim_win_is_valid(diffview.new_win))
          A.equal(vim.api.nvim_get_option_value('diff', { win = diffview.old_win }), true)
          A.equal(vim.api.nvim_get_option_value('diff', { win = diffview.new_win }), true)
          A.equal(vim.api.nvim_get_option_value('buftype', { buf = diffview.new_buf }), '')
        end)
      end,
    },
    {
      name = 'staged files open temp backed read only panes',
      run = function()
        N.with_repo('repo_staged', function()
          require('glance').start()
          local diffview = open_first_changed()

          A.equal(vim.api.nvim_get_option_value('buftype', { buf = diffview.old_buf }), 'nofile')
          A.equal(vim.api.nvim_get_option_value('readonly', { buf = diffview.old_buf }), true)
          A.equal(vim.api.nvim_get_option_value('buftype', { buf = diffview.new_buf }), 'nofile')
          A.equal(vim.api.nvim_get_option_value('readonly', { buf = diffview.new_buf }), true)
        end)
      end,
    },
    {
      name = 'deleted files open a single readonly pane',
      run = function()
        N.with_repo('repo_deleted', function()
          require('glance').start()
          local diffview = open_first_changed()
          local deleted_ns = vim.api.nvim_create_namespace('glance_deleted')

          A.equal(diffview.old_win, nil)
          A.truthy(diffview.new_win and vim.api.nvim_win_is_valid(diffview.new_win))
          A.equal(vim.api.nvim_get_option_value('readonly', { buf = diffview.new_buf }), true)
          A.truthy(#vim.api.nvim_buf_get_extmarks(diffview.new_buf, deleted_ns, 0, -1, {}) > 0)
        end)
      end,
    },
    {
      name = 'untracked files open a single editable pane',
      run = function()

        N.with_repo('repo_untracked', function()
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          ui.open_file(filetree.files.untracked[1])
          local diffview = require('glance.diffview')

          A.equal(diffview.old_win, nil)
          A.equal(vim.api.nvim_get_option_value('buftype', { buf = diffview.new_buf }), '')
          A.equal(vim.api.nvim_get_option_value('readonly', { buf = diffview.new_buf }), false)
        end)
      end,
    },
    {
      name = 'conflicted files open a single editable pane with conflict markers',
      run = function()
        N.with_repo('repo_conflict', function()
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local minimap = require('glance.minimap')

          ui.open_file(filetree.files.conflicts[1])

          A.equal(diffview.old_win, nil)
          A.truthy(diffview.new_win and vim.api.nvim_win_is_valid(diffview.new_win))
          A.equal(vim.api.nvim_get_option_value('buftype', { buf = diffview.new_buf }), '')
          A.equal(vim.api.nvim_get_option_value('readonly', { buf = diffview.new_buf }), false)
          A.equal(vim.api.nvim_get_option_value('diff', { win = diffview.new_win }), false)
          A.equal(minimap.win, nil)

          local text = table.concat(vim.api.nvim_buf_get_lines(diffview.new_buf, 0, -1, false), '\n')
          A.contains(text, '<<<<<<<')
          A.contains(text, '=======')
          A.contains(text, '>>>>>>>')
        end)
      end,
    },
    {
      name = 'type-changed files open a placeholder instead of a diff',
      run = function()
        N.with_repo('repo_type_change', function()
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local minimap = require('glance.minimap')

          ui.open_file(filetree.files.changes[1])

          A.equal(diffview.old_win, nil)
          A.truthy(diffview.new_win and vim.api.nvim_win_is_valid(diffview.new_win))
          A.equal(vim.api.nvim_get_option_value('buftype', { buf = diffview.new_buf }), 'nofile')
          A.equal(vim.api.nvim_get_option_value('readonly', { buf = diffview.new_buf }), true)
          A.equal(vim.api.nvim_get_option_value('diff', { win = diffview.new_win }), false)
          A.equal(minimap.win, nil)

          local text = table.concat(vim.api.nvim_buf_get_lines(diffview.new_buf, 0, -1, false), '\n')
          A.contains(text, 'Kind: type_changed')
          A.contains(text, 'Raw status:  T')
          A.contains(text, 'type-changed entries are not supported yet')
        end)
      end,
    },
    {
      name = 'staged rename uses old path content in the left pane',
      run = function()
        N.with_repo('repo_rename', function()
          require('glance').start()
          local diffview = open_first_changed()

          A.same(vim.api.nvim_buf_get_lines(diffview.old_buf, 0, -1, false), { 'rename me' })
        end)
      end,
    },
    {
      name = 'equalize panes and diff keymaps respect filetree visibility',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')

          local visible_width = vim.api.nvim_win_get_width(diffview.old_win)
          filetree.toggle()
          diffview.equalize_panes()
          local hidden_width = vim.api.nvim_win_get_width(diffview.old_win)

          local keymaps = vim.api.nvim_buf_get_keymap(diffview.new_buf, 'n')
          local has_toggle = false
          for _, map in ipairs(keymaps) do
            if map.lhs == '<Tab>' then
              has_toggle = true
            end
          end

          A.truthy(hidden_width > visible_width)
          A.truthy(has_toggle)
        end)
      end,
    },
    {
      name = 'configured hunk navigation aliases jump between diff hunks',
      run = function()
        N.with_repo('repo_modified', function(repo)
          repo:write(repo.files.tracked, table.concat({
            'line 1',
            'line 2',
            'line 3',
            'line 4',
            'line 5',
            'line 6',
            'line 7',
            'line 8',
            'line 9',
            'line 10',
          }, '\n') .. '\n')
          repo:commit_all('seed multi-hunk baseline')

          repo:write(repo.files.tracked, table.concat({
            'line 1',
            'line 2 changed',
            'line 3',
            'line 4',
            'line 5 changed',
            'line 6',
            'line 7',
            'line 8',
            'line 9 changed',
            'line 10',
          }, '\n') .. '\n')

          require('glance').setup({
            app = {},
            hunk_navigation = {
              next = 'N',
              prev = 'n',
            },
          })
          require('glance').start()

          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')

          local keymaps = vim.api.nvim_buf_get_keymap(diffview.new_buf, 'n')
          local has_next = false
          local has_prev = false
          for _, map in ipairs(keymaps) do
            if map.lhs == 'N' then
              has_next = true
            elseif map.lhs == 'n' then
              has_prev = true
            end
          end

          vim.api.nvim_set_current_win(diffview.new_win)
          vim.api.nvim_win_set_cursor(diffview.new_win, { 1, 0 })

          N.press('N')
          A.equal(vim.api.nvim_win_get_cursor(diffview.new_win)[1], 2)

          N.press('N')
          A.equal(vim.api.nvim_win_get_cursor(diffview.new_win)[1], 5)

          N.press('n')
          A.equal(vim.api.nvim_win_get_cursor(diffview.new_win)[1], 2)

          A.truthy(has_next)
          A.truthy(has_prev)
        end)
      end,
    },
    {
      name = 'diff window options and watch lifecycle follow config',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').setup({
            windows = {
              diff = {
                number = false,
                relativenumber = false,
                signcolumn = 'yes',
                cursorline = true,
                foldenable = true,
              },
            },
            watch = {
              enabled = false,
            },
          })
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')

          A.equal(vim.api.nvim_get_option_value('number', { win = diffview.new_win }), false)
          A.equal(vim.api.nvim_get_option_value('relativenumber', { win = diffview.new_win }), false)
          A.equal(vim.api.nvim_get_option_value('signcolumn', { win = diffview.new_win }), 'yes')
          A.equal(vim.api.nvim_get_option_value('cursorline', { win = diffview.new_win }), true)
          A.equal(vim.api.nvim_get_option_value('foldenable', { win = diffview.new_win }), true)
          A.equal(diffview.fs_watcher, nil)
        end)
      end,
    },
    {
      name = 'save refreshes disk and minimap and watcher reloads external edits',
      run = function()
        N.with_repo('repo_modified', function(repo)
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          local minimap = require('glance.minimap')

          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')

          vim.api.nvim_buf_set_lines(diffview.new_buf, 0, -1, false, {
            'saved one',
            'saved two',
            'saved three',
            'saved four',
          })
          vim.api.nvim_buf_call(diffview.new_buf, function()
            vim.cmd('write')
          end)
          N.wait(200, function()
            local disk = repo:read(repo.files.tracked)
            return disk:find('saved one', 1, true) ~= nil
          end)
          N.wait(1000, function()
            return minimap.total_logical == 4
          end)
          A.truthy(minimap.cached_pixels ~= nil)
          A.equal(minimap.total_logical, 4)

          repo:write(repo.files.tracked, 'external change\n')
          N.wait(500, function()
            local lines = vim.api.nvim_buf_get_lines(diffview.new_buf, 0, -1, false)
            return lines[1] == 'external change'
          end)

          vim.api.nvim_buf_set_lines(diffview.new_buf, 0, -1, false, { 'local unsaved change' })
          repo:write(repo.files.tracked, 'external change while dirty\n')
          vim.wait(400)

          A.same(vim.api.nvim_buf_get_lines(diffview.new_buf, 0, -1, false), {
            'local unsaved change',
          })
          A.equal(vim.api.nvim_get_option_value('modified', { buf = diffview.new_buf }), true)
        end)
      end,
    },
    {
      name = 'unsaved prompt Yes writes No discards and Cancel aborts',
      run = function()
        N.with_repo('repo_modified', function(repo)
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')

          vim.api.nvim_buf_set_lines(diffview.new_buf, 0, -1, false, { 'save me' })
          N.with_confirm(1, function()
            diffview.close(false)
          end)
          A.falsy(ui.diff_open)
          A.contains(repo:read(repo.files.tracked), 'save me')

          ui.open_file(filetree.files.changes[1])
          diffview = require('glance.diffview')
          vim.api.nvim_buf_set_lines(diffview.new_buf, 0, -1, false, { 'discard me' })
          N.with_confirm(2, function()
            diffview.close(false)
          end)
          local path = repo:path(repo.files.tracked)
          A.falsy(N.find_buffer_by_name(path))
          ui.open_file(filetree.files.changes[1])
          diffview = require('glance.diffview')
          A.falsy(vim.deep_equal(vim.api.nvim_buf_get_lines(diffview.new_buf, 0, -1, false), { 'discard me' }))

          vim.api.nvim_buf_set_lines(diffview.new_buf, 0, -1, false, { 'cancel me' })
          N.with_confirm(3, function()
            diffview.close(false)
          end)
          A.truthy(ui.diff_open)
          A.truthy(diffview.new_win and vim.api.nvim_win_is_valid(diffview.new_win))
        end)
      end,
    },
    {
      name = 'closing a diff window cleans up the full view and hidden tree restore works',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')

          vim.api.nvim_win_close(diffview.old_win, true)
          N.wait(200, function()
            return not ui.diff_open
          end)
          A.truthy(filetree.win and vim.api.nvim_win_is_valid(filetree.win))
          A.truthy(ui.welcome_win and vim.api.nvim_win_is_valid(ui.welcome_win))

          ui.open_file(filetree.files.changes[1])
          diffview = require('glance.diffview')
          filetree.toggle()
          diffview.close(true)
          A.truthy(filetree.win and vim.api.nvim_win_is_valid(filetree.win))
          A.truthy(ui.welcome_win and vim.api.nvim_win_is_valid(ui.welcome_win))
        end)
      end,
    },
    {
      name = 'close restores lazyredraw when an internal step errors',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')
          local minimap = require('glance.minimap')
          local original = minimap.close
          local old_lazyredraw = vim.o.lazyredraw

          minimap.close = function()
            error('boom')
          end
          local ok = pcall(function()
            diffview.close(true)
          end)
          minimap.close = original

          A.falsy(ok)
          A.equal(vim.o.lazyredraw, old_lazyredraw)
        end)
      end,
    },
  },
}
