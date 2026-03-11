local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

return {
  name = 'minimap-theme',
  cases = {
    {
      name = 'minimap cursor color follows the active theme preset',
      run = function()
        N.with_repo('repo_modified', function()
          require('glance').setup({
            theme = {
              preset = 'one_light',
            },
          })

          require('glance').start()
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          local minimap = require('glance.minimap')

          ui.open_file(filetree.files.changes[1])
          local diffview = require('glance.diffview')

          vim.api.nvim_win_set_cursor(diffview.new_win, { 1, 0 })
          minimap.update_viewport()

          local extmarks = vim.api.nvim_buf_get_extmarks(minimap.buf, -1, 0, -1, {
            details = true,
          })

          local hl_group
          for _, extmark in ipairs(extmarks) do
            local details = extmark[4]
            if details and details.hl_group then
              hl_group = details.hl_group
              break
            end
          end

          A.truthy(hl_group)

          local hl = vim.api.nvim_get_hl(0, { name = hl_group })
          A.equal(hl.fg, tonumber('111111', 16))
        end)
      end,
    },
  },
}
