local source = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))
local helpers_dir = vim.fs.dirname(source)
local tests_dir = vim.fs.dirname(helpers_dir)

return {
  helpers = helpers_dir,
  tests = tests_dir,
  root = vim.fs.dirname(tests_dir),
}
