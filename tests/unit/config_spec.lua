local A = require('tests.helpers.assert')

return {
  name = 'config',
  cases = {
    {
      name = 'defaults expose the nested config schema',
      run = function()
        local config = require('glance.config')
        A.same(config.defaults, {
          app = {
            hide_statusline = false,
            colorscheme = 'default',
            termguicolors = true,
            smoothscroll = true,
            mousescroll = 'ver:1,hor:1',
            checktime = true,
            autoread = true,
            hidden = false,
          },
          theme = {
            preset = 'seti_black',
            palette = {
              bg = '#000000',
              fg = '#D7D7D7',
              muted = '#677A83',
              string = '#E6DB74',
              keyword = '#F92672',
              func = '#A6E22E',
              type = '#66D9EF',
              number = '#AE81FF',
              accent = '#FD971F',
              selection = '#444444',
              line_highlight = '#333333',
              logo = '#F2E94B',
              added = '#2ea043',
              deleted = '#f85149',
              changed = '#d29922',
              minimap_bg = '#111111',
              minimap_viewport_bg = '#2a2a2a',
              statusline_bg = '#101010',
              split = '#333333',
              deleted_old = '#3d1a1a',
              deleted_old_text = '#6b2c2c',
              added_new = '#1a3d1a',
              added_new_text = '#2b6b2b',
              diff_change = '#2b2b00',
              diff_text = '#4a4a00',
              untracked = '#808080',
              line_nr = '#555555',
              folded = '#1a1a1a',
            },
          },
          windows = {
            filetree = {
              width = 30,
              number = false,
              relativenumber = false,
              signcolumn = 'no',
              cursorline = true,
              winfixwidth = true,
            },
            diff = {
              number = true,
              relativenumber = true,
              signcolumn = 'no',
              cursorline = false,
              foldenable = false,
            },
            welcome = {
              number = false,
              relativenumber = false,
              signcolumn = 'no',
              cursorline = false,
            },
          },
          keymaps = {
            open_file = '<CR>',
            quit = 'q',
            refresh = 'r',
            next_section = 'J',
            prev_section = 'K',
            toggle_filetree = '<Tab>',
          },
          hunk_navigation = {},
          signs = {
            modified = 'M',
            added = 'A',
            deleted = 'D',
            renamed = 'R',
            untracked = '?',
          },
          welcome = {
            animate = true,
            frame_ms = 150,
          },
          minimap = {
            enabled = true,
            width = 1,
            winblend = 0,
            zindex = 50,
            debounce_ms = 16,
          },
          watch = {
            enabled = true,
            interval_ms = 200,
          },
        })
      end,
    },
    {
      name = 'setup deep merges nested overrides',
      run = function()
        local config = require('glance.config')
        config.setup({
          app = {
            hide_statusline = true,
          },
          windows = {
            filetree = {
              width = 42,
            },
            diff = {
              relativenumber = false,
            },
          },
          theme = {
            palette = {
              logo = '#ffffff',
            },
          },
          hunk_navigation = {
            next = 'N',
          },
          keymaps = {
            quit = 'x',
          },
          minimap = {
            enabled = false,
          },
        })

        A.equal(config.options.app.hide_statusline, true)
        A.equal(config.options.windows.filetree.width, 42)
        A.equal(config.options.windows.filetree.cursorline, true)
        A.equal(config.options.windows.diff.relativenumber, false)
        A.equal(config.options.theme.palette.logo, '#ffffff')
        A.equal(config.options.theme.palette.bg, '#000000')
        A.equal(config.options.hunk_navigation.next, 'N')
        A.equal(config.options.hunk_navigation.prev, nil)
        A.equal(config.options.keymaps.quit, 'x')
        A.equal(config.options.keymaps.open_file, '<CR>')
        A.equal(config.options.minimap.enabled, false)
        A.equal(config.options.watch.enabled, true)
      end,
    },
    {
      name = 'partial sign overrides preserve defaults and drive display glyphs',
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
      name = 'flat legacy keys are rejected',
      run = function()
        local config = require('glance.config')
        local ok, err = pcall(function()
          config.setup({
            hide_statusline = true,
          })
        end)

        A.falsy(ok)
        A.match(err, 'unknown config key config%.hide_statusline')
      end,
    },
    {
      name = 'invalid window signcolumn values are rejected',
      run = function()
        local config = require('glance.config')
        local ok, err = pcall(function()
          config.setup({
            windows = {
              diff = {
                signcolumn = 'bogus',
              },
            },
          })
        end)

        A.falsy(ok)
        A.match(err, 'windows%.diff%.signcolumn must be a valid signcolumn value')
      end,
    },
    {
      name = 'invalid theme palette colors are rejected',
      run = function()
        local config = require('glance.config')
        local ok, err = pcall(function()
          config.setup({
            theme = {
              palette = {
                bg = 'banana',
              },
            },
          })
        end)

        A.falsy(ok)
        A.match(err, 'theme%.palette%.bg must be a hex color like #RRGGBB')
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
