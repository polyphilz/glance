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
          hunk_navigation = {},
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
          hunk_navigation = {
            next = 'N',
          },
          keymaps = {
            quit = 'x',
          },
        })

        A.equal(config.options.filetree_width, 42)
        A.equal(config.options.hide_statusline, true)
        A.equal(config.options.hunk_navigation.next, 'N')
        A.equal(config.options.hunk_navigation.prev, nil)
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
    {
      name = 'duplicate hunk navigation keys are rejected',
      run = function()
        local config = require('glance.config')
        local ok, err = pcall(function()
          config.setup({
            hunk_navigation = {
              next = 'N',
              prev = 'N',
            },
          })
        end)

        A.falsy(ok)
        A.match(err, 'hunk_navigation%.next and hunk_navigation%.prev must be different')
      end,
    },
    {
      name = 'hunk navigation keys cannot reuse toggle filetree',
      run = function()
        local config = require('glance.config')
        local ok, err = pcall(function()
          config.setup({
            hunk_navigation = {
              next = '<Tab>',
            },
          })
        end)

        A.falsy(ok)
        A.match(err, 'hunk_navigation%.next conflicts with keymaps%.toggle_filetree')
      end,
    },
  },
}
