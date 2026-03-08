local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

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
  },
}
