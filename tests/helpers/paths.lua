local source = debug.getinfo(1, 'S').source:sub(2)
local helpers_dir = vim.fs.dirname(vim.fs.normalize(source))
local tests_dir = vim.fs.dirname(helpers_dir)

return {
  helpers = helpers_dir,
  tests = tests_dir,
  root = vim.fs.dirname(tests_dir),
}
