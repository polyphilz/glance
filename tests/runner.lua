local paths = require('tests.helpers.paths')
local state = require('tests.helpers.state')
local nvim = require('tests.helpers.nvim')

local M = {}

local function normalize_cases(spec)
  if spec.cases then
    return spec.cases
  end
  return spec
end

local function spec_name(file, spec)
  return spec.name or vim.fs.basename(file)
end

local function case_name(case, index)
  return case.name or ('case #' .. index)
end

local function collect_files(suites)
  local files = {}
  for _, suite in ipairs(suites) do
    local pattern = string.format('%s/%s/*_spec.lua', paths.tests, suite)
    for _, file in ipairs(vim.fn.glob(pattern, false, true)) do
      files[#files + 1] = file
    end
  end
  table.sort(files)
  return files
end

local function safe_reset()
  local ok, err = pcall(state.reset)
  if not ok then
    io.stderr:write('state reset failed: ' .. err .. '\n')
  end
end

function M.run(opts)
  opts = opts or {}
  nvim.bootstrap()

  local suites = opts.suites or { opts.suite or 'unit' }
  local files = collect_files(suites)

  local passed = 0
  local failed = 0
  local failures = {}

  for _, file in ipairs(files) do
    local spec = assert(dofile(file), 'spec must return a table: ' .. file)
    local cases = normalize_cases(spec)

    for index, case in ipairs(cases) do
      io.write(string.format('RUN  %s :: %s\n', spec_name(file, spec), case_name(case, index)))
      safe_reset()

      local ok, err = xpcall(function()
        if spec.before_each then
          spec.before_each()
        end
        case.run()
        if spec.after_each then
          spec.after_each()
        end
      end, debug.traceback)

      safe_reset()

      if ok then
        passed = passed + 1
        io.write('PASS\n')
      else
        failed = failed + 1
        failures[#failures + 1] = {
          file = file,
          case = case_name(case, index),
          err = err,
        }
        io.write('FAIL\n')
      end
    end
  end

  io.write(string.format('\nSummary: %d passed, %d failed\n', passed, failed))

  if failed > 0 then
    for _, failure in ipairs(failures) do
      io.write(string.format('\n%s :: %s\n%s\n', failure.file, failure.case, failure.err))
    end
    vim.cmd('cquit ' .. math.min(failed, 255))
    return
  end

  vim.cmd('qa!')
end

return M
