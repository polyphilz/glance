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
          local keymaps = vim.api.nvim_buf_get_keymap(filetree.buf, 'n')
          local lines = vim.api.nvim_buf_get_lines(filetree.buf, 0, 2, false)
          local saw_discard = false
          local saw_discard_all = false

          for _, map in ipairs(keymaps) do
            if map.lhs == 'd' then
              saw_discard = true
            elseif map.lhs == 'D' then
              saw_discard_all = true
            end
          end

          A.equal(vim.api.nvim_get_option_value('buftype', { buf = filetree.buf }), 'nofile')
          A.equal(vim.api.nvim_get_option_value('swapfile', { buf = filetree.buf }), false)
          A.equal(vim.api.nvim_get_option_value('filetype', { buf = filetree.buf }), 'glance')
          A.truthy(saw_discard)
          A.truthy(saw_discard_all)
          A.same(lines, {
            '  discard',
            '  [d] file   [D] all',
          })
          A.equal(filetree.selected_line, 5)
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
          A.equal(filetree.selected_line, 5)
          N.press('j')
          A.equal(filetree.selected_line, 8)
          N.press('j')
          A.equal(filetree.selected_line, 11)
          N.press('k')
          A.equal(filetree.selected_line, 8)
          N.press('K')
          A.equal(filetree.selected_line, 5)
          N.press('J')
          A.equal(filetree.selected_line, 8)
          N.press('2j')
          A.equal(filetree.selected_line, 11)
        end)
      end,
    },
    {
      name = 'arrow keys cross section headers in both directions',
      run = function()
        N.with_repo('repo_untracked', function(repo)
          repo:write(repo.files.tracked, 'alpha\nbeta changed\ngamma\n')
          repo.files.staged_add = 'staged-only.txt'
          repo:write(repo.files.staged_add, 'staged only\n')
          repo:stage(repo.files.staged_add)
          require('glance').start()
          local filetree = require('glance.filetree')

          vim.api.nvim_set_current_win(filetree.win)
          A.equal(filetree.selected_line, 5)

          N.press('<Down>')
          A.equal(filetree.selected_line, 8)

          N.press('<Down>')
          A.equal(filetree.selected_line, 11)

          N.press('<Up>')
          A.equal(filetree.selected_line, 8)

          N.press('<Up>')
          A.equal(filetree.selected_line, 5)
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
      name = 'type-changed entries render in the changes section',
      run = function()
        N.with_repo('repo_type_change', function(repo)
          require('glance').start()
          local filetree = require('glance.filetree')
          local lines = vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false)

          A.contains(lines, '  Changes')
          A.contains(lines, '    T ' .. repo.files.tracked)
          A.equal(filetree.get_selected_file().path, repo.files.tracked)
          A.equal(filetree.get_selected_file().section, 'changes')
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
    {
      name = 'discard selected file honors confirm and closes the active diff when needed',
      run = function()
        N.with_repo('repo_modified', function(repo)
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          local diffview = require('glance.diffview')
          local git = require('glance.git')

          ui.open_file(filetree.files.changes[1])
          vim.api.nvim_buf_set_lines(diffview.new_buf, 0, -1, false, { 'unsaved change' })
          vim.api.nvim_set_current_win(filetree.win)

          N.with_confirm(2, function()
            N.press('d')
          end)
          A.truthy(ui.diff_open)
          A.equal(repo:read(repo.files.tracked), 'alpha\nbeta modified\ngamma\n')

          N.with_confirm(1, function()
            N.press('d')
          end)

          A.falsy(ui.diff_open)
          A.equal(repo:read(repo.files.tracked), 'alpha\nbeta\ngamma\n')
          A.same(git.get_changed_files(), {
            staged = {},
            changes = {},
            untracked = {},
            conflicts = {},
          })
        end)
      end,
    },
    {
      name = 'discard selected file warns for blocked states without prompting',
      run = function()
        N.with_repo('repo_type_change', function(repo)
          require('glance').start()
          local filetree = require('glance.filetree')
          local git = require('glance.git')
          local messages, restore = N.capture_notifications()
          local original_confirm = vim.fn.confirm
          local confirm_calls = 0

          vim.fn.confirm = function()
            confirm_calls = confirm_calls + 1
            return 1
          end

          local ok, err = xpcall(function()
            vim.api.nvim_set_current_win(filetree.win)
            N.press('d')
          end, debug.traceback)

          vim.fn.confirm = original_confirm
          restore()

          if not ok then
            error(err, 0)
          end

          A.equal(confirm_calls, 0)
          A.equal(messages[1].msg, git.UNSUPPORTED_DISCARD_MESSAGE)
          A.equal(messages[1].level, vim.log.levels.WARN)
          A.contains(repo:git({ 'status', '--porcelain=v1', '--untracked-files=all' }), 'T ' .. repo.files.tracked)
        end)
      end,
    },
    {
      name = 'discard all honors confirm and resets the repo state',
      run = function()
        N.with_repo('repo_modified', function(repo)
          repo.files.staged_add = 'new-file.txt'
          repo.files.untracked = 'scratch.txt'
          repo:write(repo.files.staged_add, 'new staged file\n')
          repo:stage(repo.files.staged_add)
          repo:write(repo.files.untracked, 'scratch\n')

          require('glance').start()
          local filetree = require('glance.filetree')

          vim.api.nvim_set_current_win(filetree.win)

          N.with_confirm(2, function()
            N.press('D')
          end)
          A.equal(repo:read(repo.files.tracked), 'alpha\nbeta modified\ngamma\n')
          A.truthy(vim.uv.fs_stat(repo:path(repo.files.staged_add)))
          A.truthy(vim.uv.fs_stat(repo:path(repo.files.untracked)))

          N.with_confirm(1, function()
            N.press('D')
          end)

          A.equal(vim.trim(repo:git({ 'status', '--porcelain=v1', '--untracked-files=all' })), '')
          A.equal(repo:read(repo.files.tracked), 'alpha\nbeta\ngamma\n')
          A.falsy(vim.uv.fs_stat(repo:path(repo.files.staged_add)))
          A.falsy(vim.uv.fs_stat(repo:path(repo.files.untracked)))
        end)
      end,
    },
    {
      name = 'discard all warns when the repo contains blocked states',
      run = function()
        N.with_repo('repo_binary_staged_add', function(repo)
          require('glance').start()
          local filetree = require('glance.filetree')
          local git = require('glance.git')
          local messages, restore = N.capture_notifications()
          local original_confirm = vim.fn.confirm
          local confirm_calls = 0

          vim.fn.confirm = function()
            confirm_calls = confirm_calls + 1
            return 1
          end

          local ok, err = xpcall(function()
            vim.api.nvim_set_current_win(filetree.win)
            N.press('D')
          end, debug.traceback)

          vim.fn.confirm = original_confirm
          restore()

          if not ok then
            error(err, 0)
          end

          A.equal(confirm_calls, 0)
          A.equal(messages[1].msg, git.UNSUPPORTED_DISCARD_MESSAGE)
          A.equal(messages[1].level, vim.log.levels.WARN)
          A.contains(repo:git({ 'status', '--porcelain=v1', '--untracked-files=all' }), 'A  ' .. repo.files.binary)
        end)
      end,
    },
  },
}
