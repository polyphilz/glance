local config = require('glance.config')

local M = {}

local state = {
  started = false,
  root = nil,
  get_current_snapshot_key = function()
    return ''
  end,
  on_snapshot = function()
  end,
  is_active_fast = function()
    return true
  end,
  is_active = function()
    return true
  end,
  watchers = {},
  watch_signature = nil,
  refresh_pending = false,
  refresh_inflight = false,
  refresh_generation = 0,
  refresh_options = nil,
  poll_timer = nil,
  poll_backoff_index = 1,
}

local function watch_options()
  return config.options.watch
end

local function repo_poll_enabled()
  return state.started
    and watch_options().enabled
    and watch_options().poll
end

local function repo_fs_watch_enabled()
  return state.started
    and watch_options().enabled
end

local function close_handle(handle)
  if not handle then
    return
  end

  pcall(function()
    handle:stop()
  end)
  pcall(function()
    handle:close()
  end)
end

local function stop_repo_poll()
  if state.poll_timer then
    close_handle(state.poll_timer)
    state.poll_timer = nil
  end
end

local function repo_poll_intervals()
  local base = math.max(watch_options().interval_ms, 250)
  local max_delay = 3000
  local delays = {
    base,
    math.min(base * 2, max_delay),
    math.min(base * 4, max_delay),
    math.min(base * 8, max_delay),
    max_delay,
  }

  local deduped = {}
  for _, delay in ipairs(delays) do
    if deduped[#deduped] ~= delay then
      deduped[#deduped + 1] = delay
    end
  end

  return deduped
end

local function reset_repo_poll_backoff()
  state.poll_backoff_index = 1
end

local function advance_repo_poll_backoff()
  local delays = repo_poll_intervals()
  state.poll_backoff_index = math.min((state.poll_backoff_index or 1) + 1, #delays)
end

local function current_repo_poll_delay()
  local delays = repo_poll_intervals()
  local index = math.min(math.max(state.poll_backoff_index or 1, 1), #delays)
  state.poll_backoff_index = index
  return delays[index]
end

local function repo_poll_backoff_exhausted()
  local delays = repo_poll_intervals()
  return (state.poll_backoff_index or 1) >= #delays
end

local function schedule_repo_poll(reset_backoff)
  if not repo_poll_enabled() then
    stop_repo_poll()
    reset_repo_poll_backoff()
    return
  end

  if reset_backoff then
    reset_repo_poll_backoff()
  end

  if not state.poll_timer then
    state.poll_timer = vim.uv.new_timer()
  end
  if not state.poll_timer then
    return
  end

  local delay = current_repo_poll_delay()

  pcall(function()
    state.poll_timer:stop()
  end)

  local ok = pcall(function()
    state.poll_timer:start(delay, 0, function()
      if not state.is_active_fast() then
        return
      end

      M.request_refresh({ source = 'poll' })
    end)
  end)

  if not ok then
    close_handle(state.poll_timer)
    state.poll_timer = nil
  end
end

local function stop_repo_watchers()
  for _, watcher in ipairs(state.watchers) do
    close_handle(watcher)
  end
  state.watchers = {}
  state.watch_signature = nil
end

local function finalize_repo_poll(changed, opts)
  if not repo_poll_enabled() then
    stop_repo_poll()
    reset_repo_poll_backoff()
    return
  end

  opts = opts or {}
  if changed or opts.reset_poll then
    reset_repo_poll_backoff()
  elseif opts.source == 'poll' then
    if not repo_poll_backoff_exhausted() then
      advance_repo_poll_backoff()
    end
  end

  schedule_repo_poll(false)
end

local function sync_repo_watchers()
  local git = require('glance.git')
  local paths = {}
  local signature = ''

  if repo_fs_watch_enabled() then
    paths = git.repo_watch_paths()
    signature = table.concat(paths, '\n')
  end

  if signature == state.watch_signature then
    return
  end

  stop_repo_watchers()
  state.watch_signature = signature

  for _, path in ipairs(paths) do
    local watcher = vim.uv.new_fs_poll()
    if watcher then
      local ok = pcall(function()
        watcher:start(path, watch_options().interval_ms, function(err)
          if err then
            return
          end

          M.request_refresh({
            source = 'watch',
            reset_poll = true,
            resync_watchers = true,
          })
        end)
      end)

      if ok then
        state.watchers[#state.watchers + 1] = watcher
      else
        close_handle(watcher)
      end
    end
  end
end

local function reset_runtime_state()
  state.refresh_generation = state.refresh_generation + 1
  stop_repo_poll()
  stop_repo_watchers()
  state.refresh_pending = false
  state.refresh_inflight = false
  state.refresh_options = nil
  reset_repo_poll_backoff()
end

function M.start(opts)
  opts = opts or {}

  reset_runtime_state()
  state.started = true
  state.root = opts.root
  state.get_current_snapshot_key = opts.get_current_snapshot_key or function()
    return ''
  end
  state.on_snapshot = opts.on_snapshot or function()
  end
  state.is_active_fast = opts.is_active_fast or opts.is_active or function()
    return true
  end
  state.is_active = opts.is_active or function()
    return true
  end

  sync_repo_watchers()
  schedule_repo_poll(true)
end

function M.stop()
  reset_runtime_state()
  state.started = false
  state.root = nil
  state.get_current_snapshot_key = function()
    return ''
  end
  state.on_snapshot = function()
  end
  state.is_active_fast = function()
    return true
  end
  state.is_active = function()
    return true
  end
end

function M.note_activity(opts)
  if not state.started then
    return
  end

  opts = opts or {}
  local function apply_activity()
    if not state.started then
      return
    end

    if opts.resync_watchers then
      sync_repo_watchers()
    end

    schedule_repo_poll(opts.reset_poll ~= false)
  end

  if vim.in_fast_event() then
    vim.schedule(apply_activity)
    return
  end

  apply_activity()
end

function M.request_refresh(opts)
  if not state.started then
    return
  end

  opts = opts or {}
  local pending_opts = state.refresh_options or {}
  pending_opts.reset_poll = pending_opts.reset_poll or opts.reset_poll
  pending_opts.resync_watchers = pending_opts.resync_watchers or opts.resync_watchers
  if pending_opts.source == nil or pending_opts.source == 'poll' then
    pending_opts.source = opts.source or pending_opts.source
  end
  state.refresh_options = pending_opts

  if state.refresh_pending or state.refresh_inflight then
    return
  end

  if pending_opts.source == 'poll'
    and not pending_opts.reset_poll
    and not pending_opts.resync_watchers
  then
    local refresh_generation = state.refresh_generation
    state.refresh_options = nil
    state.refresh_inflight = true

    require('glance.git').get_status_snapshot_async(function(snapshot)
      if refresh_generation ~= state.refresh_generation then
        state.refresh_inflight = false
        return
      end

      if (snapshot.key or '') == (state.get_current_snapshot_key() or '') then
        state.refresh_inflight = false
        finalize_repo_poll(false, pending_opts)
        if state.refresh_options ~= nil then
          M.request_refresh()
        end
        return
      end

      vim.schedule(function()
        if refresh_generation ~= state.refresh_generation then
          state.refresh_inflight = false
          return
        end
        if not state.is_active() then
          state.refresh_inflight = false
          return
        end

        state.refresh_inflight = false
        state.on_snapshot(snapshot, pending_opts)
        sync_repo_watchers()
        finalize_repo_poll(true, pending_opts)
        if state.refresh_options ~= nil then
          M.request_refresh()
        end
      end)
    end, {
      root = state.root,
      schedule_callback = false,
    })
    return
  end

  state.refresh_pending = true
  vim.schedule(function()
    state.refresh_pending = false
    if not state.is_active() then
      state.refresh_options = nil
      return
    end

    local pending_opts = state.refresh_options or {}
    state.refresh_options = nil
    state.refresh_inflight = true
    local refresh_generation = state.refresh_generation

    require('glance.git').get_status_snapshot_async(function(snapshot)
      if refresh_generation ~= state.refresh_generation then
        state.refresh_inflight = false
        return
      end

      state.refresh_inflight = false
      if not state.is_active() then
        return
      end

      if (snapshot.key or '') == (state.get_current_snapshot_key() or '') then
        if pending_opts.resync_watchers then
          sync_repo_watchers()
        end
        finalize_repo_poll(false, pending_opts)
      else
        state.on_snapshot(snapshot, pending_opts)
        sync_repo_watchers()
        finalize_repo_poll(true, pending_opts)
      end

      if state.refresh_options ~= nil then
        M.request_refresh()
      end
    end)
  end)
end

return M
