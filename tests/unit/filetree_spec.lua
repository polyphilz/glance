local A = require('tests.helpers.assert')

local function setup_filetree()
  local filetree = require('glance.filetree')
  local buf = filetree.create_buf()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  filetree.win = win
  return filetree
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
          '  discard',
          '  [d] file   [D] all',
          '  drag divider to resize',
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
        A.equal(filetree.selected_line, 6)
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
          '  discard',
          '  [d] file   [D] all',
          '  drag divider to resize',
          '',
          '  Conflicts',
          '    U conflict.txt',
          '',
          '  Changes',
          '    T typed.txt',
        })
        A.equal(filetree.selected_line, 6)
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

        A.equal(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false)[6], '    R old/path.txt → new/path.txt')
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

        A.equal(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false)[6], '    ! conflict.txt')
        A.equal(vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false)[9], '    > copied.txt')
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
          '  discard',
          '  [d] file   [D] all',
          '  drag divider to resize',
          '',
          '  No changes found',
        })
        A.equal(filetree.get_selected_file(), nil)
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
      name = 'repo polling backs off when idle and resets after activity',
      run = function()
        local config = require('glance.config')
        local git = require('glance.git')
        local original_new_timer = vim.uv.new_timer
        local original_new_fs_poll = vim.uv.new_fs_poll
        local original_repo_watch_paths = git.repo_watch_paths
        local timer

        config.setup({
          watch = {
            enabled = true,
            interval_ms = 200,
          },
        })

        local ok, err = xpcall(function()
          vim.uv.new_timer = function()
            timer = {
              starts = {},
            }

            function timer:start(delay, repeat_ms, callback)
              self.starts[#self.starts + 1] = {
                delay = delay,
                repeat_ms = repeat_ms,
              }
              self.delay = delay
              self.repeat_ms = repeat_ms
              self.callback = callback
            end

            function timer:stop()
            end

            function timer:close()
            end

            return timer
          end

          vim.uv.new_fs_poll = function()
            return nil
          end

          git.repo_watch_paths = function()
            return {}
          end

          local filetree = setup_filetree()
          filetree.start_repo_watch()
          A.equal(filetree.repo_poll_delay_ms, 250)
          A.equal(filetree.repo_poll_backoff_index, 1)

          local snapshot = {
            output = '',
            files = {
              conflicts = {},
              staged = {},
              changes = {},
              untracked = {},
            },
          }

          filetree.handle_repo_status_change(snapshot, { source = 'poll' })
          A.equal(filetree.repo_poll_delay_ms, 500)
          A.equal(filetree.repo_poll_backoff_index, 2)

          filetree.handle_repo_status_change(snapshot, { source = 'poll' })
          A.equal(filetree.repo_poll_delay_ms, 1000)
          A.equal(filetree.repo_poll_backoff_index, 3)

          filetree.handle_repo_status_change(snapshot, { source = 'poll' })
          A.equal(filetree.repo_poll_delay_ms, 2000)
          A.equal(filetree.repo_poll_backoff_index, 4)

          filetree.handle_repo_status_change(snapshot, { source = 'poll' })
          A.equal(filetree.repo_poll_delay_ms, 3000)
          A.equal(filetree.repo_poll_backoff_index, 5)

          filetree.handle_repo_status_change(snapshot, { source = 'poll' })
          A.equal(filetree.repo_poll_timer, nil)
          A.equal(filetree.repo_poll_delay_ms, nil)

          filetree.note_repo_activity()
          A.equal(filetree.repo_poll_delay_ms, 250)
          A.equal(filetree.repo_poll_backoff_index, 1)
        end, debug.traceback)

        git.repo_watch_paths = original_repo_watch_paths
        vim.uv.new_fs_poll = original_new_fs_poll
        vim.uv.new_timer = original_new_timer

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'unchanged poll ticks skip watcher resync until explicitly requested',
      run = function()
        local config = require('glance.config')
        local git = require('glance.git')
        local original_new_timer = vim.uv.new_timer
        local original_new_fs_poll = vim.uv.new_fs_poll
        local original_repo_watch_paths = git.repo_watch_paths
        local repo_watch_path_calls = 0

        config.setup({
          watch = {
            enabled = true,
            interval_ms = 200,
          },
        })

        local ok, err = xpcall(function()
          vim.uv.new_timer = function()
            local timer = {}

            function timer:start()
            end

            function timer:stop()
            end

            function timer:close()
            end

            return timer
          end

          vim.uv.new_fs_poll = function()
            return nil
          end

          git.repo_watch_paths = function()
            repo_watch_path_calls = repo_watch_path_calls + 1
            return {}
          end

          local filetree = setup_filetree()
          filetree.start_repo_watch()
          A.equal(repo_watch_path_calls, 1)

          local snapshot = {
            output = '',
            files = {
              conflicts = {},
              staged = {},
              changes = {},
              untracked = {},
            },
          }

          filetree.handle_repo_status_change(snapshot, { source = 'poll' })
          A.equal(repo_watch_path_calls, 1)

          filetree.handle_repo_status_change(snapshot, {
            source = 'focus',
            reset_poll = true,
            resync_watchers = true,
          })
          A.equal(repo_watch_path_calls, 2)
        end, debug.traceback)

        git.repo_watch_paths = original_repo_watch_paths
        vim.uv.new_fs_poll = original_new_fs_poll
        vim.uv.new_timer = original_new_timer

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'scheduled repo refreshes fetch snapshots asynchronously and coalesce in flight requests',
      run = function()
        local git = require('glance.git')
        local filetree = setup_filetree()
        local original_async_snapshot = git.get_status_snapshot_async
        local original_handle = filetree.handle_repo_status_change
        local callbacks = {}
        local fetches = 0
        local handled = {}

        local ok, err = xpcall(function()
          git.get_status_snapshot_async = function(callback)
            fetches = fetches + 1
            callbacks[#callbacks + 1] = callback
          end

          filetree.handle_repo_status_change = function(snapshot, opts)
            handled[#handled + 1] = {
              snapshot = snapshot,
              opts = vim.deepcopy(opts),
            }
          end

          filetree.schedule_repo_refresh({ source = 'poll' })
          vim.wait(100, function()
            return fetches == 1
          end)
          A.equal(fetches, 1)

          filetree.schedule_repo_refresh({
            source = 'watch',
            reset_poll = true,
            resync_watchers = true,
          })
          vim.wait(20)
          A.equal(fetches, 1)

          callbacks[1]({
            key = 'first',
            output = '',
            files = {
              conflicts = {},
              staged = {},
              changes = {},
              untracked = {},
            },
          })

          vim.wait(100, function()
            return fetches == 2 and #handled == 1
          end)
          A.equal(fetches, 2)
          A.equal(handled[1].opts.source, 'poll')

          callbacks[2]({
            key = 'second',
            output = '',
            files = {
              conflicts = {},
              staged = {},
              changes = {},
              untracked = {},
            },
          })

          vim.wait(100, function()
            return #handled == 2
          end)
          A.equal(handled[2].opts.source, 'watch')
          A.truthy(handled[2].opts.reset_poll)
          A.truthy(handled[2].opts.resync_watchers)
        end, debug.traceback)

        filetree.handle_repo_status_change = original_handle
        git.get_status_snapshot_async = original_async_snapshot

        if not ok then
          error(err)
        end
      end,
    },
  },
}
