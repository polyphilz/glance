local A = require('tests.helpers.assert')

return {
  name = 'config',
  cases = {
    {
      name = 'defaults are stable',
      run = function()
        local config = require('glance.config')
        A.same(config.defaults, {
          filetree_width = 30,
          hide_statusline = false,
          keymaps = {
            open_file = '<CR>',
            quit = 'q',
            refresh = 'r',
            next_section = 'J',
            prev_section = 'K',
            toggle_filetree = '<Tab>',
          },
          signs = {
            modified = 'M',
            added = 'A',
            deleted = 'D',
            renamed = 'R',
            untracked = '?',
          },
        })
      end,
    },
    {
      name = 'setup deep merges overrides',
      run = function()
        local config = require('glance.config')
        config.setup({
          filetree_width = 42,
          hide_statusline = true,
          keymaps = {
            quit = 'x',
          },
        })

        A.equal(config.options.filetree_width, 42)
        A.equal(config.options.hide_statusline, true)
        A.equal(config.options.keymaps.quit, 'x')
        A.equal(config.options.keymaps.open_file, '<CR>')
        A.equal(config.options.signs.deleted, 'D')
      end,
    },
    {
      name = 'partial sign overrides preserve defaults',
      run = function()
        local config = require('glance.config')
        config.setup({
          signs = {
            added = '+',
          },
        })

        A.equal(config.options.signs.added, '+')
        A.equal(config.options.signs.modified, 'M')
        A.equal(config.options.signs.untracked, '?')
      end,
    },
  },
}
