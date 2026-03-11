local paths = require('tests.helpers.paths')
local repo_helper = require('tests.helpers.repo')

local M = {}

local bootstrapped = false

local function listify(value)
  if type(value) == 'table' then
    return value
  end
  return { value }
end

local function shelljoin(cmd)
  local escaped = {}
  for _, part in ipairs(cmd) do
    escaped[#escaped + 1] = vim.fn.shellescape(part)
  end
  return table.concat(escaped, ' ')
end

function M.bootstrap()
  if bootstrapped then
    return
  end

  vim.opt.runtimepath:append(paths.root)
  vim.cmd('source ' .. vim.fn.fnameescape(paths.root .. '/plugin/glance.vim'))
  vim.o.swapfile = false
  bootstrapped = true
end

function M.wait(ms, predicate, message)
  local ok = vim.wait(ms, predicate or function()
    return true
  end, 10)
  if not ok then
    error(message or ('timed out after ' .. ms .. 'ms'), 2)
  end
end

function M.with_confirm(choice, fn)
  local original = vim.fn.confirm
  vim.fn.confirm = function()
    return choice
  end

  local ok, result = xpcall(fn, debug.traceback)
  vim.fn.confirm = original

  if not ok then
    error(result, 0)
  end

  return result
end

function M.capture_notifications()
  local messages = {}
  local original = vim.notify

  vim.notify = function(msg, level, opts)
    messages[#messages + 1] = {
      msg = tostring(msg),
      level = level,
      opts = opts,
    }
  end

  return messages, function()
    vim.notify = original
  end
end

function M.with_repo(scenario, fn)
  local repo = repo_helper.create(scenario)
  local previous = vim.fn.getcwd()

  local ok, result = xpcall(function()
    vim.cmd('cd ' .. vim.fn.fnameescape(repo.root))
    return fn(repo)
  end, debug.traceback)

  pcall(vim.cmd, 'cd ' .. vim.fn.fnameescape(previous))
  pcall(function()
    repo:cleanup()
  end)

  if not ok then
    error(result, 0)
  end

  return result
end

function M.with_tempdir(fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local previous = vim.fn.getcwd()

  local ok, result = xpcall(function()
    vim.cmd('cd ' .. vim.fn.fnameescape(dir))
    return fn(dir)
  end, debug.traceback)

  pcall(vim.cmd, 'cd ' .. vim.fn.fnameescape(previous))
  vim.fn.delete(dir, 'rf')

  if not ok then
    error(result, 0)
  end

  return result
end

function M.start_glance(scenario)
  M.bootstrap()
  return M.with_repo(scenario, function(repo)
    require('glance').start()
    return repo
  end)
end

function M.file_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

function M.press(keys)
  local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcodes, 'xt', false)
  vim.cmd('redraw')
end

function M.find_buffer_by_name(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
end

function M.window_layout()
  local function normalize(node)
    if type(node) ~= 'table' then
      return node
    end
    if #node == 2 and type(node[1]) == 'string' then
      local kind = node[1]
      if kind == 'leaf' then
        return {
          kind = kind,
          win = node[2],
          width = vim.api.nvim_win_is_valid(node[2]) and vim.api.nvim_win_get_width(node[2]) or nil,
          height = vim.api.nvim_win_is_valid(node[2]) and vim.api.nvim_win_get_height(node[2]) or nil,
          buf = vim.api.nvim_win_is_valid(node[2]) and vim.api.nvim_win_get_buf(node[2]) or nil,
        }
      end
      local children = {}
      for _, child in ipairs(node[2]) do
        children[#children + 1] = normalize(child)
      end
      return {
        kind = kind,
        children = children,
      }
    end
    return node
  end

  return normalize(vim.fn.winlayout())
end

function M.run_headless(commands, opts)
  M.bootstrap()
  opts = opts or {}
  local temp_root = vim.fn.tempname()
  vim.fn.mkdir(temp_root, 'p')
  vim.fn.mkdir(temp_root .. '/state', 'p')
  vim.fn.mkdir(temp_root .. '/data', 'p')
  vim.fn.mkdir(temp_root .. '/cache', 'p')
  local lua_root = paths.root .. '/lua'

  local command = {
    'env',
    'XDG_STATE_HOME=' .. temp_root .. '/state',
    'XDG_DATA_HOME=' .. temp_root .. '/data',
    'XDG_CACHE_HOME=' .. temp_root .. '/cache',
  }

  if opts.env then
    for key, value in pairs(opts.env) do
      command[#command + 1] = key .. '=' .. value
    end
  end

  command[#command + 1] = opts.nvim or 'nvim'
  vim.list_extend(command, {
    '--headless',
    '-u',
    'NONE',
    '-i',
    'NONE',
    '--cmd',
    'lua vim.opt.runtimepath:append([[' .. paths.root .. ']])',
    '--cmd',
    'lua package.path = package.path .. ";' .. lua_root .. '/?.lua;' .. lua_root .. '/?/init.lua"',
    '--cmd',
    'set noswapfile',
  })

  for _, item in ipairs(listify(commands)) do
    command[#command + 1] = '-c'
    command[#command + 1] = item
  end

  command[#command + 1] = '-c'
  command[#command + 1] = 'qa!'

  local output = vim.fn.system(command)
  local code = vim.v.shell_error
  vim.fn.delete(temp_root, 'rf')

  return {
    cmd = shelljoin(command),
    code = code,
    output = output,
  }
end

return M
