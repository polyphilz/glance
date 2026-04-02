local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

local function open_first_changed()
  local filetree = require('glance.filetree')
  local ui = require('glance.ui')
  ui.open_file(filetree.files.staged[1] or filetree.files.changes[1] or filetree.files.untracked[1])
  return require('glance.diffview')
end

local function open_custom_workspace(role_specs, opts)
  opts = opts or {}

  require('glance').start()
  local diffview = require('glance.diffview')
  local ui = require('glance.ui')

  ui.close_welcome()
  ui.diff_open = true
  diffview.configure_workspace({
    roles = role_specs,
    preferred_focus_role = opts.preferred_focus_role,
    editable_role = opts.editable_role,
  })

  local wins = {}
  local bufs = {}
  for _, spec in ipairs(role_specs) do
    if spec.kind == 'content' then
      local win, buf = diffview.open_workspace_pane(spec.role)
      wins[spec.role] = win
      bufs[spec.role] = buf
      pcall(vim.api.nvim_buf_set_name, buf, 'glance://' .. spec.role)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { spec.role })
    end
  end

  diffview.equalize_panes()
  return diffview, wins, bufs
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
          local conflict_ns = vim.api.nvim_create_namespace('glance_conflict')

          ui.open_file(filetree.files.conflicts[1])

          A.equal(diffview.old_win, nil)
          A.truthy(diffview.new_win and vim.api.nvim_win_is_valid(diffview.new_win))
          A.equal(vim.api.nvim_get_option_value('buftype', { buf = diffview.new_buf }), '')
          A.equal(vim.api.nvim_get_option_value('readonly', { buf = diffview.new_buf }), false)
          A.equal(vim.api.nvim_get_option_value('diff', { win = diffview.new_win }), false)
          A.equal(vim.api.nvim_get_option_value('winbar', { win = diffview.new_win }), 'Conflict: unresolved markers')
          A.equal(minimap.win, nil)
          A.truthy(#vim.api.nvim_buf_get_extmarks(diffview.new_buf, conflict_ns, 0, -1, {}) > 0)

          local text = table.concat(vim.api.nvim_buf_get_lines(diffview.new_buf, 0, -1, false), '\n')
          A.contains(text, '<<<<<<<')
          A.contains(text, '=======')
          A.contains(text, '>>>>>>>')

          local keymaps = vim.api.nvim_buf_get_keymap(diffview.new_buf, 'n')
          local found_next = false
          local found_prev = false
          for _, map in ipairs(keymaps) do
            if map.lhs == ']x' then
              found_next = true
            elseif map.lhs == '[x' then
              found_prev = true
            end
          end
          A.truthy(found_next)
          A.truthy(found_prev)
        end)
      end,
    },
    {
      name = 'conflict navigation keymaps jump to unresolved markers',
      run = function()
        N.with_repo('repo_conflict', function()
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')

          ui.open_file(filetree.files.conflicts[1])
          vim.api.nvim_set_current_win(diffview.new_win)

          local lines = vim.api.nvim_buf_get_lines(diffview.new_buf, 0, -1, false)
          local marker_line
          for index, line in ipairs(lines) do
            if line:match('^<<<<<<<') then
              marker_line = index
              break
            end
          end

          A.truthy(marker_line)

          vim.api.nvim_win_set_cursor(diffview.new_win, { #lines, 0 })
          N.press(']x')
          A.equal(vim.api.nvim_win_get_cursor(diffview.new_win)[1], marker_line)
          N.press(']x')
          A.equal(vim.api.nvim_win_get_cursor(diffview.new_win)[1], marker_line)

          vim.api.nvim_win_set_cursor(diffview.new_win, { #lines, 0 })
          N.press('[x')
          A.equal(vim.api.nvim_win_get_cursor(diffview.new_win)[1], marker_line)
        end)
      end,
    },
    {
      name = 'type-changed files open a metadata panel instead of a diff',
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
          A.contains(text, 'Type Changed')
          A.contains(text, 'regular file → symlink')
          A.contains(text, 'Unstaged')
        end)
      end,
    },
    {
      name = 'binary entries open a metadata panel instead of a text diff',
      run = function()
        N.with_repo('repo_binary_staged_add', function(repo)
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local minimap = require('glance.minimap')

          ui.open_file(filetree.files.staged[1])

          A.equal(diffview.old_win, nil)
          A.truthy(diffview.new_win and vim.api.nvim_win_is_valid(diffview.new_win))
          A.equal(vim.api.nvim_get_option_value('buftype', { buf = diffview.new_buf }), 'nofile')
          A.equal(vim.api.nvim_get_option_value('readonly', { buf = diffview.new_buf }), true)
          A.equal(vim.api.nvim_get_option_value('modifiable', { buf = diffview.new_buf }), false)
          A.equal(vim.api.nvim_get_option_value('diff', { win = diffview.new_win }), false)
          A.equal(minimap.win, nil)

          local text = table.concat(vim.api.nvim_buf_get_lines(diffview.new_buf, 0, -1, false), '\n')
          A.contains(text, 'Binary File')
          A.contains(text, repo.files.binary)
          A.contains(text, 'Staged')
          A.contains(text, 'Old size   —')
          A.match(text, 'New size   %d+ B')
        end)
      end,
    },
    {
      name = 'copied entries open a metadata panel when rendered directly',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local diffview = require('glance.diffview')
          local git = require('glance.git')
          local original = git.get_diff_stat

          git.get_diff_stat = function()
            return table.concat({
              'copy original.txt => copy.txt (100%)',
              '1 file changed, 0 insertions(+), 0 deletions(-)',
            }, '\n')
          end

          local ok, err = xpcall(function()
            diffview.open_copied({
              path = 'copy.txt',
              old_path = 'original.txt',
              section = 'staged',
              status = 'C',
              kind = 'copied',
            })

            A.equal(vim.api.nvim_get_option_value('buftype', { buf = diffview.new_buf }), 'nofile')
            A.equal(vim.api.nvim_get_option_value('readonly', { buf = diffview.new_buf }), true)

            local text = table.concat(vim.api.nvim_buf_get_lines(diffview.new_buf, 0, -1, false), '\n')
            A.contains(text, 'Copied File')
            A.contains(text, 'original.txt → copy.txt')
            A.contains(text, '  copy original.txt => copy.txt (100%)')
          end, debug.traceback)

          git.get_diff_stat = original
          if not ok then
            error(err, 0)
          end
        end)
      end,
    },
    {
      name = 'staged rename uses old path content in the left pane',
      run = function()
        N.with_repo('repo_rename', function(repo)
          require('glance').start()
          local diffview = open_first_changed()

          A.same(vim.api.nvim_buf_get_lines(diffview.old_buf, 0, -1, false), { 'rename me' })
          A.equal(vim.api.nvim_get_option_value('winbar', { win = diffview.old_win }), 'Old: ' .. repo.files.renamed_old)
          A.equal(vim.api.nvim_get_option_value('winbar', { win = diffview.new_win }), 'New: ' .. repo.files.renamed_new)
        end)
      end,
    },
    {
      name = 'unstaged rename keeps old-path baseline and visible path labels',
      run = function()
        N.with_repo('repo_unstaged_rename', function(repo)
          require('glance').start()
          local diffview = open_first_changed()

          A.same(vim.api.nvim_buf_get_lines(diffview.old_buf, 0, -1, false), { 'rename me' })
          A.equal(vim.api.nvim_get_option_value('winbar', { win = diffview.old_win }), 'Old: ' .. repo.files.renamed_old)
          A.equal(vim.api.nvim_get_option_value('winbar', { win = diffview.new_win }), 'New: ' .. repo.files.renamed_new)
        end)
      end,
    },
    {
      name = 'manual refresh rebaselines an open staged diff when HEAD moves without status changing',
      run = function()
        N.with_repo('repo_no_changes', function(repo)
          repo:write(repo.files.tracked, 'alpha\nbeta second\ngamma\n')
          repo:stage(repo.files.tracked)
          repo:commit_all('Second commit')

          repo:write(repo.files.tracked, 'alpha\nbeta third\ngamma\n')
          repo:stage(repo.files.tracked)

          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          ui.open_file(filetree.files.staged[1])
          local diffview = require('glance.diffview')

          A.same(vim.api.nvim_buf_get_lines(diffview.old_buf, 0, -1, false), {
            'alpha',
            'beta second',
            'gamma',
          })

          local before_key = filetree.repo_snapshot_key
          repo:git({ 'reset', '--soft', 'HEAD^' })
          filetree.refresh()

          A.truthy(ui.diff_open)
          A.not_equal(filetree.repo_snapshot_key, before_key)
          A.same(vim.api.nvim_buf_get_lines(diffview.old_buf, 0, -1, false), {
            'alpha',
            'beta',
            'gamma',
          })
        end)
      end,
    },
    {
      name = 'manual refresh updates an open staged diff when index content changes without status changing',
      run = function()
        N.with_repo('repo_no_changes', function(repo)
          repo:write(repo.files.tracked, 'alpha\nbeta second\ngamma\n')
          repo:stage(repo.files.tracked)

          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          ui.open_file(filetree.files.staged[1])
          local diffview = require('glance.diffview')

          A.same(vim.api.nvim_buf_get_lines(diffview.new_buf, 0, -1, false), {
            'alpha',
            'beta second',
            'gamma',
          })

          local before_key = filetree.repo_snapshot_key
          repo:write(repo.files.tracked, 'alpha\nbeta third\ngamma\n')
          repo:stage(repo.files.tracked)
          filetree.refresh()

          A.truthy(ui.diff_open)
          A.not_equal(filetree.repo_snapshot_key, before_key)
          A.same(vim.api.nvim_buf_get_lines(diffview.new_buf, 0, -1, false), {
            'alpha',
            'beta third',
            'gamma',
          })
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
      name = 'workspace helpers include a third content pane without special casing old/new',
      run = function()
        N.with_repo('repo_modified', function()
          local diffview, wins, bufs = open_custom_workspace({
            { role = 'filetree', kind = 'sidebar' },
            { role = 'merge_theirs', kind = 'content' },
            { role = 'merge_ours', kind = 'content' },
            { role = 'merge_result', kind = 'content' },
          }, {
            preferred_focus_role = 'merge_result',
            editable_role = 'merge_result',
          })
          local filetree = require('glance.filetree')

          A.same(diffview.content_roles(), {
            'merge_theirs',
            'merge_ours',
            'merge_result',
          })
          A.same(diffview.content_wins(), {
            wins.merge_theirs,
            wins.merge_ours,
            wins.merge_result,
          })
          A.equal(diffview.editable_buf(), bufs.merge_result)
          A.same(diffview.hoverable_separator_wins(), {
            filetree.win,
            wins.merge_theirs,
            wins.merge_ours,
          })

          vim.api.nvim_set_current_win(wins.merge_theirs)
          A.truthy(diffview.focus_content_pane())
          A.equal(vim.api.nvim_get_current_win(), wins.merge_result)

          local visible_width = vim.api.nvim_win_get_width(wins.merge_theirs)
          filetree.toggle()
          diffview.equalize_panes()
          local hidden_width = vim.api.nvim_win_get_width(wins.merge_theirs)

          A.truthy(hidden_width > visible_width)
        end)
      end,
    },
    {
      name = 'close cleans up every registered content pane in a custom workspace',
      run = function()
        N.with_repo('repo_modified', function()
          local diffview, wins, bufs = open_custom_workspace({
            { role = 'filetree', kind = 'sidebar' },
            { role = 'merge_theirs', kind = 'content' },
            { role = 'merge_ours', kind = 'content' },
            { role = 'merge_result', kind = 'content' },
          }, {
            preferred_focus_role = 'merge_result',
            editable_role = 'merge_result',
          })
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')

          diffview.close(true)

          A.falsy(ui.diff_open)
          A.truthy(filetree.win and vim.api.nvim_win_is_valid(filetree.win))
          A.truthy(ui.welcome_win and vim.api.nvim_win_is_valid(ui.welcome_win))

          for _, win in pairs(wins) do
            A.falsy(vim.api.nvim_win_is_valid(win))
          end
          for _, buf in pairs(bufs) do
            A.falsy(vim.api.nvim_buf_is_valid(buf))
          end
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
      name = 'configured pane navigation aliases move focus across Glance panes',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').setup({
            app = {},
            pane_navigation = {
              left = 'H',
              right = ']',
            },
          })
          require('glance').start()

          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')

          local keymaps = vim.api.nvim_buf_get_keymap(diffview.new_buf, 'n')
          local has_left = false
          local has_right = false
          for _, map in ipairs(keymaps) do
            if map.lhs == 'H' then
              has_left = true
            elseif map.lhs == ']' then
              has_right = true
            end
          end

          vim.api.nvim_set_current_win(diffview.new_win)
          N.press('H')
          A.equal(vim.api.nvim_get_current_win(), diffview.old_win)

          N.press('H')
          A.equal(vim.api.nvim_get_current_win(), filetree.win)

          N.press(']')
          A.equal(vim.api.nvim_get_current_win(), diffview.old_win)

          N.press(']')
          A.equal(vim.api.nvim_get_current_win(), diffview.new_win)

          A.truthy(has_left)
          A.truthy(has_right)
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
      name = 'watch disabled registers CursorHold checktime for in-place reloads',
      run = function()
        N.with_repo('repo_modified', function(repo)
          require('glance').setup({
            app = {
              checktime = true,
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

          A.equal(diffview.fs_watcher, nil)

          local app_autocmds = vim.api.nvim_get_autocmds({
            group = 'GlanceApp',
            event = 'CursorHold',
          })
          A.truthy(#app_autocmds > 0)

          repo:write(repo.files.tracked, 'external change via CursorHold\n')
          vim.wait(1100)
          vim.api.nvim_set_current_win(diffview.new_win)
          vim.cmd('silent! checktime')

          N.wait(500, function()
            local lines = vim.api.nvim_buf_get_lines(diffview.new_buf, 0, -1, false)
            return lines[1] == 'external change via CursorHold'
          end)
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
      name = 'untracked files also reload external edits through the file watcher',
      run = function()
        N.with_repo('repo_untracked', function(repo)
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')

          ui.open_file(filetree.files.untracked[1])
          local diffview = require('glance.diffview')

          A.truthy(diffview.fs_watcher ~= nil)

          repo:write(repo.files.untracked, 'external untracked change\n')
          N.wait(500, function()
            local lines = vim.api.nvim_buf_get_lines(diffview.new_buf, 0, -1, false)
            return lines[1] == 'external untracked change'
          end)
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
