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

local ORDINARY_ACTION_KINDS = {
  modified = true,
  added = true,
  deleted = true,
  renamed = true,
  untracked = true,
}

local LOG_FIELD_SEPARATOR = string.char(31)
local LOG_RECORD_SEPARATOR = string.char(30)
local DEFAULT_LOG_MAX_COMMITS = 200

M._repo_root = nil
M._repo_root_cwd = nil
M._git_dir = nil
M._git_dir_root = nil

local function empty_files()
  return { staged = {}, changes = {}, untracked = {}, conflicts = {} }
end

local function run_git(args)
  local ok, output = M.run_git_capture(args)
  return ok, output
end

local function repo_root_command_output()
  local result = vim.fn.system('git rev-parse --show-toplevel 2>/dev/null')
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return vim.trim(result)
end

local function normalize_git_dir(root, git_dir)
  if type(git_dir) ~= 'string' or git_dir == '' then
    return nil
  end

  if git_dir:sub(1, 1) == '/' then
    return git_dir
  end

  return root .. '/' .. git_dir
end

local function git_dir_command_output(root)
  if not root or root == '' then
    return nil
  end

  local output = vim.fn.system({ 'git', '-C', root, 'rev-parse', '--git-dir' })
  if vim.v.shell_error ~= 0 then
    return nil
  end

  return normalize_git_dir(root, vim.trim(output))
end

local function git_dir_at_root(root)
  if not root or root == '' then
    return nil
  end

  if M._git_dir and M._git_dir_root == root then
    return M._git_dir
  end

  M._git_dir_root = root
  M._git_dir = git_dir_command_output(root)
  return M._git_dir
end

local function format_timespec(spec)
  if type(spec) == 'table' then
    return tostring(spec.sec or 0) .. ':' .. tostring(spec.nsec or 0)
  end

  return tostring(spec or 0)
end

local function index_signature_at_root(root)
  local git_dir = git_dir_at_root(root)
  if not git_dir then
    return ''
  end

  local stat = vim.uv.fs_stat(git_dir .. '/index')
  if not stat then
    return ''
  end

  return table.concat({
    tostring(stat.size or 0),
    format_timespec(stat.mtime),
    format_timespec(stat.ctime),
  }, ':')
end

local function run_git_capture_at_root_async(root, args, opts, callback)
  local cmd = { 'git', '-C', root }
  vim.list_extend(cmd, args)
  local schedule_callback = opts == nil or opts.schedule_callback ~= false

  vim.system(cmd, { text = true }, function(result)
    local output = result.stdout or ''
    local allowed_codes = (opts and opts.allowed_codes) or { 0 }
    local function deliver(...)
      if schedule_callback then
        local argv = { ... }
        vim.schedule(function()
          callback(unpack(argv))
        end)
        return
      end
      callback(...)
    end

    if not vim.tbl_contains(allowed_codes, result.code) then
      local message = vim.trim(output ~= '' and output or (result.stderr or ''))
      if message == '' then
        message = 'git command failed'
      end
      deliver(false, message)
      return
    end

    deliver(true, output)
  end)
end

local function run_git_capture_at_root(root, args, opts)
  local cmd = { 'git', '-C', root }
  vim.list_extend(cmd, args)

  local result = vim.system(cmd, { text = true }):wait()
  local allowed_codes = (opts and opts.allowed_codes) or { 0 }
  local stdout = result.stdout or ''
  local stderr = result.stderr or ''

  if not vim.tbl_contains(allowed_codes, result.code) then
    local message = vim.trim(stdout ~= '' and stdout or stderr)
    if message == '' then
      message = 'git command failed'
    end
    return false, message
  end

  if stdout ~= '' then
    return true, stdout
  end

  return true, stderr
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

local function split_lines(output)
  if type(output) ~= 'string' or output == '' then
    return {}
  end

  local lines = vim.split(output, '\n', {
    plain = true,
    trimempty = false,
  })
  if lines[#lines] == '' then
    table.remove(lines)
  end
  return lines
end

local function trim_log_field(value)
  if type(value) ~= 'string' then
    return value
  end

  return (value:gsub('^[\r\n]+', ''):gsub('[\r\n]+$', ''))
end

local function log_max_commits(opts)
  local value = opts and opts.max_commits or nil
  if type(value) == 'number' and value >= 1 and value % 1 == 0 then
    return value
  end

  return DEFAULT_LOG_MAX_COMMITS
end

local function is_no_commits_error(message)
  if type(message) ~= 'string' or message == '' then
    return false
  end

  local lower = message:lower()
  return lower:find('does not have any commits yet', 1, true) ~= nil
    or lower:find('bad default revision', 1, true) ~= nil
end

function M.parse_log_entries(output)
  local entries = {}
  if type(output) ~= 'string' or output == '' then
    return entries
  end

  for record in output:gmatch('([^' .. LOG_RECORD_SEPARATOR .. ']+)') do
    local fields = vim.split(record, LOG_FIELD_SEPARATOR, {
      plain = true,
      trimempty = false,
    })

    if #fields >= 6 then
      for index, field in ipairs(fields) do
        fields[index] = trim_log_field(field)
      end
    end

    if #fields >= 6 and fields[1] ~= '' then
      entries[#entries + 1] = {
        hash = fields[1],
        short_hash = fields[2],
        decorations = fields[3],
        author_name = fields[4],
        relative_date = fields[5],
        subject = fields[6],
      }
    end
  end

  return entries
end

function M.get_log_entries(opts)
  local ok, output = M.run_git_capture({
    '--no-pager',
    'log',
    '--max-count=' .. tostring(log_max_commits(opts)),
    '--decorate=short',
    '--date=relative',
    '--format=%H%x1f%h%x1f%D%x1f%an%x1f%ar%x1f%s%x1e',
  })

  if not ok then
    if is_no_commits_error(output) then
      return {}
    end
    return nil, output
  end

  return M.parse_log_entries(output)
end

function M.get_commit_preview(oid)
  local ok, output = M.run_git_capture({
    '--no-pager',
    'show',
    '--stat',
    '--patch',
    '--decorate=short',
    '--color=never',
    '--format=fuller',
    oid,
  })

  if not ok then
    return nil, output
  end

  return split_lines(output)
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
  local cwd = vim.uv.cwd()
  if M._repo_root
    and M._repo_root ~= ''
    and M._repo_root_cwd == cwd
  then
    return M._repo_root
  end

  M._repo_root_cwd = cwd
  M._repo_root = repo_root_command_output()
  return M._repo_root
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
  return M.get_status_snapshot().files
end

local function snapshot_key(output, head_oid, index_signature)
  return table.concat({
    output or '',
    head_oid or '',
    index_signature or '',
  }, '\0')
end

local function build_status_snapshot(output, head_oid, opts)
  opts = opts or {}
  output = output or ''
  local index_signature = opts.index_signature
  if index_signature == nil then
    index_signature = index_signature_at_root(opts.root or M.repo_root())
  end
  return {
    output = output,
    head_oid = head_oid,
    index_signature = index_signature,
    key = snapshot_key(output, head_oid, index_signature),
    files = M.build_file_sections(M.parse_porcelain_entries(output)),
  }
end

local function empty_snapshot()
  return build_status_snapshot('', nil, {
    index_signature = '',
  })
end

function M.head_oid()
  local ok, output = M.run_git_capture({ 'rev-parse', '--verify', '-q', 'HEAD' }, {
    allowed_codes = { 0, 1 },
  })
  if not ok then
    return nil
  end

  local oid = vim.trim(output)
  if oid == '' then
    return nil
  end

  return oid
end

function M.get_status_snapshot()
  local root = M.repo_root()
  if not root then
    return empty_snapshot()
  end

  local ok, output = run_git({ 'status', '--porcelain=v1', '--untracked-files=all' })
  if not ok then
    return empty_snapshot()
  end

  return build_status_snapshot(output, M.head_oid(), {
    root = root,
  })
end

function M.get_status_snapshot_async(callback, opts)
  opts = opts or {}
  local root = opts.root or M.repo_root()
  if not root then
    if opts.schedule_callback == false then
      callback(empty_snapshot())
    else
      vim.schedule(function()
        callback(empty_snapshot())
      end)
    end
    return
  end

  run_git_capture_at_root_async(root, { 'status', '--porcelain=v1', '--untracked-files=all' }, {
    schedule_callback = opts.schedule_callback,
  }, function(ok, output)
    if not ok then
      callback(empty_snapshot())
      return
    end

    run_git_capture_at_root_async(root, { 'rev-parse', '--verify', '-q', 'HEAD' }, {
      allowed_codes = { 0, 1 },
      schedule_callback = opts.schedule_callback,
    }, function(head_ok, head_output)
      local head_oid = nil
      if head_ok then
        head_oid = vim.trim(head_output)
        if head_oid == '' then
          head_oid = nil
        end
      end

      callback(build_status_snapshot(output, head_oid, {
        root = root,
      }))
    end)
  end)
end

function M.git_dir()
  return git_dir_at_root(M.repo_root())
end

function M.repo_watch_paths()
  local git_dir = M.git_dir()
  if not git_dir then
    return {}
  end

  local candidates = {
    git_dir .. '/HEAD',
    git_dir .. '/index',
    git_dir .. '/packed-refs',
  }

  local ok, output = M.run_git_capture({ 'symbolic-ref', '-q', 'HEAD' }, {
    allowed_codes = { 0, 1 },
  })
  if ok then
    local ref = vim.trim(output)
    if ref ~= '' then
      candidates[#candidates + 1] = git_dir .. '/' .. ref
    end
  end

  local paths = {}
  local seen = {}
  for _, path in ipairs(candidates) do
    if not seen[path] and vim.uv.fs_stat(path) then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end

  table.sort(paths)
  return paths
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

function M.entry_paths(file)
  local paths = {}
  local seen = {}
  local function add_path(path)
    if type(path) == 'string' and path ~= '' and not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end

  if type(file) ~= 'table' then
    return paths
  end

  add_path(file.old_path)
  add_path(file.path)

  return paths
end

local function entry_binary_args(file)
  if type(file) ~= 'table' or type(file.path) ~= 'string' or file.path == '' then
    return nil
  end

  if file.section == 'staged' then
    local args = { 'diff', '--cached', '--numstat', '--' }
    vim.list_extend(args, M.entry_paths(file))
    return args
  end

  if file.section == 'changes' or file.section == 'conflicts' then
    local args = { 'diff', '--numstat', '--' }
    vim.list_extend(args, M.entry_paths(file))
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

--- Resolve and memoize the binary state for a file entry when needed.
--- @param file table|nil
--- @return boolean
function M.ensure_file_binary(file)
  if type(file) ~= 'table' then
    return false
  end

  if file.is_binary == true then
    return true
  end

  local is_binary = M.entry_is_binary(file)
  file.is_binary = is_binary
  return is_binary
end

local function cat_file_size(ref, path)
  if type(path) ~= 'string' or path == '' then
    return nil
  end

  local object = ref == ':' and (':' .. path) or (ref .. ':' .. path)
  local ok, output = M.run_git_capture({ 'cat-file', '-s', object }, {
    allowed_codes = { 0, 128 },
  })
  if not ok then
    return nil
  end

  return tonumber(vim.trim(output))
end

local function mode_to_type(mode)
  if mode == '100644' or mode == '100755' then
    return 'regular file'
  end
  if mode == '120000' then
    return 'symlink'
  end
  if mode == '160000' then
    return 'submodule'
  end
  return 'unknown'
end

local function stat_type_to_type(stat_type)
  if stat_type == 'file' then
    return 'regular file'
  end
  if stat_type == 'link' then
    return 'symlink'
  end
  if stat_type == 'directory' then
    return 'directory'
  end
  return 'unknown'
end

local function first_mode_field(output)
  local line = split_lines(output)[1]
  if type(line) ~= 'string' or line == '' then
    return nil
  end

  return line:match('^(%d+)')
end

local function trimmed_output(output)
  local text = vim.trim(output or '')
  if text == '' then
    return nil
  end
  return text
end

local function has_copy_summary(output)
  for line in (output or ''):gmatch('[^\n]+') do
    local lower = line:lower()
    if lower:match('^%s*copy ')
      or lower:find('copy from', 1, true)
      or lower:find('copy to', 1, true)
      or lower:find('similarity index', 1, true)
    then
      return true
    end
  end

  return false
end

function M.get_binary_info(file)
  local info = {
    old_size = nil,
    new_size = nil,
  }

  if type(file) ~= 'table' then
    return info
  end

  local root = M.repo_root()
  local old_path = file.old_path or file.path

  if file.section == 'staged' then
    info.old_size = cat_file_size('HEAD', old_path)
    info.new_size = cat_file_size(':', file.path)
    return info
  end

  if file.section == 'changes' then
    info.old_size = cat_file_size(':', old_path)
    if root then
      local stat = vim.uv.fs_stat(root .. '/' .. file.path)
      info.new_size = stat and stat.size or nil
    end
    return info
  end

  if file.section == 'untracked' or file.kind == 'untracked' then
    if root then
      local stat = vim.uv.fs_stat(root .. '/' .. file.path)
      info.new_size = stat and stat.size or nil
    end
  end

  return info
end

function M.get_diff_stat(file)
  if type(file) ~= 'table' then
    return ''
  end

  local args
  if file.section == 'staged' then
    args = { 'diff', '--cached', '--stat', '--summary', '--find-copies-harder', '--' }
  elseif file.section == 'changes' then
    args = { 'diff', '--stat', '--summary', '--find-copies-harder', '--' }
  else
    return ''
  end

  vim.list_extend(args, M.entry_paths(file))
  local ok, output = M.run_git_capture(args, { allowed_codes = { 0, 1 } })
  if not ok then
    return ''
  end

  local text = trimmed_output(output)
  if not text or not has_copy_summary(text) then
    return ''
  end

  return text
end

function M.get_type_change_info(file)
  local info = {
    old_type = 'unknown',
    new_type = 'unknown',
    diff_text = nil,
  }

  if type(file) ~= 'table' then
    return info
  end

  local old_path = file.old_path or file.path
  local ok_old, old_output = M.run_git_capture({ 'ls-tree', 'HEAD', '--', old_path }, {
    allowed_codes = { 0, 128 },
  })
  if ok_old then
    info.old_type = mode_to_type(first_mode_field(old_output))
  end

  if file.section == 'staged' then
    local ok_new, new_output = M.run_git_capture({ 'ls-files', '-s', '--', file.path }, {
      allowed_codes = { 0 },
    })
    if ok_new then
      info.new_type = mode_to_type(first_mode_field(new_output))
    end
  else
    local root = M.repo_root()
    if root then
      local stat = vim.uv.fs_lstat(root .. '/' .. file.path)
      if stat then
        info.new_type = stat_type_to_type(stat.type)
      end
    end
  end

  local diff_args
  if file.section == 'staged' then
    diff_args = { 'diff', '--cached', '--' }
  elseif file.section == 'changes' then
    diff_args = { 'diff', '--' }
  end

  if diff_args then
    vim.list_extend(diff_args, M.entry_paths(file))
    local ok_diff, diff_output = M.run_git_capture(diff_args, { allowed_codes = { 0, 1 } })
    if ok_diff then
      info.diff_text = trimmed_output(diff_output)
    end
  end

  return info
end

M.UNSUPPORTED_DISCARD_MESSAGE = 'glance: discard is not supported for this git state yet'
M.UNSUPPORTED_STAGE_MESSAGE = 'glance: stage is not supported for this git state yet'
M.UNSUPPORTED_UNSTAGE_MESSAGE = 'glance: unstage is not supported for this git state yet'
M.INVALID_STAGE_TARGET_MESSAGE = 'glance: selected file is not stageable from this section'
M.INVALID_UNSTAGE_TARGET_MESSAGE = 'glance: selected file is not unstageable from this section'
M.NO_STAGED_COMMIT_MESSAGE = 'glance: there are no staged changes to commit'
M.CONFLICT_COMMIT_MESSAGE = 'glance: commit is not possible while conflicts are unresolved'
M.EMPTY_COMMIT_MESSAGE = 'glance: commit message cannot be empty'

function M.infer_stage_kind(file)
  if type(file) ~= 'table' then
    return 'unsupported'
  end

  if type(file.kind) == 'string' and file.kind ~= '' then
    return file.kind
  end

  if file.section == 'conflicts' or file.status == 'U' then
    return 'conflicted'
  end
  if file.status == '?' then
    return 'untracked'
  end
  if file.status == 'D' then
    return 'deleted'
  end
  if file.status == 'R' then
    return 'renamed'
  end
  if file.status == 'C' then
    return 'copied'
  end
  if file.status == 'T' then
    return 'type_changed'
  end
  if file.status == 'A' then
    return 'added'
  end
  if file.status == 'M' then
    return 'modified'
  end

  return 'unsupported'
end

--- Check whether a single file entry is safe to discard with current release semantics.
--- @param file table|nil
--- @return boolean, string|nil
function M.can_discard_file(file)
  if type(file) ~= 'table' or type(file.path) ~= 'string' or file.path == '' then
    return false, 'invalid file target'
  end

  if M.ensure_file_binary(file) then
    return false, M.UNSUPPORTED_DISCARD_MESSAGE
  end

  local kind = M.infer_stage_kind(file)
  if not ORDINARY_ACTION_KINDS[kind] then
    return false, M.UNSUPPORTED_DISCARD_MESSAGE
  end

  return true
end

--- Check whether a single file entry is stageable with current release semantics.
--- @param file table|nil
--- @return boolean, string|nil
function M.can_stage_file(file)
  if type(file) ~= 'table' or type(file.path) ~= 'string' or file.path == '' then
    return false, 'invalid file target'
  end

  local kind = M.infer_stage_kind(file)
  if kind == 'conflicted' or not ORDINARY_ACTION_KINDS[kind] then
    return false, M.UNSUPPORTED_STAGE_MESSAGE
  end

  if file.section ~= 'changes' and file.section ~= 'untracked' then
    return false, M.INVALID_STAGE_TARGET_MESSAGE
  end

  return true
end

--- Check whether a single file entry is unstageable with current release semantics.
--- @param file table|nil
--- @return boolean, string|nil
function M.can_unstage_file(file)
  if type(file) ~= 'table' or type(file.path) ~= 'string' or file.path == '' then
    return false, 'invalid file target'
  end

  local kind = M.infer_stage_kind(file)
  if kind == 'conflicted' or not ORDINARY_ACTION_KINDS[kind] or kind == 'untracked' then
    return false, M.UNSUPPORTED_UNSTAGE_MESSAGE
  end

  if file.section ~= 'staged' then
    return false, M.INVALID_UNSTAGE_TARGET_MESSAGE
  end

  return true
end

--- Check whether the current repo state is safe for a staged-only commit.
--- @param files table|nil
--- @return boolean, string|nil
function M.can_commit(files)
  files = files or M.get_changed_files()
  if type(files) ~= 'table' then
    return false, 'invalid files table'
  end

  if #(files.conflicts or {}) > 0 then
    return false, M.CONFLICT_COMMIT_MESSAGE
  end

  if #(files.staged or {}) == 0 then
    return false, M.NO_STAGED_COMMIT_MESSAGE
  end

  return true
end

local function normalize_commit_message(message)
  local text = ''

  if type(message) == 'table' then
    text = table.concat(message, '\n')
  elseif type(message) == 'string' then
    text = message
  end

  text = text:gsub('\r\n?', '\n')

  local lines = vim.split(text, '\n', { plain = true })
  while #lines > 0 and vim.trim(lines[1]) == '' do
    table.remove(lines, 1)
  end
  while #lines > 0 and vim.trim(lines[#lines]) == '' do
    table.remove(lines)
  end

  if #lines == 0 then
    return nil, M.EMPTY_COMMIT_MESSAGE
  end

  return table.concat(lines, '\n') .. '\n'
end

local function write_commit_message_file(path, text)
  local file, err = io.open(path, 'w')
  if not file then
    return false, err or 'failed to open commit message temp file'
  end

  local ok, write_err = pcall(function()
    file:write(text)
  end)
  file:close()

  if not ok then
    return false, write_err
  end

  return true
end

--- Check whether the current repo state is safe for discard-all.
--- @param files table|nil
--- @return boolean, string|nil, table|nil
function M.can_discard_all(files)
  files = files or M.get_changed_files()
  if type(files) ~= 'table' then
    return false, 'invalid files table'
  end

  for _, section in ipairs({ 'conflicts', 'staged', 'changes', 'untracked' }) do
    for _, file in ipairs(files[section] or {}) do
      local ok, err = M.can_discard_file(file)
      if not ok then
        return false, err, file
      end
    end
  end

  return true
end

--- Check whether the current repo state is safe for stage-all.
--- @param files table|nil
--- @return boolean, string|nil, table|nil
function M.can_stage_all(files)
  files = files or M.get_changed_files()
  if type(files) ~= 'table' then
    return false, 'invalid files table'
  end

  for _, section in ipairs({ 'conflicts', 'staged', 'changes', 'untracked' }) do
    for _, file in ipairs(files[section] or {}) do
      local kind = M.infer_stage_kind(file)
      if kind == 'conflicted' or not ORDINARY_ACTION_KINDS[kind] then
        return false, M.UNSUPPORTED_STAGE_MESSAGE, file
      end
    end
  end

  return true
end

--- Check whether the current repo state is safe for unstage-all.
--- @param files table|nil
--- @return boolean, string|nil, table|nil
function M.can_unstage_all(files)
  files = files or M.get_changed_files()
  if type(files) ~= 'table' then
    return false, 'invalid files table'
  end

  for _, file in ipairs(files.conflicts or {}) do
    return false, M.UNSUPPORTED_UNSTAGE_MESSAGE, file
  end

  for _, file in ipairs(files.staged or {}) do
    local kind = M.infer_stage_kind(file)
    if kind == 'conflicted' or not ORDINARY_ACTION_KINDS[kind] or kind == 'untracked' then
      return false, M.UNSUPPORTED_UNSTAGE_MESSAGE, file
    end
  end

  return true
end

--- Stage all git-visible changes for a single file path set.
--- @param file { path: string, old_path: string|nil }|nil
--- @return boolean, string|nil
function M.stage_file(file)
  local allowed, reason = M.can_stage_file(file)
  if not allowed then
    return false, reason
  end

  local args = { 'add', '-A', '--' }
  vim.list_extend(args, M.entry_paths(file))
  return run_git(args)
end

--- Unstage all git-visible changes for a single file path set.
--- @param file { path: string, old_path: string|nil }|nil
--- @return boolean, string|nil
function M.unstage_file(file)
  local allowed, reason = M.can_unstage_file(file)
  if not allowed then
    return false, reason
  end

  local args = { 'reset', 'HEAD', '--' }
  vim.list_extend(args, M.entry_paths(file))
  return run_git(args)
end

--- Stage all visible repo changes when the current repo state is supported.
--- @param files table|nil
--- @return boolean, string|nil
function M.stage_all(files)
  local allowed, reason = M.can_stage_all(files)
  if not allowed then
    return false, reason
  end

  return run_git({ 'add', '-A' })
end

--- Unstage all staged repo changes when the current repo state is supported.
--- @param files table|nil
--- @return boolean, string|nil
function M.unstage_all(files)
  local allowed, reason = M.can_unstage_all(files)
  if not allowed then
    return false, reason
  end

  return run_git({ 'reset', 'HEAD', '--', '.' })
end

--- Commit the current index with a message body written outside the repo root.
--- @param message string|string[]
--- @param files table|nil
--- @return boolean, string|nil
function M.commit(message, files)
  local allowed, reason = M.can_commit(files)
  if not allowed then
    return false, reason
  end

  local normalized, message_err = normalize_commit_message(message)
  if not normalized then
    return false, message_err
  end

  local root = M.repo_root()
  if not root then
    return false, 'not a git repository'
  end

  local temp_path = vim.fn.tempname()
  local wrote_message, write_err = write_commit_message_file(temp_path, normalized)
  if not wrote_message then
    pcall(vim.fn.delete, temp_path)
    return false, tostring(write_err)
  end

  local ok, err = run_git_capture_at_root(root, { 'commit', '--file', temp_path })
  pcall(vim.fn.delete, temp_path)

  if not ok then
    return false, err
  end

  return true
end

--- Discard all git-visible changes for a single file path.
--- This restores tracked files to HEAD and removes new files not present in HEAD.
--- @param file { path: string, old_path: string|nil }|nil
--- @return boolean, string|nil
function M.discard_file(file)
  local allowed, reason = M.can_discard_file(file)
  if not allowed then
    return false, reason
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
  local allowed, reason = M.can_discard_all()
  if not allowed then
    return false, reason
  end

  local ok, err = run_git({ 'reset', '--hard', 'HEAD' })
  if not ok then
    return false, err
  end

  return run_git({ 'clean', '-fd' })
end

return M
