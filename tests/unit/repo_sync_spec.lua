local A = require('tests.helpers.assert')

local function start_repo_sync(opts)
  local repo_sync = require('glance.repo_sync')
  repo_sync.start(vim.tbl_extend('force', {
    root = '/tmp/glance-test-repo',
    get_current_snapshot_key = function()
      return ''
    end,
    on_snapshot = function()
    end,
    is_active = function()
      return true
    end,
  }, opts or {}))
  return repo_sync
end

local function empty_snapshot(key)
  return {
    key = key or '',
    output = '',
    files = {
      conflicts = {},
      staged = {},
      changes = {},
      untracked = {},
    },
  }
end

return {
  name = 'repo-sync-unit',
  cases = {
    {
      name = 'repo polling backs off when idle, keeps polling at max delay, and resets after activity',
      run = function()
        local config = require('glance.config')
        local git = require('glance.git')
        local repo_sync = require('glance.repo_sync')
        local original_async_snapshot = git.get_status_snapshot_async
        local original_new_timer = vim.uv.new_timer
        local original_new_fs_poll = vim.uv.new_fs_poll
        local original_repo_watch_paths = git.repo_watch_paths
        local timers = {}

        config.setup({
          watch = {
            enabled = true,
            poll = true,
            interval_ms = 200,
          },
        })

        local ok, err = xpcall(function()
          git.get_status_snapshot_async = function(callback)
            callback(empty_snapshot(''))
          end

          vim.uv.new_timer = function()
            local timer = {
              starts = {},
              closed = false,
            }

            function timer:start(delay, repeat_ms, callback)
              self.starts[#self.starts + 1] = {
                delay = delay,
                repeat_ms = repeat_ms,
              }
              self.callback = callback
            end

            function timer:stop()
            end

            function timer:close()
              self.closed = true
            end

            timers[#timers + 1] = timer
            return timer
          end

          vim.uv.new_fs_poll = function()
            return nil
          end

          git.repo_watch_paths = function()
            return {}
          end

          start_repo_sync()
          A.equal(timers[1].starts[1].delay, 250)

          repo_sync.request_refresh({ source = 'poll' })
          A.equal(timers[1].starts[2].delay, 500)

          repo_sync.request_refresh({ source = 'poll' })
          A.equal(timers[1].starts[3].delay, 1000)

          repo_sync.request_refresh({ source = 'poll' })
          A.equal(timers[1].starts[4].delay, 2000)

          repo_sync.request_refresh({ source = 'poll' })
          A.equal(timers[1].starts[5].delay, 3000)

          repo_sync.request_refresh({ source = 'poll' })
          A.equal(timers[1].starts[6].delay, 3000)
          A.falsy(timers[1].closed)

          repo_sync.note_activity()
          A.equal(#timers, 1)
          A.equal(timers[1].starts[7].delay, 250)
        end, debug.traceback)

        repo_sync.stop()
        git.repo_watch_paths = original_repo_watch_paths
        vim.uv.new_fs_poll = original_new_fs_poll
        vim.uv.new_timer = original_new_timer
        git.get_status_snapshot_async = original_async_snapshot

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
        local repo_sync = require('glance.repo_sync')
        local original_async_snapshot = git.get_status_snapshot_async
        local original_new_timer = vim.uv.new_timer
        local original_new_fs_poll = vim.uv.new_fs_poll
        local original_repo_watch_paths = git.repo_watch_paths
        local repo_watch_path_calls = 0

        config.setup({
          watch = {
            enabled = true,
            poll = true,
            interval_ms = 200,
          },
        })

        local ok, err = xpcall(function()
          git.get_status_snapshot_async = function(callback)
            callback(empty_snapshot(''))
          end

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

          start_repo_sync()
          A.equal(repo_watch_path_calls, 1)

          repo_sync.request_refresh({ source = 'poll' })
          A.equal(repo_watch_path_calls, 1)

          repo_sync.request_refresh({
            source = 'focus',
            reset_poll = true,
            resync_watchers = true,
          })
          vim.wait(100, function()
            return repo_watch_path_calls == 2
          end)
          A.equal(repo_watch_path_calls, 2)
        end, debug.traceback)

        repo_sync.stop()
        git.repo_watch_paths = original_repo_watch_paths
        vim.uv.new_fs_poll = original_new_fs_poll
        vim.uv.new_timer = original_new_timer
        git.get_status_snapshot_async = original_async_snapshot

        if not ok then
          error(err)
        end
      end,
    },
    {
      name = 'scheduled repo refreshes fetch snapshots asynchronously and coalesce in flight requests',
      run = function()
        local git = require('glance.git')
        local repo_sync = require('glance.repo_sync')
        local original_async_snapshot = git.get_status_snapshot_async
        local callbacks = {}
        local fetches = 0
        local handled = {}
        local current_key = ''

        local ok, err = xpcall(function()
          git.get_status_snapshot_async = function(callback)
            fetches = fetches + 1
            callbacks[#callbacks + 1] = callback
          end

          start_repo_sync({
            get_current_snapshot_key = function()
              return current_key
            end,
            on_snapshot = function(snapshot, opts)
              current_key = snapshot.key or ''
              handled[#handled + 1] = {
                snapshot = snapshot,
                opts = vim.deepcopy(opts),
              }
            end,
          })

          repo_sync.request_refresh({ source = 'poll' })
          vim.wait(100, function()
            return fetches == 1
          end)
          A.equal(fetches, 1)

          repo_sync.request_refresh({
            source = 'watch',
            reset_poll = true,
            resync_watchers = true,
          })
          vim.wait(20)
          A.equal(fetches, 1)

          callbacks[1](empty_snapshot('first'))

          vim.wait(100, function()
            return fetches == 2 and #handled == 1
          end)
          A.equal(fetches, 2)
          A.equal(handled[1].opts.source, 'poll')

          callbacks[2](empty_snapshot('second'))

          vim.wait(100, function()
            return #handled == 2
          end)
          A.equal(handled[2].opts.source, 'watch')
          A.truthy(handled[2].opts.reset_poll)
          A.truthy(handled[2].opts.resync_watchers)
        end, debug.traceback)

        repo_sync.stop()
        git.get_status_snapshot_async = original_async_snapshot

        if not ok then
          error(err)
        end
      end,
    },
  },
}
