local M = {}

local function join_path(...)
  return table.concat({ ... }, '/')
end

local function ensure_parent_dir(path)
  local parent = vim.fn.fnamemodify(path, ':h')
  if parent ~= '.' and parent ~= '' then
    vim.fn.mkdir(parent, 'p')
  end
end

local function run_command(args)
  local output = vim.fn.system(args)
  if vim.v.shell_error ~= 0 then
    error(table.concat(args, ' ') .. '\n' .. output)
  end
  return output
end

local function git(root, args)
  local command = { 'git', '-C', root }
  vim.list_extend(command, args)
  return run_command(command)
end

local function write_file(path, content, mode)
  ensure_parent_dir(path)
  local file = assert(io.open(path, mode or 'w'))
  file:write(content)
  file:close()
end

local function new_fixture(root)
  local fixture = {
    temp_dir = root,
    root = root,
    files = {},
  }

  function fixture:path(relpath)
    return join_path(self.root, relpath)
  end

  function fixture:git(args)
    return git(self.root, args)
  end

  function fixture:write(relpath, content, mode)
    write_file(self:path(relpath), content, mode)
  end

  function fixture:append(relpath, content)
    write_file(self:path(relpath), content, 'a')
  end

  function fixture:read(relpath)
    local file = assert(io.open(self:path(relpath), 'rb'))
    local content = file:read('*a')
    file:close()
    return content
  end

  function fixture:remove(relpath)
    vim.fn.delete(self:path(relpath), 'rf')
  end

  function fixture:rename(from_relpath, to_relpath)
    ensure_parent_dir(self:path(to_relpath))
    assert(os.rename(self:path(from_relpath), self:path(to_relpath)))
  end

  function fixture:stage(...)
    local paths = { ... }
    if #paths == 0 then
      return self:git({ 'add', '-A' })
    end

    local args = { 'add', '--' }
    vim.list_extend(args, paths)
    return self:git(args)
  end

  function fixture:stage_all()
    return self:git({ 'add', '-A' })
  end

  function fixture:commit_all(message)
    self:stage_all()
    return self:git({ 'commit', '-m', message or 'Test fixture commit' })
  end

  function fixture:cleanup()
    vim.fn.delete(self.root, 'rf')
  end

  return fixture
end

local function init_repo()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  root = vim.loop.fs_realpath(root) or root
  git(root, { 'init' })
  git(root, { 'config', 'user.name', 'Glance Tests' })
  git(root, { 'config', 'user.email', 'glance-tests@example.com' })
  return root
end

local function seed_committed_file(fixture, relpath, content, key)
  fixture.files[key or 'tracked'] = relpath
  fixture:write(relpath, content)
  fixture:stage(relpath)
  fixture:git({ 'commit', '-m', 'Seed fixture' })
end

local scenarios = {}

function scenarios.repo_no_changes(fixture)
  seed_committed_file(fixture, 'tracked.txt', 'alpha\nbeta\ngamma\n')
end

function scenarios.repo_modified(fixture)
  seed_committed_file(fixture, 'tracked.txt', 'alpha\nbeta\ngamma\n')
  fixture:write(fixture.files.tracked, 'alpha\nbeta modified\ngamma\n')
end

function scenarios.repo_staged(fixture)
  seed_committed_file(fixture, 'tracked.txt', 'alpha\nbeta\ngamma\n')
  fixture:write(fixture.files.tracked, 'alpha\nbeta staged\ngamma\n')
  fixture:stage(fixture.files.tracked)
end

function scenarios.repo_mixed_mm(fixture)
  seed_committed_file(fixture, 'tracked.txt', 'alpha\nbeta\ngamma\n')
  fixture:write(fixture.files.tracked, 'alpha\nbeta staged\ngamma\n')
  fixture:stage(fixture.files.tracked)
  fixture:write(fixture.files.tracked, 'alpha\nbeta staged\ngamma\nunstaged tail\n')
end

function scenarios.repo_deleted(fixture)
  seed_committed_file(fixture, 'tracked.txt', 'alpha\nbeta\ngamma\n')
  fixture:remove(fixture.files.tracked)
end

function scenarios.repo_untracked(fixture)
  seed_committed_file(fixture, 'tracked.txt', 'alpha\nbeta\ngamma\n')
  fixture.files.untracked = 'notes/todo.txt'
  fixture:write(fixture.files.untracked, 'todo\n')
end

function scenarios.repo_staged_add(fixture)
  seed_committed_file(fixture, 'tracked.txt', 'alpha\nbeta\ngamma\n')
  fixture.files.staged_add = 'new-file.txt'
  fixture:write(fixture.files.staged_add, 'new staged file\n')
  fixture:stage(fixture.files.staged_add)
end

function scenarios.repo_rename(fixture)
  seed_committed_file(fixture, 'rename-before.txt', 'rename me\n', 'renamed_old')
  fixture.files.renamed_new = 'rename-after.txt'
  fixture:git({ 'mv', fixture.files.renamed_old, fixture.files.renamed_new })
end

function scenarios.repo_binary(fixture)
  seed_committed_file(fixture, 'tracked.txt', 'alpha\nbeta\ngamma\n')
  fixture.files.binary = 'assets/sample.bin'
  fixture:write(fixture.files.binary, string.char(0, 1, 2, 3, 255), 'wb')
end

--- Create a temp git repo fixture for a named scenario.
--- @param scenario_name string
--- @return table
function M.create(scenario_name)
  assert(type(scenario_name) == 'string' and scenario_name ~= '', 'scenario_name is required')

  local scenario = scenarios[scenario_name]
  assert(scenario, 'unknown scenario: ' .. scenario_name)

  local fixture = new_fixture(init_repo())
  scenario(fixture)
  return fixture
end

function M.available_scenarios()
  local names = vim.tbl_keys(scenarios)
  table.sort(names)
  return names
end

return M
