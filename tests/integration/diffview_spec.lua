local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

local function open_first_changed()
  local filetree = require('glance.filetree')
  local ui = require('glance.ui')
  ui.open_file(filetree.files.staged[1] or filetree.files.changes[1] or filetree.files.untracked[1])
  return require('glance.diffview')
end

local function merge_extmarks(buf)
  local merge_ns = vim.api.nvim_get_namespaces().glance_merge
  return vim.api.nvim_buf_get_extmarks(buf, merge_ns, 0, -1, { details = true })
end

local function has_extmark_detail(marks, key, value)
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details and details[key] == value then
      return true
    end
  end

  return false
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
      name = 'conflicted files open a 3-pane merge inspector with a clean result projection',
      run = function()
        N.with_repo('repo_conflict', function()
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local minimap = require('glance.minimap')
          local workspace = require('glance.workspace')

          ui.open_file(filetree.files.conflicts[1])

          local theirs_win = workspace.get_win(diffview.workspace, 'merge_theirs')
          local ours_win = workspace.get_win(diffview.workspace, 'merge_ours')
          local result_win = workspace.get_win(diffview.workspace, 'merge_result')
          local theirs_buf = workspace.get_buf(diffview.workspace, 'merge_theirs')
          local ours_buf = workspace.get_buf(diffview.workspace, 'merge_ours')
          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')

          A.same(diffview.content_roles(), {
            'merge_theirs',
            'merge_ours',
            'merge_result',
          })
          A.truthy(theirs_win and vim.api.nvim_win_is_valid(theirs_win))
          A.truthy(ours_win and vim.api.nvim_win_is_valid(ours_win))
          A.truthy(result_win and vim.api.nvim_win_is_valid(result_win))
          A.equal(vim.api.nvim_get_option_value('diff', { win = theirs_win }), false)
          A.equal(vim.api.nvim_get_option_value('diff', { win = ours_win }), false)
          A.equal(vim.api.nvim_get_option_value('diff', { win = result_win }), false)
          A.equal(vim.api.nvim_get_option_value('buftype', { buf = theirs_buf }), 'nofile')
          A.equal(vim.api.nvim_get_option_value('readonly', { buf = theirs_buf }), true)
          A.equal(vim.api.nvim_get_option_value('buftype', { buf = ours_buf }), 'nofile')
          A.equal(vim.api.nvim_get_option_value('readonly', { buf = ours_buf }), true)
          A.equal(vim.api.nvim_get_option_value('buftype', { buf = result_buf }), '')
          A.equal(vim.api.nvim_get_option_value('readonly', { buf = result_buf }), false)
          A.equal(vim.api.nvim_get_option_value('modifiable', { buf = result_buf }), true)
          A.truthy(minimap.win and vim.api.nvim_win_is_valid(minimap.win))
          A.equal(minimap.mode, 'merge')
          A.equal(minimap.target_win, result_win)
          A.same(vim.api.nvim_buf_get_lines(theirs_buf, 0, -1, false), { 'feature' })
          A.same(vim.api.nvim_buf_get_lines(ours_buf, 0, -1, false), { 'main' })
          A.same(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), { 'base' })
          A.contains(vim.api.nvim_get_option_value('winbar', { win = theirs_win }), 'Theirs | stage 3 | MERGE_HEAD')
          A.contains(vim.api.nvim_get_option_value('winbar', { win = ours_win }), 'Ours | stage 2 | HEAD')
          local result_winbar = vim.api.nvim_get_option_value('winbar', { win = result_win })
          A.contains(result_winbar, 'Result')
          A.contains(result_winbar, '1/1')
          A.contains(result_winbar, 'unresolved')
          A.contains(result_winbar, '1 unresolved')
          A.equal(vim.api.nvim_get_current_win(), result_win)
          A.equal(vim.api.nvim_win_get_cursor(result_win)[1], 1)
        end)
      end,
    },
    {
      name = 'conflicted file open builds the merge model once',
      run = function()
        N.with_repo('repo_conflict', function()
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local merge_model = require('glance.merge.model')
          local original_build = merge_model.build
          local calls = 0

          merge_model.build = function(...)
            calls = calls + 1
            return original_build(...)
          end

          local ok, err = pcall(function()
            ui.open_file(filetree.files.conflicts[1])
          end)
          merge_model.build = original_build
          if not ok then
            error(err)
          end

          A.equal(calls, 1)
        end)
      end,
    },
    {
      name = 'merge refresh preserves unsaved result edits',
      run = function()
        N.with_repo('repo_conflict', function()
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local workspace = require('glance.workspace')

          ui.open_file(filetree.files.conflicts[1])

          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, {
            'manual draft line 1',
            'manual draft line 2',
          })

          diffview.refresh(filetree.files.conflicts[1])

          A.same(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), {
            'manual draft line 1',
            'manual draft line 2',
          })
          A.equal(vim.api.nvim_get_option_value('modified', { buf = result_buf }), true)
        end)
      end,
    },
    {
      name = 'add/add conflicts stay visible and navigable even when the result projection is empty',
      run = function()
        N.with_repo('repo_conflict_add_add', function()
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local workspace = require('glance.workspace')

          ui.open_file(filetree.files.conflicts[1])

          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          local result_win = workspace.get_win(diffview.workspace, 'merge_result')
          local theirs_win = workspace.get_win(diffview.workspace, 'merge_theirs')
          local marks = merge_extmarks(result_buf)
          local placeholder = ''

          A.truthy(#marks > 0)
          for _, mark in ipairs(marks) do
            if mark[4] and mark[4].virt_lines and mark[4].virt_lines[1] and mark[4].virt_lines[1][1] then
              placeholder = mark[4].virt_lines[1][1][1]
              break
            end
          end

          A.contains(placeholder, 'unresolved')
          A.equal(vim.api.nvim_get_current_win(), result_win)
          A.equal(vim.api.nvim_win_get_cursor(result_win)[1], 1)

          vim.api.nvim_set_current_win(theirs_win)
          N.press(']x')
          A.equal(vim.api.nvim_get_current_win(), result_win)
          A.equal(vim.api.nvim_win_get_cursor(result_win)[1], 1)
        end)
      end,
    },
    {
      name = 'zero-line conflicts stay visible, editable, and resettable without changing semantic state',
      run = function()
        N.with_repo('repo_conflict_zero_line', function(repo)
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local workspace = require('glance.workspace')

          ui.open_file(filetree.files.conflicts[1])

          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          local result_win = workspace.get_win(diffview.workspace, 'merge_result')
          local marks = merge_extmarks(result_buf)
          local placeholder = ''
          local placeholder_above = false

          for _, mark in ipairs(marks) do
            if mark[4] and mark[4].virt_lines and mark[4].virt_lines[1] and mark[4].virt_lines[1][1] then
              placeholder = mark[4].virt_lines[1][1][1]
              placeholder_above = mark[4].virt_lines_above == true
              break
            end
          end

          A.same(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), { 'alpha', 'omega' })
          A.contains(placeholder, 'unresolved')
          A.contains(placeholder, 'insert')
          A.truthy(placeholder_above)
          A.equal(vim.api.nvim_win_get_cursor(result_win)[1], 2)

          vim.api.nvim_buf_set_lines(result_buf, 1, 1, false, { 'draft insert' })
          vim.api.nvim_exec_autocmds('TextChanged', {
            buffer = result_buf,
            modeline = false,
          })

          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), 'manual unresolved')
          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), '1 unresolved')

          N.press('\\r')

          A.same(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), { 'alpha', 'omega' })
          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), 'unresolved')
          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), '1 unresolved')

          vim.api.nvim_buf_call(result_buf, function()
            vim.cmd('write')
          end)

          A.equal(repo:read(repo.files.tracked), table.concat({
            'alpha',
            '<<<<<<< Ours',
            'main insert',
            '||||||| Base',
            '=======',
            'feature insert',
            '>>>>>>> Theirs',
            'omega',
            '',
          }, '\n'))
        end)
      end,
    },
    {
      name = 'merge writes preserve the clean result buffer while persisting unresolved marker form to disk',
      run = function()
        N.with_repo('repo_conflict_multi', function(repo)
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local workspace = require('glance.workspace')

          ui.open_file(filetree.files.conflicts[1])

          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          local result_win = workspace.get_win(diffview.workspace, 'merge_result')
          local expected_result = {
            'intro updated',
            'first main',
            'gap one adjusted',
            'gap two',
            'gap three',
            'second base',
            'outro updated',
          }

          N.press('\\o')

          vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, expected_result)
          vim.api.nvim_buf_call(result_buf, function()
            vim.cmd('write')
          end)

          A.same(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), expected_result)
          A.equal(vim.api.nvim_get_option_value('modified', { buf = result_buf }), false)
          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), '1 unresolved')
          A.equal(repo:read(repo.files.tracked), table.concat({
            'intro updated',
            'first main',
            'gap one adjusted',
            'gap two',
            'gap three',
            '<<<<<<< Ours',
            'second main',
            '||||||| Base',
            'second base',
            '=======',
            'second feature',
            '>>>>>>> Theirs',
            'outro updated',
            '',
          }, '\n'))

          diffview.close(true)
          ui.open_file(filetree.files.conflicts[1])

          local reopened_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          A.same(vim.api.nvim_buf_get_lines(reopened_buf, 0, -1, false), expected_result)
        end)
      end,
    },
    {
      name = 'merge writes preserve no-trailing-newline state',
      run = function()
        N.with_repo('repo_conflict_noeol', function(repo)
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local workspace = require('glance.workspace')

          ui.open_file(filetree.files.conflicts[1])

          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          A.equal(vim.api.nvim_get_option_value('endofline', { buf = result_buf }), false)

          N.press('\\o')
          vim.api.nvim_set_option_value('endofline', false, { buf = result_buf })
          vim.api.nvim_buf_call(result_buf, function()
            vim.cmd('write')
          end)

          A.equal(repo:read(repo.files.tracked), 'main')
          A.equal(vim.api.nvim_get_option_value('endofline', { buf = result_buf }), false)
        end)
      end,
    },
    {
      name = 'merge writes persist a fully resolved clean result without conflict markers',
      run = function()
        N.with_repo('repo_conflict', function(repo)
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local workspace = require('glance.workspace')

          ui.open_file(filetree.files.conflicts[1])

          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          local result_win = workspace.get_win(diffview.workspace, 'merge_result')

          N.press('\\o')

          vim.api.nvim_buf_call(result_buf, function()
            vim.cmd('write')
          end)

          A.same(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), { 'main' })
          A.equal(vim.api.nvim_get_option_value('modified', { buf = result_buf }), false)
          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), '0 unresolved')
          A.equal(repo:read(repo.files.tracked), 'main\n')

          diffview.close(true)
          ui.open_file(filetree.files.conflicts[1])

          local reopened_win = workspace.get_win(diffview.workspace, 'merge_result')
          A.contains(vim.api.nvim_get_option_value('winbar', { win = reopened_win }), 'manual resolved')
          A.contains(vim.api.nvim_get_option_value('winbar', { win = reopened_win }), '0 unresolved')
        end)
      end,
    },
    {
      name = 'merge writes fail closed for unresolved manual result edits that cannot be serialized safely',
      run = function()
        N.with_repo('repo_conflict', function(repo)
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local workspace = require('glance.workspace')
          local messages, restore_notify = N.capture_notifications()

          ui.open_file(filetree.files.conflicts[1])

          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, {
            'custom unresolved draft',
            'with extra context',
          })

          vim.api.nvim_buf_call(result_buf, function()
            vim.cmd('write')
          end)

          restore_notify()

          local warned = false
          for _, entry in ipairs(messages) do
            if entry.msg:find('cannot safely', 1, true) then
              warned = true
              break
            end
          end

          A.truthy(warned)
          A.equal(vim.api.nvim_get_option_value('modified', { buf = result_buf }), true)
          A.truthy(repo:read(repo.files.tracked):match('^<<<<<<<') ~= nil)
        end)
      end,
    },
    {
      name = 'merge conflict navigation keymaps move through unresolved conflicts in the result pane',
      run = function()
        N.with_repo('repo_conflict_multi', function()
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local workspace = require('glance.workspace')

          ui.open_file(filetree.files.conflicts[1])

          local theirs_win = workspace.get_win(diffview.workspace, 'merge_theirs')
          local result_win = workspace.get_win(diffview.workspace, 'merge_result')
          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')

          A.same(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), {
            'intro',
            'first base',
            'gap one',
            'gap two',
            'gap three',
            'second base',
            'outro',
          })
          A.equal(vim.api.nvim_get_current_win(), result_win)
          A.equal(vim.api.nvim_win_get_cursor(result_win)[1], 2)
          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), '1/2')

          vim.api.nvim_set_current_win(theirs_win)
          N.press(']x')
          A.equal(vim.api.nvim_get_current_win(), result_win)
          A.equal(vim.api.nvim_win_get_cursor(result_win)[1], 6)
          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), '2/2')

          N.press(']x')
          A.equal(vim.api.nvim_win_get_cursor(result_win)[1], 2)
          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), '1/2')

          N.press('[x')
          A.equal(vim.api.nvim_win_get_cursor(result_win)[1], 6)
          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), '2/2')
        end)
      end,
    },
    {
      name = 'merge minimap renders conflict states and active conflict changes',
      run = function()
        N.with_repo('repo_conflict_multi', function()
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local minimap = require('glance.minimap')
          local logic = require('glance.minimap_logic')
          local workspace = require('glance.workspace')

          ui.open_file(filetree.files.conflicts[1])

          local result_win = workspace.get_win(diffview.workspace, 'merge_result')
          A.truthy(minimap.win and vim.api.nvim_win_is_valid(minimap.win))
          A.equal(minimap.mode, 'merge')
          A.equal(minimap.target_win, result_win)
          A.contains(minimap.cached_pixels, logic.states.MERGE_ACTIVE)
          A.contains(minimap.cached_pixels, logic.states.MERGE_UNRESOLVED)

          N.press('\\o')
          N.press(']x')

          A.contains(minimap.cached_pixels, logic.states.MERGE_HANDLED)
          A.contains(minimap.cached_pixels, logic.states.MERGE_ACTIVE)
        end)
      end,
    },
    {
      name = 'merge minimap renders manual conflict state before explicit resolution',
      run = function()
        N.with_repo('repo_conflict_multi', function()
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local minimap = require('glance.minimap')
          local logic = require('glance.minimap_logic')
          local workspace = require('glance.workspace')

          ui.open_file(filetree.files.conflicts[1])

          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          vim.api.nvim_buf_set_lines(result_buf, 1, 2, false, { 'manual first resolution' })
          vim.api.nvim_exec_autocmds('TextChanged', {
            buffer = result_buf,
            modeline = false,
          })

          N.press(']x')
          A.contains(minimap.cached_pixels, logic.states.MERGE_MANUAL)
          A.contains(minimap.cached_pixels, logic.states.MERGE_ACTIVE)

          N.press('[x')
          N.press('\\m')
          N.press(']x')

          A.contains(minimap.cached_pixels, logic.states.MERGE_HANDLED)
          A.contains(minimap.cached_pixels, logic.states.MERGE_ACTIVE)
        end)
      end,
    },
    {
      name = 'merge action bar renders configured keys and accept ours resolves immediately',
      run = function()
        N.with_repo('repo_conflict', function(repo)
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local workspace = require('glance.workspace')

          ui.open_file(filetree.files.conflicts[1])

          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          local result_win = workspace.get_win(diffview.workspace, 'merge_result')
          local marks = merge_extmarks(result_buf)

          local winbar = vim.api.nvim_get_option_value('winbar', { win = result_win })
          A.truthy(has_extmark_detail(marks, 'line_hl_group', 'GlanceConflictStateUnresolved'))
          A.truthy(has_extmark_detail(marks, 'number_hl_group', 'GlanceConflictActiveNumber'))
          A.contains(winbar, '1/1')
          A.contains(winbar, 'unresolved')
          A.contains(winbar, '\\o ours')
          A.contains(winbar, '\\t theirs')
          A.contains(winbar, '\\O both o/t')
          A.contains(winbar, '\\T both t/o')
          A.contains(winbar, '\\b base')

          N.press('\\o')

          A.same(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), { 'main' })
          winbar = vim.api.nvim_get_option_value('winbar', { win = result_win })
          A.contains(winbar, 'handled: ours')
          A.contains(winbar, '0 unresolved')

          vim.api.nvim_buf_call(result_buf, function()
            vim.cmd('write')
          end)

          A.equal(repo:read(repo.files.tracked), 'main\n')

          diffview.close(true)
          ui.open_file(filetree.files.conflicts[1])

          local reopened_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          local reopened_win = workspace.get_win(diffview.workspace, 'merge_result')
          A.same(vim.api.nvim_buf_get_lines(reopened_buf, 0, -1, false), { 'main' })
          winbar = vim.api.nvim_get_option_value('winbar', { win = reopened_win })
          A.contains(winbar, 'manual resolved')
          A.contains(winbar, '0 unresolved')
        end)
      end,
    },
    {
      name = 'merge actions can fully resolve a conflict without dropping to raw markers',
      run = function()
        N.with_repo('repo_conflict', function(repo)
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local workspace = require('glance.workspace')

          ui.open_file(filetree.files.conflicts[1])

          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          local result_win = workspace.get_win(diffview.workspace, 'merge_result')

          N.press('\\o')

          A.same(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), { 'main' })
          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), '0 unresolved')

          vim.api.nvim_buf_call(result_buf, function()
            vim.cmd('write')
          end)

          A.equal(repo:read(repo.files.tracked), 'main\n')
        end)
      end,
    },
    {
      name = 'manual result edits can be explicitly marked resolved and reopen cleanly',
      run = function()
        N.with_repo('repo_conflict', function(repo)
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local workspace = require('glance.workspace')

          ui.open_file(filetree.files.conflicts[1])

          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          local result_win = workspace.get_win(diffview.workspace, 'merge_result')

          vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, { 'custom merge draft' })
          vim.api.nvim_exec_autocmds('TextChanged', {
            buffer = result_buf,
            modeline = false,
          })

          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), '1 unresolved')

          N.press('\\m')

          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), 'manual resolved')
          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), '0 unresolved')

          vim.api.nvim_buf_call(result_buf, function()
            vim.cmd('write')
          end)

          A.equal(repo:read(repo.files.tracked), 'custom merge draft\n')

          diffview.close(true)
          ui.open_file(filetree.files.conflicts[1])

          local reopened_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          local reopened_win = workspace.get_win(diffview.workspace, 'merge_result')
          A.same(vim.api.nvim_buf_get_lines(reopened_buf, 0, -1, false), { 'custom merge draft' })
          A.contains(vim.api.nvim_get_option_value('winbar', { win = reopened_win }), 'manual resolved')
          A.contains(vim.api.nvim_get_option_value('winbar', { win = reopened_win }), '0 unresolved')
        end)
      end,
    },
    {
      name = 'merge accept-all and reset-result operate on the whole result buffer',
      run = function()
        N.with_repo('repo_conflict_multi', function()
          require('glance').start()
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local workspace = require('glance.workspace')

          ui.open_file(filetree.files.conflicts[1])

          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          local result_win = workspace.get_win(diffview.workspace, 'merge_result')

          N.press('\\ao')

          A.same(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), {
            'intro',
            'first main',
            'gap one',
            'gap two',
            'gap three',
            'second main',
            'outro',
          })
          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), '0 unresolved')
          A.equal(vim.api.nvim_get_option_value('modified', { buf = result_buf }), true)

          N.with_confirm(1, function()
            N.press('\\R')
          end)

          A.same(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), {
            'intro',
            'first base',
            'gap one',
            'gap two',
            'gap three',
            'second base',
            'outro',
          })
          A.contains(vim.api.nvim_get_option_value('winbar', { win = result_win }), '2 unresolved')
          A.equal(vim.api.nvim_get_option_value('modified', { buf = result_buf }), true)
        end)
      end,
    },
    {
      name = 'accept all ours can complete a merge with no visible staged diff',
      run = function()
        N.with_repo('repo_conflict_multi', function()
          require('glance').start()
          local git = require('glance.git')
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local messages, restore_notify = N.capture_notifications()

          ui.open_file(filetree.files.conflicts[1])
          N.press('\\ao')
          N.press('\\c')
          restore_notify()

          local changed = git.get_changed_files()
          A.falsy(ui.diff_open)
          A.equal(git.get_operation_context().kind, 'merge')
          A.equal(#(changed.conflicts or {}), 0)
          A.equal(#(changed.staged or {}), 0)
          A.equal(#(changed.changes or {}), 0)
          local lines = vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false)
          A.equal(lines[#lines - 1], '  Merge ready to complete')
          A.equal(lines[#lines], '  Press c to commit the merge')

          local notified = false
          for _, entry in ipairs(messages) do
            if entry.msg == 'glance: all merge conflicts are resolved; press c to commit the merge' then
              notified = true
              break
            end
          end
          A.truthy(notified)
        end)
      end,
    },
    {
      name = 'complete merge stages the resolved file and returns to the filetree',
      run = function()
        N.with_repo('repo_conflict_two_files', function(repo)
          require('glance').start()
          local git = require('glance.git')
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')

          A.equal(#filetree.files.conflicts, 2)
          local first = filetree.files.conflicts[1]
          ui.open_file(first)

          N.press('\\t')
          N.press('\\c')

          local changed = git.get_changed_files()
          A.falsy(ui.diff_open)
          A.equal(vim.api.nvim_get_current_win(), filetree.win)
          A.equal(#changed.conflicts, 1)
          A.equal(changed.conflicts[1].path, repo.files.second)
          A.equal(#changed.staged, 1)
          A.equal(changed.staged[1].path, first.path)
          A.equal(repo:read(first.path), 'first feature\n')
        end)
      end,
    },
    {
      name = 'complete merge refuses unresolved conflicts and manual edits that are not marked resolved',
      run = function()
        N.with_repo('repo_conflict', function()
          require('glance').start()
          local git = require('glance.git')
          local ui = require('glance.ui')
          local filetree = require('glance.filetree')
          local diffview = require('glance.diffview')
          local workspace = require('glance.workspace')
          local messages, restore_notify = N.capture_notifications()

          ui.open_file(filetree.files.conflicts[1])
          N.press('\\c')

          local warned_unresolved = false
          for _, entry in ipairs(messages) do
            if entry.msg:find('unresolved conflict', 1, true) then
              warned_unresolved = true
              break
            end
          end

          A.truthy(warned_unresolved)
          A.truthy(ui.diff_open)
          A.equal(#git.get_changed_files().conflicts, 1)

          local result_buf = workspace.get_buf(diffview.workspace, 'merge_result')
          vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, { 'manual draft' })
          vim.api.nvim_exec_autocmds('TextChanged', {
            buffer = result_buf,
            modeline = false,
          })
          N.press('\\c')

          restore_notify()

          local warned_manual = false
          for _, entry in ipairs(messages) do
            if entry.msg:find('mark 1 manual conflict resolved first', 1, true) then
              warned_manual = true
              break
            end
          end

          A.truthy(warned_manual)
          A.truthy(ui.diff_open)
          A.equal(#git.get_changed_files().conflicts, 1)
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
