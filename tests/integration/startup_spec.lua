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
      name = 'startup in a clean repo hits the no changes path',
      run = function()
        N.with_repo('repo_no_changes', function()
          local messages, restore = N.capture_notifications()
          local quits = capture_quit(function()
            require('glance').start()
          end)
          restore()

          A.equal(messages[1].msg, 'glance: no changes found')
          A.equal(messages[1].level, vim.log.levels.INFO)
          A.length(quits, 1)
        end)
      end,
    },
    {
      name = 'dirty startup sets options highlights and the initial layout',
      run = function()
        N.with_repo('repo_modified', function()
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
          A.equal(vim.api.nvim_win_get_width(filetree.win), config.options.filetree_width)
          A.truthy(next(vim.api.nvim_get_hl(0, { name = 'GlanceSectionHeader', link = false })) ~= nil)
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
