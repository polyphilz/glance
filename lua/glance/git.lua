local M = {}

local STATUS_KIND_MAP = {
  M = 'modified',
  A = 'added',
  D = 'deleted',
  R = 'renamed',
  C = 'copied',
  T = 'type_changed',
}

local CONFLICT_STATUS_PAIRS = {
  DD = true,
  AU = true,
  UD = true,
  UA = true,
  DU = true,
  AA = true,
  UU = true,
}

local function empty_files()
  return { staged = {}, changes = {}, untracked = {}, conflicts = {} }
end

local function run_git(args)
  local ok, output = M.run_git_capture(args)
  return ok, output
end

function M.run_git_capture(args, opts)
  local root = M.repo_root()
  if not root then
    return false, 'not a git repository'
  end

  local cmd = { 'git', '-C', root }
  vim.list_extend(cmd, args)
  local output = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error
  local allowed_codes = (opts and opts.allowed_codes) or { 0 }
  if not vim.tbl_contains(allowed_codes, exit_code) then
    local message = vim.trim(output)
    if message == '' then
      message = 'git command failed'
    end
    return false, message
  end

  return true, output
end

local function path_exists_at_head(filepath)
  return run_git({ 'cat-file', '-e', 'HEAD:' .. filepath })
end

local function delete_worktree_path(filepath)
  local root = M.repo_root()
  if not root then
    return
  end
  vim.fn.delete(root .. '/' .. filepath, 'rf')
end

local function discard_new_path(filepath)
  run_git({ 'rm', '-f', '--', filepath })
  run_git({ 'rm', '--cached', '-f', '--', filepath })
  delete_worktree_path(filepath)
end

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

local function entry_is_untracked(entry)
  return entry.x == '?' and entry.y == '?'
end

local function entry_is_conflicted(entry)
  return CONFLICT_STATUS_PAIRS[entry.raw_status] == true
end

local function parse_rename_or_copy_path(entry)
  if entry.x ~= 'R' and entry.y ~= 'R' and entry.x ~= 'C' and entry.y ~= 'C' then
    return
  end

  local arrow_pos = entry.path:find(' -> ', 1, true)
  if not arrow_pos then
    return
  end

  entry.old_path = entry.path:sub(1, arrow_pos - 1)
  entry.path = entry.path:sub(arrow_pos + 4)
end

local function build_file_entry(entry, section)
  local classification = M.classify_entry(entry, section)
  return {
    path = entry.path,
    old_path = entry.old_path,
    section = section,
    status = classification.status,
    display_status = classification.display_status,
    kind = classification.kind,
    is_binary = false,
    x = entry.x,
    y = entry.y,
    raw_status = entry.raw_status,
  }
end

--- Parse `git status --porcelain=v1` into raw entries.
--- @param output string
--- @return table[]
function M.parse_porcelain_entries(output)
  local entries = {}
  if type(output) ~= 'string' or output == '' then
    return entries
  end

  for line in output:gmatch('[^\n]+') do
    if #line < 4 then
      goto continue
    end

    local entry = {
      x = line:sub(1, 1),
      y = line:sub(2, 2),
      path = line:sub(4),
    }
    entry.raw_status = entry.x .. entry.y
    parse_rename_or_copy_path(entry)

    table.insert(entries, entry)

    ::continue::
  end

  return entries
end

--- Classify a parsed porcelain entry for a filetree section.
--- @param entry table
--- @param section string|nil
--- @return { kind: string, status: string, display_status: string }
function M.classify_entry(entry, section)
  if type(entry) ~= 'table' then
    return {
      kind = 'unsupported',
      status = 'X',
      display_status = 'X',
    }
  end

  if entry_is_untracked(entry) or section == 'untracked' then
    return {
      kind = 'untracked',
      status = '?',
      display_status = '?',
    }
  end

  if entry_is_conflicted(entry) or section == 'conflicts' then
    return {
      kind = 'conflicted',
      status = 'U',
      display_status = 'U',
    }
  end

  local code
  if section == 'staged' then
    code = entry.x
  elseif section == 'changes' then
    code = entry.y
  else
    code = entry.x ~= ' ' and entry.x or entry.y
  end

  local kind = STATUS_KIND_MAP[code]
  if kind then
    return {
      kind = kind,
      status = code,
      display_status = code,
    }
  end

  code = (type(code) == 'string' and code ~= '' and code ~= ' ') and code or 'X'
  return {
    kind = 'unsupported',
    status = code,
    display_status = code,
  }
end

--- Expand parsed entries into filetree sections.
--- A file can appear in both staged and changes (e.g. `MM`).
--- @param entries table[]
--- @return { staged: table[], changes: table[], untracked: table[], conflicts: table[] }
function M.build_file_sections(entries)
  local files = empty_files()
  if type(entries) ~= 'table' then
    return files
  end

  for _, entry in ipairs(entries) do
    if entry_is_untracked(entry) then
      table.insert(files.untracked, build_file_entry(entry, 'untracked'))
    elseif entry_is_conflicted(entry) then
      table.insert(files.conflicts, build_file_entry(entry, 'conflicts'))
    else
      if entry.x ~= ' ' and entry.x ~= '?' then
        table.insert(files.staged, build_file_entry(entry, 'staged'))
      end

      if entry.y ~= ' ' and entry.y ~= '?' then
        table.insert(files.changes, build_file_entry(entry, 'changes'))
      end
    end
  end

  return files
end

--- Parse, classify, and section `git status --porcelain=v1` output.
--- @param output string
--- @return { staged: table[], changes: table[], untracked: table[], conflicts: table[] }
function M.parse_porcelain_status(output)
  return M.build_file_sections(M.parse_porcelain_entries(output))
end

function M.get_changed_files()
  if not M.repo_root() then
    return empty_files()
  end

  local ok, output = run_git({ 'status', '--porcelain=v1', '--untracked-files=all' })
  if not ok then
    return empty_files()
  end

  local files = M.build_file_sections(M.parse_porcelain_entries(output))
  for _, section in ipairs({ 'conflicts', 'staged', 'changes', 'untracked' }) do
    for _, file in ipairs(files[section]) do
      file.is_binary = M.entry_is_binary(file)
    end
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

local function diff_paths(file)
  local paths = {}

  if type(file.old_path) == 'string' and file.old_path ~= '' then
    table.insert(paths, file.old_path)
  end
  if type(file.path) == 'string' and file.path ~= '' then
    table.insert(paths, file.path)
  end

  return paths
end

local function entry_binary_args(file)
  if type(file) ~= 'table' or type(file.path) ~= 'string' or file.path == '' then
    return nil
  end

  if file.section == 'staged' then
    local args = { 'diff', '--cached', '--numstat', '--' }
    vim.list_extend(args, diff_paths(file))
    return args
  end

  if file.section == 'changes' or file.section == 'conflicts' then
    local args = { 'diff', '--numstat', '--' }
    vim.list_extend(args, diff_paths(file))
    return args
  end

  if file.section == 'untracked' or file.kind == 'untracked' then
    local root = M.repo_root()
    if not root then
      return nil
    end
    return {
      'diff',
      '--no-index',
      '--numstat',
      '--',
      '/dev/null',
      root .. '/' .. file.path,
    }
  end

  return nil
end

--- Check if a file entry is binary according to the diff Glance would show.
--- @param file table
--- @return boolean
function M.entry_is_binary(file)
  local args = entry_binary_args(file)
  if not args then
    return false
  end

  local ok, output = M.run_git_capture(args, { allowed_codes = { 0, 1 } })
  if not ok then
    return false
  end

  -- Binary files show "-\t-\t" in numstat output.
  for line in output:gmatch('[^\n]+') do
    if line:match('^%-\t%-\t') then
      return true
    end
  end

  return false
end

--- Discard all git-visible changes for a single file path.
--- This restores tracked files to HEAD and removes new files not present in HEAD.
--- @param file { path: string, old_path: string|nil }|nil
--- @return boolean, string|nil
function M.discard_file(file)
  if type(file) ~= 'table' or type(file.path) ~= 'string' or file.path == '' then
    return false, 'invalid file target'
  end

  if file.old_path and path_exists_at_head(file.old_path) then
    local ok, err = run_git({ 'restore', '--source=HEAD', '--staged', '--worktree', '--', file.old_path })
    if not ok then
      return false, err
    end
    if file.path ~= file.old_path then
      discard_new_path(file.path)
    end
    return true
  end

  if path_exists_at_head(file.path) then
    return run_git({ 'restore', '--source=HEAD', '--staged', '--worktree', '--', file.path })
  end

  discard_new_path(file.path)
  return true
end

--- Discard all tracked, staged, and untracked changes in the repository.
--- @return boolean, string|nil
function M.discard_all()
  local ok, err = run_git({ 'reset', '--hard', 'HEAD' })
  if not ok then
    return false, err
  end

  return run_git({ 'clean', '-fd' })
end

return M
