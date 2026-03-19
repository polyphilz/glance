local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

local function capture_quit(fn)
  local original = vim.cmd
  local seen = {}

  vim.cmd = function(cmd)
    if cmd == 'qa!' then
      seen[#seen + 1] = cmd
      return
    end
    return original(cmd)
  end

  local ok, err = xpcall(fn, debug.traceback)
  vim.cmd = original

  if not ok then
    error(err, 0)
  end

  return seen
end

return {
  name = 'startup',
  cases = {
    {
      name = 'startup outside a repo hits the error exit path',
      run = function()
        N.with_tempdir(function()
          local messages, restore = N.capture_notifications()
          local quits = capture_quit(function()
            require('glance').start()
          end)
          restore()

          A.equal(messages[1].msg, 'glance: not a git repository')
          A.equal(messages[1].level, vim.log.levels.ERROR)
          A.length(quits, 1)
        end)
      end,
    },
    {
      name = 'startup in a clean repo shows the empty state layout',
      run = function()
        N.with_repo('repo_no_changes', function()
          local messages, restore = N.capture_notifications()
          local quits = capture_quit(function()
            require('glance').start()
          end)
          restore()

          local filetree = require('glance.filetree')
          local ui = require('glance.ui')
          local lines = vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false)

          A.same(messages, {})
          A.length(quits, 0)
          A.truthy(filetree.win and vim.api.nvim_win_is_valid(filetree.win))
          A.truthy(ui.welcome_win and vim.api.nvim_win_is_valid(ui.welcome_win))
          A.equal(lines[#lines], '  No changes found')
          A.equal(vim.api.nvim_get_option_value('cursorline', { win = filetree.win }), false)
          A.same(vim.api.nvim_win_get_cursor(filetree.win), { #lines, 4 })
        end)
      end,
    },
    {
      name = 'dirty startup sets options highlights and the initial layout',
      run = function()
        N.with_repo('repo_modified', function()
          vim.o.laststatus = 3
          require('glance').start()
          local config = require('glance.config')
          local filetree = require('glance.filetree')
          local ui = require('glance.ui')

          A.truthy(filetree.win and vim.api.nvim_win_is_valid(filetree.win))
          A.truthy(ui.welcome_win and vim.api.nvim_win_is_valid(ui.welcome_win))
          A.equal(vim.go.termguicolors, true)
          A.equal(vim.o.autoread, true)
          A.equal(vim.o.hidden, false)
          A.equal(vim.o.smoothscroll, true)
          A.equal(vim.o.laststatus, 3)
          A.equal(vim.api.nvim_win_get_width(filetree.win), config.options.windows.filetree.width)
          A.truthy(next(vim.api.nvim_get_hl(0, { name = 'GlanceSectionHeader', link = false })) ~= nil)
        end)
      end,
    },
    {
      name = 'conflicts count as startup-visible changes and render a conflicts section',
      run = function()
        N.with_repo('repo_conflict', function(repo)
          local messages, restore = N.capture_notifications()
          require('glance').start()
          restore()

          local filetree = require('glance.filetree')
          local lines = vim.api.nvim_buf_get_lines(filetree.buf, 0, -1, false)

          A.same(messages, {})
          A.truthy(filetree.win and vim.api.nvim_win_is_valid(filetree.win))
          A.contains(lines, '  Conflicts')
          A.contains(lines, '    U ' .. repo.files.tracked)
          A.equal(filetree.get_selected_file().path, repo.files.tracked)
          A.equal(filetree.get_selected_file().section, 'conflicts')
        end)
      end,
    },
    {
      name = 'startup can hide the statusline when configured',
      run = function()
        N.with_repo('repo_modified', function()
          local glance = require('glance')

          vim.o.laststatus = 3
          glance.setup({
            app = {
              hide_statusline = true,
            },
          })
          glance.start()

          A.equal(vim.o.laststatus, 0)
        end)
      end,
    },
    {
      name = 'tree sitter setup remains non-fatal when parsers are absent',
      run = function()
        local glance = require('glance')
        local ok = pcall(glance.setup_treesitter)
        A.truthy(ok)
      end,
    },
  },
}
