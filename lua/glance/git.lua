local M = {}

--- Check if the current directory is inside a git repository.
function M.is_repo()
  local result = vim.fn.system('git rev-parse --is-inside-work-tree 2>/dev/null')
  return vim.v.shell_error == 0 and vim.trim(result) == 'true'
end

--- Get the root path of the git repository.
function M.repo_root()
  local result = vim.fn.system('git rev-parse --show-toplevel 2>/dev/null')
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return vim.trim(result)
end

--- Parse `git status --porcelain=v1` and categorize files into staged, changes, and untracked.
--- A file can appear in both staged and changes (e.g., MM).
--- @return { staged: table[], changes: table[], untracked: table[] }
function M.get_changed_files()
  local root = M.repo_root()
  if not root then
    return { staged = {}, changes = {}, untracked = {} }
  end

  local output = vim.fn.system('git status --porcelain=v1 2>/dev/null')
  if vim.v.shell_error ~= 0 then
    return { staged = {}, changes = {}, untracked = {} }
  end

  local files = { staged = {}, changes = {}, untracked = {} }

  for line in output:gmatch('[^\n]+') do
    if #line < 4 then
      goto continue
    end

    local x = line:sub(1, 1) -- index status
    local y = line:sub(2, 2) -- working tree status
    local path = line:sub(4)

    -- Handle renamed files: "R  old -> new"
    local old_path = nil
    if x == 'R' or y == 'R' then
      local arrow_pos = path:find(' -> ')
      if arrow_pos then
        old_path = path:sub(1, arrow_pos - 1)
        path = path:sub(arrow_pos + 4)
      end
    end

    -- Untracked
    if x == '?' and y == '?' then
      table.insert(files.untracked, {
        path = path,
        status = '?',
        section = 'untracked',
      })
      goto continue
    end

    -- Staged changes: X is not ' ' and not '?'
    if x ~= ' ' and x ~= '?' then
      table.insert(files.staged, {
        path = path,
        status = x,
        section = 'staged',
        old_path = old_path,
      })
    end

    -- Unstaged changes: Y is not ' ' and not '?'
    if y ~= ' ' and y ~= '?' then
      table.insert(files.changes, {
        path = path,
        status = y,
        section = 'changes',
        old_path = old_path,
      })
    end

    ::continue::
  end

  return files
end

--- Retrieve file content at a specific git ref.
--- @param filepath string  Path relative to repo root
--- @param ref string|nil   "HEAD", ":" (index), or nil (working tree / disk)
--- @return string[]        Lines of file content
function M.get_file_content(filepath, ref)
  if ref == nil then
    -- Read from working tree (disk)
    local root = M.repo_root()
    if not root then
      return {}
    end
    local full_path = root .. '/' .. filepath
    local f = io.open(full_path, 'r')
    if not f then
      return {}
    end
    local content = f:read('*a')
    f:close()
    local lines = {}
    for line in (content .. '\n'):gmatch('(.-)\n') do
      table.insert(lines, line)
    end
    -- Remove trailing empty line from the split
    if #lines > 0 and lines[#lines] == '' then
      table.remove(lines)
    end
    return lines
  end

  -- ref is "HEAD" or ":" (index)
  local git_ref
  if ref == ':' then
    git_ref = ':' .. filepath
  else
    git_ref = ref .. ':' .. filepath
  end

  local result = vim.fn.system('git show ' .. vim.fn.shellescape(git_ref) .. ' 2>/dev/null')
  if vim.v.shell_error ~= 0 then
    return {}
  end

  local lines = {}
  for line in (result .. '\n'):gmatch('(.-)\n') do
    table.insert(lines, line)
  end
  if #lines > 0 and lines[#lines] == '' then
    table.remove(lines)
  end
  return lines
end

--- Check if a file is binary according to git.
--- @param filepath string  Path relative to repo root
--- @return boolean
function M.is_binary(filepath)
  local result = vim.fn.system(
    'git diff --no-index --numstat /dev/null ' .. vim.fn.shellescape(filepath) .. ' 2>/dev/null'
  )
  -- Binary files show "-\t-\t" in numstat output
  return result:match('^%-\t%-\t') ~= nil
end

return M
