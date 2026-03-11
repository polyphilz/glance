local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

local function write_file(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(lines, path)
end

return {
  name = 'bootstrap',
  cases = {
    {
      name = 'bootstrap automatically loads config from XDG path',
      run = function()
        N.with_repo('repo_modified', function(repo)
          N.with_tempdir(function(tempdir)
            local xdg_home = tempdir .. '/xdg'
            local config_path = xdg_home .. '/glance/config.lua'
            write_file(config_path, {
              'return {',
              '  app = {',
              '    hide_statusline = true,',
              '  },',
              '  windows = {',
              '    filetree = {',
              '      width = 42,',
              '    },',
              '    diff = {',
              '      relativenumber = false,',
              '    },',
              '  },',
              '  minimap = {',
              '    enabled = false,',
              '  },',
              '  watch = {',
              '    enabled = false,',
              '  },',
              '}',
            })

            local result = N.run_headless({
              'cd ' .. repo.root,
              "lua require('glance.bootstrap').run()",
              "lua local filetree = require('glance.filetree'); require('glance.ui').open_file(filetree.files.changes[1])",
              "lua local filetree = require('glance.filetree'); local diffview = require('glance.diffview'); local minimap = require('glance.minimap'); print('laststatus=' .. vim.o.laststatus); print('tree_width=' .. vim.api.nvim_win_get_width(filetree.win)); print('diff_relativenumber=' .. tostring(vim.api.nvim_get_option_value('relativenumber', { win = diffview.new_win }))); print('minimap=' .. tostring(minimap.win ~= nil)); print('watch=' .. tostring(diffview.fs_watcher ~= nil))",
            }, {
              env = {
                XDG_CONFIG_HOME = xdg_home,
              },
            })

            A.equal(result.code, 0, result.output)
            A.contains(result.output, 'laststatus=0')
            A.contains(result.output, 'tree_width=42')
            A.contains(result.output, 'diff_relativenumber=false')
            A.contains(result.output, 'minimap=false')
            A.contains(result.output, 'watch=false')
          end)
        end)
      end,
    },
  },
}
