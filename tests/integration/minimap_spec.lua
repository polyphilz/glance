local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

local function with_counted_function(tbl, key, fn)
  local original = tbl[key]
  local calls = 0

  tbl[key] = function(...)
    calls = calls + 1
    return original(...)
  end

  local ok, err = xpcall(function()
    return fn(function()
      return calls
    end)
  end, debug.traceback)

  tbl[key] = original

  if not ok then
    error(err, 0)
  end
end

return {
  name = 'minimap',
  cases = {
    {
      name = 'minimap opens on diff and closes cleanly',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          local minimap = require('glance.minimap')

          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')

          A.truthy(minimap.win and vim.api.nvim_win_is_valid(minimap.win))
          A.equal(minimap.target_win, diffview.new_win)

          diffview.close(true)
          A.equal(minimap.win, nil)
          A.equal(minimap.buf, nil)
        end)
      end,
    },
    {
      name = 'text edits scroll and resize update the minimap state',
      run = function()
        N.with_repo('repo_modified', function(repo)
          local lines = {}
          for i = 1, 40 do
            lines[i] = 'line ' .. i
          end
          repo:write(repo.files.tracked, table.concat(lines, '\n') .. '\n')
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          local minimap = require('glance.minimap')

          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')

          vim.api.nvim_buf_set_lines(diffview.new_buf, 0, -1, false, {
            'changed',
            'line',
            'set',
            'for',
            'minimap',
          })
          minimap.full_update()
          A.truthy(minimap.cached_pixels and #minimap.cached_pixels > 0)

          vim.api.nvim_win_set_cursor(diffview.new_win, { 5, 0 })
          minimap.update_viewport()

          vim.api.nvim_win_set_height(diffview.new_win, 6)
          minimap.update_viewport()
          local config = vim.api.nvim_win_get_config(minimap.win)
          A.equal(config.height, 6)
          A.equal(config.col, vim.api.nvim_win_get_width(diffview.new_win))
        end)
      end,
    },
    {
      name = 'repeated open close cycles leave no orphan minimap autocmds',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          local minimap = require('glance.minimap')

          for _ = 1, 2 do
            ui.open_file(filetree.files.changes[1])
            require('glance.diffview').close(true)
          end

          A.equal(minimap.win, nil)
          A.equal(minimap.buf, nil)
          A.length(vim.api.nvim_get_autocmds({ group = minimap.augroup }), 0)
        end)
      end,
    },
    {
      name = 'minimap can be disabled via config',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').setup({
            minimap = {
              enabled = false,
            },
          })
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          local minimap = require('glance.minimap')

          ui.open_file(filetree.files.changes[1])
          A.equal(minimap.win, nil)
        end)
      end,
    },
    {
      name = 'minimap width follows config',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').setup({
            minimap = {
              width = 3,
            },
          })
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          local minimap = require('glance.minimap')

          ui.open_file(filetree.files.changes[1])
          local config = vim.api.nvim_win_get_config(minimap.win)
          A.equal(config.width, 3)
        end)
      end,
    },
    {
      name = 'content edits are coalesced into one full update',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')

          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')
          local minimap = require('glance.minimap')

          with_counted_function(minimap, 'full_update', function(get_calls)
            vim.api.nvim_buf_set_lines(diffview.new_buf, 0, -1, false, {
              'one',
              'two',
              'three',
            })
            minimap.request_content_update()

            vim.api.nvim_buf_set_lines(diffview.new_buf, 0, -1, false, {
              'one',
              'two updated',
              'three',
            })
            minimap.request_content_update()

            vim.api.nvim_buf_set_lines(diffview.new_buf, 0, -1, false, {
              'one',
              'two updated',
              'three updated',
            })
            minimap.request_content_update()

            N.wait(500, function()
              return get_calls() >= 1
            end)
            vim.wait(200)

            A.equal(get_calls(), 1)
          end)
        end)
      end,
    },
    {
      name = 'viewport updates stay on the cached render path',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')

          ui.open_file(filetree.files.changes[1])
          local minimap = require('glance.minimap')

          with_counted_function(minimap, 'full_update', function(get_calls)
            minimap.request_viewport_update()
            minimap.request_viewport_update()
            minimap.request_viewport_update()
            vim.wait(100)

            A.equal(get_calls(), 0)
          end)
        end)
      end,
    },
    {
      name = 'write flushes pending content work once and updates the minimap immediately',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')

          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')
          local minimap = require('glance.minimap')

          with_counted_function(minimap, 'full_update', function(get_calls)
            vim.api.nvim_set_current_win(diffview.new_win)
            N.press('Goafter save<Esc>')

            vim.api.nvim_buf_call(diffview.new_buf, function()
              vim.cmd('write')
            end)

            N.wait(500, function()
              return minimap.total_logical == 4 and get_calls() >= 1
            end)
            vim.wait(200)

            A.equal(minimap.total_logical, 4)
            A.equal(get_calls(), 1)
          end)
        end)
      end,
    },
    {
      name = 'unchanged full updates skip redundant diff recompute',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')

          ui.open_file(filetree.files.changes[1])
          local logic = require('glance.minimap_logic')
          local minimap = require('glance.minimap')

          with_counted_function(logic, 'compute_line_types', function(get_calls)
            minimap.full_update()
            minimap.full_update()

            A.equal(get_calls(), 0)
          end)
        end)
      end,
    },
  },
}
