local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

local function setup_filetree()
  local filetree = require('glance.filetree')
  local buf = filetree.create_buf()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  filetree.win = win
  return filetree
end

local function snapshot(files, opts)
  opts = opts or {}
  return {
    head_oid = opts.head_oid,
    key = opts.key or '',
    output = opts.output or '',
    files = files or {
      conflicts = {},
      staged = {},
      changes = {},
      untracked = {},
    },
  }
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
          '  actions',
          '  [s] stage   [S] stage all',
          '  [u] unstage [U] unstage all',
          '  [d] discard [D] discard all',
          '  [c] commit staged changes',
          '  [L] browse commit history',
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
        A.equal(filetree.selected_line, 9)
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
          '  actions',
          '  [s] stage   [S] stage all',
          '  [u] unstage [U] unstage all',
          '  [d] discard [D] discard all',
          '  [c] commit staged changes',
          '  [L] browse commit history',
          '',
          '  Conflicts',
          '    U conflict.txt',
          '',
          '  Changes',
          '    T typed.txt',
        })
        A.equal(filetree.selected_line, 9)
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

        A.equal(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false)[9], '    R old/path.txt → new/path.txt')
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

        A.equal(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false)[9], '    ! conflict.txt')
        A.equal(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false)[12], '    > copied.txt')
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
          '  actions',
          '  [s] stage   [S] stage all',
          '  [u] unstage [U] unstage all',
          '  [d] discard [D] discard all',
          '  [c] commit staged changes',
          '  [L] browse commit history',
          '',
          '  No changes found',
        })
        A.equal(filetree.get_selected_file(), nil)
        A.equal(vim.api.nvim_get_option_value('cursorline', { win = filetree.win }), false)
        A.same(vim.api.nvim_win_get_cursor(filetree.win), { 8, 4 })
      end,
    },
    {
      name = 'render shows merge-ready state when a merge has no visible changes',
      run = function()
        local filetree = setup_filetree()
        filetree.render({
          conflicts = {},
          staged = {},
          changes = {},
          untracked = {},
        }, {
          operation_context = { kind = 'merge' },
        })

        A.same(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false), {
          '  actions',
          '  [s] stage   [S] stage all',
          '  [u] unstage [U] unstage all',
          '  [d] discard [D] discard all',
          '  [c] commit merge',
          '  [L] browse commit history',
          '',
          '  Merge ready to complete',
          '  Press c to commit the merge',
        })
        A.equal(filetree.get_selected_file(), nil)
        A.equal(vim.api.nvim_get_option_value('cursorline', { win = filetree.win }), false)
      end,
    },
    {
      name = 'render restores cursorline when files return',
      run = function()
        local filetree = setup_filetree()

        filetree.render({
          staged = {},
          changes = {},
          untracked = {},
        })
        A.equal(vim.api.nvim_get_option_value('cursorline', { win = filetree.win }), false)

        filetree.render({
          changes = {
            { path = 'changed.txt', status = 'M', section = 'changes' },
          },
        })

        A.equal(vim.api.nvim_get_option_value('cursorline', { win = filetree.win }), true)
      end,
    },
    {
      name = 'render can hide the legend via config',
      run = function()
        local config = require('glance.config')
        config.setup({
          filetree = {
            show_legend = false,
          },
        })

        local filetree = setup_filetree()
        filetree.render({
          changes = {
            { path = 'changed.txt', status = 'D', section = 'changes' },
          },
        })

        A.same(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false), {
          '  Changes',
          '    D changed.txt',
        })
        A.equal(filetree.selected_line, 2)
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
    {
      name = 'render legend includes the log action',
      run = function()
        local filetree = setup_filetree()
        filetree.render({
          changes = {
            { path = 'changed.txt', status = 'M', section = 'changes' },
          },
        })

        A.contains(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false), '  [L] browse commit history')
      end,
    },
    {
      name = 'open commit editor warns when there are no staged changes',
      run = function()
        local commit_editor = require('glance.commit_editor')
        local git = require('glance.git')
        local filetree = setup_filetree()
        local messages, restore = N.capture_notifications()
        local original_open = commit_editor.open
        local open_called = false

        local ok, err = xpcall(function()
          filetree.render({
            changes = {
              { path = 'changed.txt', status = 'M', section = 'changes' },
            },
          })

          commit_editor.open = function()
            open_called = true
          end

          filetree.open_commit_editor()

          A.falsy(open_called)
          A.equal(messages[1].msg, git.NO_STAGED_COMMIT_MESSAGE)
          A.equal(messages[1].level, vim.log.levels.WARN)
        end, debug.traceback)

        restore()
        commit_editor.open = original_open

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'open commit editor reuses an existing editor by focusing it',
      run = function()
        local commit_editor = require('glance.commit_editor')
        local filetree = setup_filetree()
        local original_is_open = commit_editor.is_open
        local original_focus = commit_editor.focus
        local original_open = commit_editor.open
        local focus_called = false
        local open_called = false

        local ok, err = xpcall(function()
          filetree.render({
            staged = {
              { path = 'staged.txt', status = 'M', section = 'staged' },
            },
          })

          commit_editor.is_open = function()
            return true
          end
          commit_editor.focus = function()
            focus_called = true
          end
          commit_editor.open = function()
            open_called = true
          end

          filetree.open_commit_editor()

          A.truthy(focus_called)
          A.falsy(open_called)
        end, debug.traceback)

        commit_editor.is_open = original_is_open
        commit_editor.focus = original_focus
        commit_editor.open = original_open

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'open log view reuses an existing modal by focusing it',
      run = function()
        local filetree = setup_filetree()
        local log_view = require('glance.log_view')
        local original_is_open = log_view.is_open
        local original_focus = log_view.focus
        local original_open = log_view.open
        local focus_called = false
        local open_called = false

        local ok, err = xpcall(function()
          log_view.is_open = function()
            return true
          end
          log_view.focus = function()
            focus_called = true
          end
          log_view.open = function()
            open_called = true
          end

          filetree.open_log_view()

          A.truthy(focus_called)
          A.falsy(open_called)
        end, debug.traceback)

        log_view.is_open = original_is_open
        log_view.focus = original_focus
        log_view.open = original_open

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'successful commit closes the editor and refreshes once without an open diff',
      run = function()
        local commit_editor = require('glance.commit_editor')
        local git = require('glance.git')
        local filetree = setup_filetree()
        local ui = require('glance.ui')
        local original_open = commit_editor.open
        local original_get_status_snapshot = git.get_status_snapshot
        local original_can_commit = git.can_commit
        local original_commit = git.commit
        local original_refresh = filetree.refresh
        local submit
        local commit_message
        local refresh_calls = 0

        local ok, err = xpcall(function()
          filetree.render({
            staged = {
              { path = 'staged.txt', status = 'M', section = 'staged' },
            },
          })

          commit_editor.open = function(opts)
            submit = opts.on_submit
          end
          git.get_status_snapshot = function()
            return snapshot({
              staged = {
                { path = 'staged.txt', status = 'M', section = 'staged' },
              },
            }, {
              key = 'submit',
            })
          end
          git.can_commit = function()
            return true
          end
          git.commit = function(message_lines)
            commit_message = message_lines
            return true
          end
          filetree.refresh = function()
            refresh_calls = refresh_calls + 1
          end

          ui.diff_open = false
          filetree.open_commit_editor()
          submit({ 'Subject', '', 'Body' })

          A.same(commit_message, { 'Subject', '', 'Body' })
          A.equal(refresh_calls, 1)
        end, debug.traceback)

        commit_editor.open = original_open
        git.get_status_snapshot = original_get_status_snapshot
        git.can_commit = original_can_commit
        git.commit = original_commit
        filetree.refresh = original_refresh
        ui.diff_open = false

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'successful commit closes any open diff without double-refreshing',
      run = function()
        local commit_editor = require('glance.commit_editor')
        local diffview = require('glance.diffview')
        local git = require('glance.git')
        local filetree = setup_filetree()
        local ui = require('glance.ui')
        local original_open = commit_editor.open
        local original_diff_close = diffview.close
        local original_get_status_snapshot = git.get_status_snapshot
        local original_can_commit = git.can_commit
        local original_commit = git.commit
        local original_refresh = filetree.refresh
        local submit
        local diff_close_force
        local refresh_calls = 0

        local ok, err = xpcall(function()
          filetree.render({
            staged = {
              { path = 'staged.txt', status = 'M', section = 'staged' },
            },
          })

          commit_editor.open = function(opts)
            submit = opts.on_submit
          end
          diffview.close = function(force)
            diff_close_force = force
            ui.diff_open = false
          end
          git.get_status_snapshot = function()
            return snapshot({
              staged = {
                { path = 'staged.txt', status = 'M', section = 'staged' },
              },
            }, {
              key = 'submit',
            })
          end
          git.can_commit = function()
            return true
          end
          git.commit = function()
            return true
          end
          filetree.refresh = function()
            refresh_calls = refresh_calls + 1
          end

          ui.diff_open = true
          filetree.open_commit_editor()
          submit({ 'Subject' })

          A.equal(diff_close_force, false)
          A.equal(refresh_calls, 0)
        end, debug.traceback)

        commit_editor.open = original_open
        diffview.close = original_diff_close
        git.get_status_snapshot = original_get_status_snapshot
        git.can_commit = original_can_commit
        git.commit = original_commit
        filetree.refresh = original_refresh
        ui.diff_open = false

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'successful commit keeps an open diff and refreshes when diff close is aborted',
      run = function()
        local commit_editor = require('glance.commit_editor')
        local diffview = require('glance.diffview')
        local git = require('glance.git')
        local filetree = setup_filetree()
        local ui = require('glance.ui')
        local original_open = commit_editor.open
        local original_diff_close = diffview.close
        local original_get_status_snapshot = git.get_status_snapshot
        local original_can_commit = git.can_commit
        local original_commit = git.commit
        local original_refresh = filetree.refresh
        local submit
        local diff_close_force
        local refresh_calls = 0

        local ok, err = xpcall(function()
          filetree.render({
            staged = {
              { path = 'staged.txt', status = 'M', section = 'staged' },
            },
          })

          commit_editor.open = function(opts)
            submit = opts.on_submit
          end
          diffview.close = function(force)
            diff_close_force = force
          end
          git.get_status_snapshot = function()
            return snapshot({
              staged = {},
              changes = {
                { path = 'staged.txt', status = 'M', section = 'changes' },
              },
            }, {
              key = 'submit',
            })
          end
          git.can_commit = function()
            return true
          end
          git.commit = function()
            return true
          end
          filetree.refresh = function()
            refresh_calls = refresh_calls + 1
          end

          ui.diff_open = true
          filetree.open_commit_editor()
          submit({ 'Subject' })

          A.equal(diff_close_force, false)
          A.equal(refresh_calls, 1)
          A.truthy(ui.diff_open)
        end, debug.traceback)

        commit_editor.open = original_open
        diffview.close = original_diff_close
        git.get_status_snapshot = original_get_status_snapshot
        git.can_commit = original_can_commit
        git.commit = original_commit
        filetree.refresh = original_refresh
        ui.diff_open = false

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'failed commit keeps the editor open and reports the git error',
      run = function()
        local commit_editor = require('glance.commit_editor')
        local git = require('glance.git')
        local filetree = setup_filetree()
        local messages, restore = N.capture_notifications()
        local original_open = commit_editor.open
        local original_get_status_snapshot = git.get_status_snapshot
        local original_can_commit = git.can_commit
        local original_commit = git.commit
        local original_refresh = filetree.refresh
        local submit
        local refresh_called = false

        local ok, err = xpcall(function()
          filetree.render({
            staged = {
              { path = 'staged.txt', status = 'M', section = 'staged' },
            },
          })

          commit_editor.open = function(opts)
            submit = opts.on_submit
          end
          git.get_status_snapshot = function()
            return snapshot({
              staged = {
                { path = 'staged.txt', status = 'M', section = 'staged' },
              },
            }, {
              key = 'submit',
            })
          end
          git.can_commit = function()
            return true
          end
          git.commit = function()
            return false, 'hook rejected'
          end
          filetree.refresh = function()
            refresh_called = true
          end

          filetree.open_commit_editor()
          submit({ 'Subject' })

          A.falsy(refresh_called)
          A.equal(messages[1].msg, 'glance: failed to commit staged changes: hook rejected')
          A.equal(messages[1].level, vim.log.levels.ERROR)
        end, debug.traceback)

        restore()
        commit_editor.open = original_open
        git.get_status_snapshot = original_get_status_snapshot
        git.can_commit = original_can_commit
        git.commit = original_commit
        filetree.refresh = original_refresh

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'stage selected file calls git stage and refreshes',
      run = function()
        local git = require('glance.git')
        local filetree = setup_filetree()
        local original_can_stage_file = git.can_stage_file
        local original_stage_file = git.stage_file
        local original_refresh = filetree.refresh
        local validated, staged, refreshed

        local ok, err = xpcall(function()
          filetree.render({
            changes = {
              { path = 'changed.txt', status = 'M', section = 'changes' },
            },
          })

          git.can_stage_file = function(file)
            validated = file
            return true
          end
          git.stage_file = function(file)
            staged = file
            return true
          end
          filetree.refresh = function()
            refreshed = true
          end

          filetree.stage_selected_file()

          A.equal(validated.path, 'changed.txt')
          A.equal(staged.path, 'changed.txt')
          A.truthy(refreshed)
        end, debug.traceback)

        git.can_stage_file = original_can_stage_file
        git.stage_file = original_stage_file
        filetree.refresh = original_refresh

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'selected stage only closes the active diff when it targets the same path',
      run = function()
        local git = require('glance.git')
        local diffview = require('glance.diffview')
        local ui = require('glance.ui')
        local filetree = setup_filetree()
        local original_can_stage_file = git.can_stage_file
        local original_stage_file = git.stage_file
        local original_refresh = filetree.refresh
        local original_close = diffview.close
        local close_calls = 0

        local ok, err = xpcall(function()
          filetree.render({
            changes = {
              { path = 'changed.txt', status = 'M', section = 'changes' },
            },
          })

          git.can_stage_file = function()
            return true
          end
          git.stage_file = function()
            return true
          end
          filetree.refresh = function() end
          diffview.close = function(force)
            close_calls = close_calls + (force and 1 or 0)
          end

          ui.diff_open = true
          filetree.active_file = {
            path = 'changed.txt',
            section = 'changes',
          }
          filetree.stage_selected_file()
          A.equal(close_calls, 1)

          filetree.active_file = {
            path = 'other.txt',
            section = 'changes',
          }
          filetree.stage_selected_file()
          A.equal(close_calls, 1)
        end, debug.traceback)

        git.can_stage_file = original_can_stage_file
        git.stage_file = original_stage_file
        filetree.refresh = original_refresh
        diffview.close = original_close
        ui.diff_open = false

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'unstage selected file warns on invalid targets without mutating or refreshing',
      run = function()
        local git = require('glance.git')
        local filetree = setup_filetree()
        local original_can_unstage_file = git.can_unstage_file
        local original_unstage_file = git.unstage_file
        local original_refresh = filetree.refresh
        local messages, restore = N.capture_notifications()
        local unstage_called = false
        local refresh_called = false

        local ok, err = xpcall(function()
          filetree.render({
            changes = {
              { path = 'changed.txt', status = 'M', section = 'changes' },
            },
          })

          git.can_unstage_file = function()
            return false, git.INVALID_UNSTAGE_TARGET_MESSAGE
          end
          git.unstage_file = function()
            unstage_called = true
            return true
          end
          filetree.refresh = function()
            refresh_called = true
          end

          filetree.unstage_selected_file()

          A.falsy(unstage_called)
          A.falsy(refresh_called)
          A.equal(messages[1].msg, git.INVALID_UNSTAGE_TARGET_MESSAGE)
          A.equal(messages[1].level, vim.log.levels.WARN)
        end, debug.traceback)

        restore()
        git.can_unstage_file = original_can_unstage_file
        git.unstage_file = original_unstage_file
        filetree.refresh = original_refresh

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'repo-wide stage and unstage close any open diff and refresh',
      run = function()
        local git = require('glance.git')
        local diffview = require('glance.diffview')
        local ui = require('glance.ui')
        local filetree = setup_filetree()
        local original_can_stage_all = git.can_stage_all
        local original_stage_all = git.stage_all
        local original_can_unstage_all = git.can_unstage_all
        local original_unstage_all = git.unstage_all
        local original_refresh = filetree.refresh
        local original_close = diffview.close
        local stage_all_arg, unstage_all_arg
        local refresh_calls = 0
        local close_calls = 0

        local ok, err = xpcall(function()
          filetree.render({
            staged = {
              { path = 'staged.txt', status = 'M', section = 'staged' },
            },
            changes = {
              { path = 'changed.txt', status = 'M', section = 'changes' },
            },
          })

          git.can_stage_all = function(files)
            return true
          end
          git.stage_all = function(files)
            stage_all_arg = files
            return true
          end
          git.can_unstage_all = function(files)
            return true
          end
          git.unstage_all = function(files)
            unstage_all_arg = files
            return true
          end
          filetree.refresh = function()
            refresh_calls = refresh_calls + 1
          end
          diffview.close = function(force)
            close_calls = close_calls + (force and 1 or 0)
          end

          ui.diff_open = true
          filetree.stage_all()
          filetree.unstage_all()

          A.equal(stage_all_arg, filetree.files)
          A.equal(unstage_all_arg, filetree.files)
          A.equal(close_calls, 2)
          A.equal(refresh_calls, 2)
        end, debug.traceback)

        git.can_stage_all = original_can_stage_all
        git.stage_all = original_stage_all
        git.can_unstage_all = original_can_unstage_all
        git.unstage_all = original_unstage_all
        filetree.refresh = original_refresh
        diffview.close = original_close
        ui.diff_open = false

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'staged diff refreshes in place when only HEAD changes',
      run = function()
        local diffview = require('glance.diffview')
        local ui = require('glance.ui')
        local original_refresh = diffview.refresh
        local refreshed

        local ok, err = xpcall(function()
          diffview.refresh = function(file)
            refreshed = file
          end

          local filetree = setup_filetree()
          local before = {
            path = 'tracked.txt',
            status = 'M',
            raw_status = 'M ',
            section = 'staged',
          }
          filetree.apply_status_snapshot(snapshot({
            conflicts = {},
            staged = { before },
            changes = {},
            untracked = {},
          }, {
            head_oid = 'head-1',
            key = 'first',
          }))
          filetree.active_file = before
          ui.diff_open = true

          filetree.handle_repo_status_change(snapshot({
            conflicts = {},
            staged = {
              {
                path = 'tracked.txt',
                status = 'M',
                raw_status = 'M ',
                section = 'staged',
              },
            },
            changes = {},
            untracked = {},
          }, {
            head_oid = 'head-2',
            key = 'second',
          }))

          A.equal(refreshed.path, 'tracked.txt')
          A.equal(refreshed.section, 'staged')
        end, debug.traceback)

        diffview.refresh = original_refresh
        ui.diff_open = false

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'stale diff closes when the active file disappears and the buffer is clean',
      run = function()
        local diffview = require('glance.diffview')
        local ui = require('glance.ui')
        local original_close = diffview.close
        local close_called

        local ok, err = xpcall(function()
          diffview.close = function(force)
            close_called = force
          end

          local filetree = setup_filetree()
          local before = {
            path = 'tracked.txt',
            status = 'M',
            raw_status = ' M',
            section = 'changes',
          }
          filetree.apply_status_snapshot(snapshot({
            conflicts = {},
            staged = {},
            changes = { before },
            untracked = {},
          }, {
            key = 'first',
          }))
          filetree.active_file = before
          ui.diff_open = true
          diffview.new_buf = vim.api.nvim_create_buf(true, false)

          filetree.handle_repo_status_change(snapshot({
            conflicts = {},
            staged = {},
            changes = {},
            untracked = {},
          }, {
            key = 'second',
          }))

          A.equal(close_called, false)
        end, debug.traceback)

        diffview.close = original_close
        diffview.new_buf = nil
        ui.diff_open = false

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'stale diff stays open when the active buffer has unsaved edits',
      run = function()
        local diffview = require('glance.diffview')
        local ui = require('glance.ui')
        local original_close = diffview.close
        local messages, restore = N.capture_notifications()
        local close_called = false

        local ok, err = xpcall(function()
          diffview.close = function()
            close_called = true
          end

          local filetree = setup_filetree()
          local before = {
            path = 'tracked.txt',
            status = 'M',
            raw_status = ' M',
            section = 'changes',
          }
          filetree.apply_status_snapshot(snapshot({
            conflicts = {},
            staged = {},
            changes = { before },
            untracked = {},
          }, {
            key = 'first',
          }))
          filetree.active_file = before
          ui.diff_open = true

          diffview.new_buf = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_buf_set_lines(diffview.new_buf, 0, -1, false, { 'unsaved edit' })

          filetree.handle_repo_status_change(snapshot({
            conflicts = {},
            staged = {},
            changes = {},
            untracked = {},
          }, {
            key = 'second',
          }))

          A.falsy(close_called)
          A.equal(filetree.active_file, nil)
          A.equal(messages[1].level, vim.log.levels.WARN)
          A.contains(messages[1].msg, 'keeping the current buffer open because it has unsaved edits')
        end, debug.traceback)

        restore()
        diffview.close = original_close
        diffview.new_buf = nil
        ui.diff_open = false

        if not ok then
          error(err)
        end
      end,
    },
  },
}
