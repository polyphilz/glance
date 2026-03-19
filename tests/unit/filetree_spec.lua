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
        A.equal(vim.api.nvim_get_option_value('cursorline', { win = filetree.win }), false)
        A.same(vim.api.nvim_win_get_cursor(filetree.win), { 5, 4 })
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
