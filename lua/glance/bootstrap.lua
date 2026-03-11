local M = {}

local function env_value(env, key)
  if env and env[key] ~= nil then
    return env[key]
  end
  return vim.env[key]
end

function M.config_candidates(opts)
  opts = opts or {}
  local candidates = {}
  local env = opts.env
  local explicit = env_value(env, 'GLANCE_CONFIG')
  local xdg_config_home = env_value(env, 'XDG_CONFIG_HOME')

  if explicit and explicit ~= '' then
    candidates[#candidates + 1] = explicit
  end
  if xdg_config_home and xdg_config_home ~= '' then
    candidates[#candidates + 1] = xdg_config_home .. '/glance/config.lua'
  end
  candidates[#candidates + 1] = vim.fn.expand('~/.config/glance/config.lua')

  return candidates
end

function M.find_config_path(opts)
  opts = opts or {}
  for _, path in ipairs(M.config_candidates(opts)) do
    if vim.uv.fs_stat(path) then
      return path
    end
  end
end

function M.load_config_file(path)
  local chunk, load_err = loadfile(path)
  if not chunk then
    return nil, 'failed to load config file ' .. path .. ': ' .. load_err
  end

  local ok, result = pcall(chunk)
  if not ok then
    return nil, 'failed to execute config file ' .. path .. ': ' .. result
  end
  if type(result) ~= 'table' then
    return nil, 'config file ' .. path .. ' must return a table'
  end

  return result
end

function M.load_user_config(opts)
  opts = opts or {}
  local path = M.find_config_path(opts)
  if not path then
    return {}
  end

  local config, err = M.load_config_file(path)
  if config then
    return config
  end

  if opts.notify ~= false then
    vim.notify('glance: ' .. err, vim.log.levels.WARN)
  end
  return {}
end

function M.run(opts)
  opts = opts or {}
  local glance = require('glance')

  local user_config = M.load_user_config(opts)
  local ok, err = pcall(glance.setup, user_config)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.WARN)
    glance.setup()
  end

  glance.start()
end

return M
