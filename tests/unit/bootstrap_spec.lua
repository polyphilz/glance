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
      name = 'search path prefers GLANCE_CONFIG over XDG config',
      run = function()
        local bootstrap = require('glance.bootstrap')

        N.with_tempdir(function(tempdir)
          local explicit = tempdir .. '/explicit.lua'
          local xdg_home = tempdir .. '/xdg'
          local xdg_config = xdg_home .. '/glance/config.lua'
          write_file(explicit, { 'return { app = { hide_statusline = true } }' })
          write_file(xdg_config, { 'return { app = { hide_statusline = false } }' })

          local path = bootstrap.find_config_path({
            env = {
              GLANCE_CONFIG = explicit,
              XDG_CONFIG_HOME = xdg_home,
            },
          })

          A.equal(path, explicit)
        end)
      end,
    },
    {
      name = 'missing config file returns an empty config table',
      run = function()
        local bootstrap = require('glance.bootstrap')

        N.with_tempdir(function(tempdir)
          local original_home = vim.env.HOME
          vim.env.HOME = tempdir .. '/home'
          local loaded = bootstrap.load_user_config({
            env = {
              GLANCE_CONFIG = tempdir .. '/missing.lua',
              XDG_CONFIG_HOME = tempdir .. '/xdg',
            },
            notify = false,
          })
          vim.env.HOME = original_home

          A.same(loaded, {})
        end)
      end,
    },
    {
      name = 'invalid config file notifies and falls back to defaults',
      run = function()
        local bootstrap = require('glance.bootstrap')

        N.with_tempdir(function(tempdir)
          local path = tempdir .. '/bad.lua'
          write_file(path, { 'return 42' })

          local messages, restore = N.capture_notifications()
          local loaded = bootstrap.load_user_config({
            env = {
              GLANCE_CONFIG = path,
            },
          })
          restore()

          A.same(loaded, {})
          A.length(messages, 1)
          A.match(messages[1].msg, 'config file .- must return a table')
          A.equal(messages[1].level, vim.log.levels.WARN)
        end)
      end,
    },
  },
}
