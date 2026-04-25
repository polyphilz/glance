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
              logo = '#FD971F',
              added = '#2ea043',
              deleted = '#f85149',
              changed = '#d29922',
              manual = '#B48CFF',
              minimap_bg = '#111111',
              minimap_viewport_bg = '#2a2a2a',
              minimap_cursor = '#C8C8C8',
              statusline_bg = '#101010',
              split = '#333333',
              split_hover = '#FD971F',
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
          },
          filetree = {
            show_legend = true,
          },
          log = {
            max_commits = 200,
          },
          merge = {
            keymaps = {
              accept_ours = '<leader>o',
              accept_theirs = '<leader>t',
              accept_both_ours_then_theirs = '<leader>O',
              accept_both_theirs_then_ours = '<leader>T',
              keep_base = '<leader>b',
              reset_conflict = '<leader>r',
              mark_resolved = '<leader>m',
            },
          },
          keymaps = {
            open_file = '<CR>',
            quit = 'q',
            refresh = 'r',
            next_section = 'J',
            prev_section = 'K',
            toggle_filetree = '<Tab>',
            commit = 'c',
            log = 'L',
            stage_file = 's',
            stage_all = 'S',
            unstage_file = 'u',
            unstage_all = 'U',
            discard_file = 'd',
            discard_all = 'D',
          },
          pane_navigation = {},
          hunk_navigation = {},
          signs = {
            modified = 'M',
            added = 'A',
            deleted = 'D',
            renamed = 'R',
            copied = 'C',
            type_changed = 'T',
            conflicted = 'U',
            untracked = '?',
          },
          welcome = {
            animate = true,
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
            poll = true,
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
          filetree = {
            show_legend = false,
          },
          log = {
            max_commits = 75,
          },
          merge = {
            keymaps = {
              accept_ours = 'go',
            },
          },
          theme = {
            preset = 'one_light',
            palette = {
              logo = '#ffffff',
            },
          },
          hunk_navigation = {
            next = 'N',
          },
          pane_navigation = {
            left = 'H',
          },
          keymaps = {
            quit = 'x',
            commit = 'm',
            log = 'o',
            stage_file = 'g',
            discard_file = 'z',
          },
          minimap = {
            enabled = false,
          },
        })

        A.equal(config.options.app.hide_statusline, true)
        A.equal(config.options.windows.filetree.width, 42)
        A.equal(config.options.windows.filetree.cursorline, true)
        A.equal(config.options.filetree.show_legend, false)
        A.equal(config.options.log.max_commits, 75)
        A.equal(config.options.merge.keymaps.accept_ours, 'go')
        A.equal(config.options.merge.keymaps.accept_theirs, '<leader>t')
        A.equal(config.options.windows.diff.relativenumber, false)
        A.equal(config.options.theme.preset, 'one_light')
        A.equal(config.options.theme.palette.logo, '#ffffff')
        A.equal(config.options.theme.palette.bg, '#FAFAFA')
        A.equal(config.options.theme.palette.keyword, '#A626A4')
        A.equal(config.options.theme.palette.minimap_cursor, '#111111')
        A.equal(config.options.hunk_navigation.next, 'N')
        A.equal(config.options.hunk_navigation.prev, nil)
        A.equal(config.options.pane_navigation.left, 'H')
        A.equal(config.options.pane_navigation.right, nil)
        A.equal(config.options.keymaps.quit, 'x')
        A.equal(config.options.keymaps.commit, 'm')
        A.equal(config.options.keymaps.log, 'o')
        A.equal(config.options.keymaps.stage_file, 'g')
        A.equal(config.options.keymaps.stage_all, 'S')
        A.equal(config.options.keymaps.unstage_file, 'u')
        A.equal(config.options.keymaps.unstage_all, 'U')
        A.equal(config.options.keymaps.open_file, '<CR>')
        A.equal(config.options.keymaps.discard_file, 'z')
        A.equal(config.options.keymaps.discard_all, 'D')
        A.equal(config.options.minimap.enabled, false)
        A.equal(config.options.watch.enabled, true)
        A.equal(config.options.watch.poll, true)
      end,
    },
    {
      name = 'theme preset resolves the built-in palette',
      run = function()
        local config = require('glance.config')
        config.setup({
          theme = {
            preset = 'one_light',
          },
        })

        A.equal(config.options.theme.preset, 'one_light')
        A.equal(config.options.theme.palette.bg, '#FAFAFA')
        A.equal(config.options.theme.palette.fg, '#383A42')
        A.equal(config.options.theme.palette.statusline_bg, '#EAEAEB')
        A.equal(config.options.theme.palette.logo, '#FD971F')
        A.equal(config.options.theme.palette.minimap_cursor, '#111111')
        A.equal(config.options.theme.palette.split_hover, '#526FFF')
        A.equal(config.options.theme.palette.deleted_old, '#F4CCC8')
        A.equal(config.options.theme.palette.added_new, '#CAE1CA')
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
        A.equal(config.options.signs.copied, 'C')
        A.equal(config.options.signs.conflicted, 'U')
        A.equal(config.options.signs.untracked, '?')
      end,
    },
    {
      name = 'removed welcome window config is rejected',
      run = function()
        local config = require('glance.config')
        local ok, err = pcall(function()
          config.setup({
            windows = {
              welcome = {
                number = true,
              },
            },
          })
        end)

        A.falsy(ok)
        A.match(err, 'unknown config key windows%.welcome')
      end,
    },
    {
      name = 'removed welcome frame timing option is rejected',
      run = function()
        local config = require('glance.config')
        local ok, err = pcall(function()
          config.setup({
            welcome = {
              frame_ms = 300,
            },
          })
        end)

        A.falsy(ok)
        A.match(err, 'unknown config key welcome%.frame_ms')
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
      name = 'invalid filetree options are rejected',
      run = function()
        local config = require('glance.config')
        local ok, err = pcall(function()
          config.setup({
            filetree = {
              show_legend = 'nope',
            },
          })
        end)

        A.falsy(ok)
        A.match(err, 'filetree%.show_legend must be a boolean')
      end,
    },
    {
      name = 'invalid log options are rejected',
      run = function()
        local config = require('glance.config')
        local ok, err = pcall(function()
          config.setup({
            log = {
              max_commits = 0,
            },
          })
        end)

        A.falsy(ok)
        A.match(err, 'log%.max_commits must be an integer >= 1')
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
      name = 'unknown theme presets are rejected',
      run = function()
        local config = require('glance.config')
        local ok, err = pcall(function()
          config.setup({
            theme = {
              preset = 'banana',
            },
          })
        end)

        A.falsy(ok)
        A.match(err, 'unknown theme preset banana')
      end,
    },
    {
      name = 'duplicate pane navigation keys are rejected',
      run = function()
        local config = require('glance.config')
        local ok, err = pcall(function()
          config.setup({
            pane_navigation = {
              left = 'H',
              right = 'H',
            },
          })
        end)

        A.falsy(ok)
        A.match(err, 'pane_navigation%.right conflicts with pane_navigation%.left')
      end,
    },
    {
      name = 'pane navigation keys cannot reuse other Glance mappings',
      run = function()
        local config = require('glance.config')
        local ok, err = pcall(function()
          config.setup({
            keymaps = {
              toggle_filetree = '<Tab>',
            },
            pane_navigation = {
              right = '<Tab>',
            },
          })
        end)

        A.falsy(ok)
        A.match(err, 'pane_navigation%.right conflicts with keymaps%.toggle_filetree')
      end,
    },
    {
      name = 'pane navigation keys cannot reuse hunk navigation mappings',
      run = function()
        local config = require('glance.config')
        local ok, err = pcall(function()
          config.setup({
            hunk_navigation = {
              next = 'N',
            },
            pane_navigation = {
              left = 'N',
            },
          })
        end)

        A.falsy(ok)
        A.match(err, 'pane_navigation%.left conflicts with hunk_navigation%.next')
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
    {
      name = 'duplicate action keymaps are rejected across the full keymap set',
      run = function()
        local config = require('glance.config')
        local ok, err = pcall(function()
          config.setup({
            keymaps = {
              log = 'c',
              commit = 'c',
            },
          })
        end)

        A.falsy(ok)
        A.match(err, 'keymaps%.log conflicts with keymaps%.commit')
      end,
    },
  },
}
