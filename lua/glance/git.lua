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

local enrich_conflict_files

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

local function read_trimmed_file(path)
  if type(path) ~= 'string' or path == '' then
    return nil
  end

  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then
    return nil
  end

  local file = io.open(path, 'r')
  if not file then
    return nil
  end

  local content = file:read('*a')
  file:close()
  content = vim.trim(content or '')
  if content == '' then
    return nil
  end

  return content
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
  local system_opts = { text = true }
  if opts and opts.env then
    system_opts.env = opts.env
  end

  vim.system(cmd, system_opts, function(result)
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

  local system_opts = { text = true }
  if opts and opts.env then
    system_opts.env = opts.env
  end

  local result = vim.system(cmd, system_opts):wait()
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

local function ensure_parent_dir(path)
  local parent = vim.fn.fnamemodify(path, ':h')
  if parent ~= '.' and parent ~= '' then
    vim.fn.mkdir(parent, 'p')
  end
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

local function parse_unmerged_stage_output(output)
  local entries = {}
  if type(output) ~= 'string' or output == '' then
    return entries
  end

  for line in output:gmatch('[^\n]+') do
    local mode, oid, stage, path = line:match('^(%d+)%s+([0-9a-f]+)%s+(%d)%s+(.+)$')
    if mode and oid and stage and path then
      entries[#entries + 1] = {
        mode = mode,
        oid = oid,
        stage = tonumber(stage),
        path = path,
      }
    end
  end

  return entries
end

local function entries_by_path(entries)
  local by_path = {}
  for _, entry in ipairs(entries or {}) do
    by_path[entry.path] = by_path[entry.path] or {}
    by_path[entry.path][entry.stage] = entry
  end
  return by_path
end

local function sorted_unique_paths(entries)
  local paths = {}
  local seen = {}
  for _, entry in ipairs(entries or {}) do
    if type(entry.path) == 'string' and entry.path ~= '' and not seen[entry.path] then
      seen[entry.path] = true
      paths[#paths + 1] = entry.path
    end
  end
  table.sort(paths)
  return paths
end

local function group_entries_for_paths(by_path, paths)
  local entries = {}
  for _, path in ipairs(paths or {}) do
    for stage = 1, 3 do
      local entry = by_path[path] and by_path[path][stage] or nil
      if entry then
        entries[#entries + 1] = entry
      end
    end
  end
  return entries
end

local function stage_map(entries)
  local stages = {}
  for _, entry in ipairs(entries or {}) do
    stages[entry.stage] = entry
  end
  return stages
end

local function conflict_group_id(stages, paths)
  local base = stages[1] and stages[1].path or nil
  if base then
    return 'base:' .. base
  end
  return 'paths:' .. table.concat(paths or {}, '\0')
end

local function conflict_display_path(stages, paths)
  if stages[2] and stages[2].path then
    return stages[2].path
  end
  if stages[3] and stages[3].path then
    return stages[3].path
  end
  if stages[1] and stages[1].path then
    return stages[1].path
  end
  return (paths or {})[1]
end

local function conflict_display_status(class)
  local labels = {
    modify_delete = 'MD',
    rename_delete = 'RD',
    rename_rename = 'RR',
    non_text_add_add = 'AA',
    binary = 'B',
  }
  return labels[class] or 'U'
end

local function path_has_conflict_entry(conflict_files, path)
  for _, file in ipairs(conflict_files or {}) do
    if file.path == path then
      return true
    end
  end
  return false
end

local function sort_stage_entries_by_path(entries)
  table.sort(entries, function(left, right)
    if left.path == right.path then
      return left.stage < right.stage
    end
    return tostring(left.path) < tostring(right.path)
  end)
  return entries
end

local function structural_orphan_entries(unmerged_entries, by_path, stage)
  local entries = {}
  for _, entry in ipairs(unmerged_entries or {}) do
    if entry.stage == stage
      and by_path[entry.path]
      and not by_path[entry.path][1]
    then
      entries[#entries + 1] = entry
    end
  end
  return sort_stage_entries_by_path(entries)
end

local function structural_pair_score(base_entry, candidate_entry)
  if base_entry.oid == candidate_entry.oid then
    return 1000
  end
  return 0
end

local function pair_structural_candidates(base_entries, candidate_entries)
  local pairs = {}
  local used_bases = {}
  local used_candidates = {}
  local scored = {}

  for base_index, base_entry in ipairs(base_entries or {}) do
    for candidate_index, candidate_entry in ipairs(candidate_entries or {}) do
      local score = structural_pair_score(base_entry, candidate_entry)
      if score > 0 then
        scored[#scored + 1] = {
          score = score,
          base_index = base_index,
          candidate_index = candidate_index,
          base_entry = base_entry,
          candidate_entry = candidate_entry,
        }
      end
    end
  end

  table.sort(scored, function(left, right)
    if left.score ~= right.score then
      return left.score > right.score
    end
    if left.base_entry.path ~= right.base_entry.path then
      return left.base_entry.path < right.base_entry.path
    end
    return left.candidate_entry.path < right.candidate_entry.path
  end)

  for _, item in ipairs(scored) do
    if not used_bases[item.base_index] and not used_candidates[item.candidate_index] then
      pairs[item.base_entry.path] = item.candidate_entry.path
      used_bases[item.base_index] = true
      used_candidates[item.candidate_index] = true
    end
  end

  local remaining_bases = {}
  local remaining_candidates = {}
  for index, entry in ipairs(base_entries or {}) do
    if not used_bases[index] then
      remaining_bases[#remaining_bases + 1] = entry
    end
  end
  for index, entry in ipairs(candidate_entries or {}) do
    if not used_candidates[index] then
      remaining_candidates[#remaining_candidates + 1] = entry
    end
  end

  -- Some tests synthesize rename conflicts with completely rewritten blobs.
  -- Pair leftovers one-to-one so a candidate can never be cross-wired into every base group.
  for index = 1, math.min(#remaining_bases, #remaining_candidates) do
    pairs[remaining_bases[index].path] = remaining_candidates[index].path
  end

  return pairs
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
  local files = M.build_file_sections(M.parse_porcelain_entries(output))
  if opts.enrich_conflicts ~= false then
    files = enrich_conflict_files(files)
  end

  return {
    output = output,
    head_oid = head_oid,
    index_signature = index_signature,
    key = snapshot_key(output, head_oid, index_signature),
    files = files,
  }
end

local function deliver_status_snapshot(callback, output, head_oid, opts)
  opts = opts or {}
  local function deliver()
    callback(build_status_snapshot(output, head_oid, opts))
  end

  if opts.schedule_callback == false and vim.in_fast_event() then
    vim.schedule(deliver)
    return
  end

  deliver()
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

function M.enrich_status_snapshot(snapshot, opts)
  opts = opts or {}
  snapshot = snapshot or {}
  return build_status_snapshot(snapshot.output, snapshot.head_oid, {
    root = opts.root,
    index_signature = snapshot.index_signature,
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

      deliver_status_snapshot(callback, output, head_oid, {
        root = root,
        schedule_callback = opts.schedule_callback,
        enrich_conflicts = opts.enrich_conflicts,
      })
    end)
  end)
end

function M.git_dir()
  return git_dir_at_root(M.repo_root())
end

function M.get_unmerged_stage_entries(filepath)
  if type(filepath) ~= 'string' or filepath == '' then
    return {}
  end

  local ok, output = M.run_git_capture({ 'ls-files', '-u', '--', filepath })
  if not ok then
    return {}
  end

  local entries = {}
  for _, entry in ipairs(parse_unmerged_stage_output(output)) do
    entries[entry.stage] = entry
  end

  return entries
end

function M.get_all_unmerged_stage_entries()
  local ok, output = M.run_git_capture({ 'ls-files', '-u' })
  if not ok then
    return {}
  end

  return parse_unmerged_stage_output(output)
end

function M.get_blob_text(oid)
  if type(oid) ~= 'string' or oid == '' then
    return ''
  end

  local root = M.repo_root()
  if not root then
    return ''
  end

  local result = vim.system({ 'git', '-C', root, 'cat-file', '-p', oid }):wait()
  if result.code ~= 0 then
    return ''
  end

  return result.stdout or ''
end

function M.blob_is_binary(oid)
  if type(oid) ~= 'string' or oid == '' then
    return false
  end

  local text = M.get_blob_text(oid)
  local temp = vim.fn.tempname()
  local file = io.open(temp, 'wb')
  if not file then
    return text:find('\0', 1, true) ~= nil
  end

  file:write(text or '')
  file:close()

  local result = vim.system({ 'git', 'diff', '--no-index', '--numstat', '--', '/dev/null', temp }, { text = true }):wait()
  vim.fn.delete(temp, 'rf')

  if result.code ~= 0 and result.code ~= 1 then
    return false
  end

  local output = result.stdout or ''
  for line in output:gmatch('[^\n]+') do
    if line:match('^%-\t%-\t') then
      return true
    end
  end

  return false
end

function M.unmerged_stage_entries_are_binary(entries)
  for _, entry in ipairs(entries or {}) do
    if entry.mode ~= '100644' and entry.mode ~= '100755' then
      return true
    end
    if M.blob_is_binary(entry.oid) then
      return true
    end
  end

  return false
end

function M.classify_conflict_entries(entries)
  local stages = stage_map(entries)
  local paths = sorted_unique_paths(entries)
  local class = 'unsupported'

  if stages[1] and stages[2] and stages[3] then
    if stages[2].path ~= stages[3].path then
      class = 'rename_rename'
    elseif M.unmerged_stage_entries_are_binary({ stages[1], stages[2], stages[3] }) then
      class = 'binary'
    else
      class = 'text'
    end
  elseif not stages[1] and stages[2] and stages[3] then
    if M.unmerged_stage_entries_are_binary({ stages[2], stages[3] }) then
      class = 'non_text_add_add'
    else
      class = 'text_add_add'
    end
  elseif stages[1] and (stages[2] or stages[3]) then
    local content = stages[2] or stages[3]
    if content.path == stages[1].path then
      class = 'modify_delete'
    else
      class = 'rename_delete'
    end
  end

  local deleted_side = nil
  if stages[1] and stages[2] and not stages[3] then
    deleted_side = 'theirs'
  elseif stages[1] and stages[3] and not stages[2] then
    deleted_side = 'ours'
  end

  return {
    class = class,
    stage_entries = stages,
    paths = paths,
    base_path = stages[1] and stages[1].path or nil,
    ours_path = stages[2] and stages[2].path or nil,
    theirs_path = stages[3] and stages[3].path or nil,
    display_path = conflict_display_path(stages, paths),
    group_id = conflict_group_id(stages, paths),
    deleted_side = deleted_side,
  }
end

function M.get_conflict_info(file)
  if type(file) ~= 'table' then
    return nil, 'invalid conflict target'
  end

  local all_entries = M.get_all_unmerged_stage_entries()
  local by_path = entries_by_path(all_entries)
  local group_paths = file.conflict_paths
  local entries

  if type(group_paths) == 'table' and #group_paths > 0 then
    entries = group_entries_for_paths(by_path, group_paths)
  elseif type(file.path) == 'string' and file.path ~= '' then
    entries = group_entries_for_paths(by_path, { file.path })
  else
    entries = {}
  end

  if #entries == 0 then
    return nil, 'no unmerged stage entries found'
  end

  local info = M.classify_conflict_entries(entries)
  info.file = file
  return info
end

local function structural_conflict_groups(conflict_files, unmerged_entries)
  local by_path = entries_by_path(unmerged_entries)
  local groups = {}
  local grouped_paths = {}
  local stage1_entries = {}

  for _, entry in ipairs(unmerged_entries or {}) do
    if entry.stage == 1 and not (by_path[entry.path] and (by_path[entry.path][2] or by_path[entry.path][3])) then
      stage1_entries[#stage1_entries + 1] = entry
    end
  end

  sort_stage_entries_by_path(stage1_entries)
  local stage2_pairs = pair_structural_candidates(stage1_entries, structural_orphan_entries(unmerged_entries, by_path, 2))
  local stage3_pairs = pair_structural_candidates(stage1_entries, structural_orphan_entries(unmerged_entries, by_path, 3))

  for _, base_entry in ipairs(stage1_entries) do
    local base_path = base_entry.path
    local paths = { base_path }
    if stage2_pairs[base_path] then
      paths[#paths + 1] = stage2_pairs[base_path]
    end
    if stage3_pairs[base_path] and stage3_pairs[base_path] ~= stage2_pairs[base_path] then
      paths[#paths + 1] = stage3_pairs[base_path]
    end

    if #paths > 1 then
      table.sort(paths)
      local entries = group_entries_for_paths(by_path, paths)
      local info = M.classify_conflict_entries(entries)
      if info.class == 'rename_delete' or info.class == 'rename_rename' then
        groups[#groups + 1] = info
        for _, path in ipairs(paths) do
          grouped_paths[path] = true
        end
      end
    end
  end

  for _, file in ipairs(conflict_files or {}) do
    if not grouped_paths[file.path] then
      local entries = group_entries_for_paths(by_path, { file.path })
      local info = M.classify_conflict_entries(entries)
      if info.class == 'non_text_add_add' or info.class == 'binary' or info.class == 'modify_delete' then
        groups[#groups + 1] = info
        grouped_paths[file.path] = true
      end
    end
  end

  return groups, grouped_paths
end

function enrich_conflict_files(files)
  local conflicts = files and files.conflicts or nil
  if not conflicts or #conflicts == 0 then
    return files
  end

  local unmerged_entries = M.get_all_unmerged_stage_entries()
  if #unmerged_entries == 0 then
    return files
  end

  local groups, grouped_paths = structural_conflict_groups(conflicts, unmerged_entries)
  if #groups == 0 then
    return files
  end

  local next_conflicts = {}
  for _, file in ipairs(conflicts) do
    if not grouped_paths[file.path] then
      next_conflicts[#next_conflicts + 1] = file
    end
  end

  for _, info in ipairs(groups) do
    if info.class ~= 'text' and info.class ~= 'text_add_add' then
      local display_path = info.display_path
      local matching = display_path and path_has_conflict_entry(conflicts, display_path) and display_path or nil
      if not matching then
        for _, path in ipairs(info.paths or {}) do
          if path_has_conflict_entry(conflicts, path) then
            matching = path
            break
          end
        end
      end

      local base_file = nil
      for _, file in ipairs(conflicts) do
        if file.path == matching then
          base_file = file
          break
        end
      end
      base_file = vim.deepcopy(base_file or conflicts[1] or {})
      base_file.path = display_path
      base_file.old_path = info.base_path ~= display_path and info.base_path or nil
      base_file.display_status = conflict_display_status(info.class)
      base_file.kind = 'conflicted'
      base_file.conflict_class = info.class
      base_file.conflict_paths = info.paths
      base_file.conflict_group_id = info.group_id
      next_conflicts[#next_conflicts + 1] = base_file
    end
  end

  table.sort(next_conflicts, function(left, right)
    return tostring(left.path) < tostring(right.path)
  end)
  files.conflicts = next_conflicts
  return files
end

local function ref_name_label(ref)
  local ok, output = M.run_git_capture({ 'name-rev', '--name-only', '--always', ref }, {
    allowed_codes = { 0, 128 },
  })
  if not ok then
    return nil
  end

  local label = vim.trim(output)
  if label == '' or label == 'undefined' or label == ref then
    return nil
  end

  if label:match('^refs/heads/') then
    return label:gsub('^refs/heads/', '')
  end

  return label
end

local function short_ref_oid(ref)
  local ok, output = M.run_git_capture({ 'rev-parse', '--short', ref }, {
    allowed_codes = { 0, 128 },
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

local function ref_display(ref)
  if type(ref) ~= 'string' or ref == '' then
    return nil
  end

  local label = ref_name_label(ref)
  if label and label ~= ref then
    return ref .. ' (' .. label .. ')'
  end

  local oid = short_ref_oid(ref)
  if oid then
    return ref .. ' (' .. oid .. ')'
  end

  return ref
end

function M.get_operation_context()
  local git_dir = M.git_dir()
  if not git_dir then
    return {
      kind = nil,
      prefix = nil,
      ours_ref = 'HEAD',
      ours_display = ref_display('HEAD') or 'HEAD',
      theirs_ref = nil,
      theirs_display = nil,
    }
  end

  local context = {
    kind = nil,
    prefix = nil,
    ours_ref = 'HEAD',
    ours_display = ref_display('HEAD') or 'HEAD',
    theirs_ref = nil,
    theirs_display = nil,
  }

  if vim.uv.fs_stat(git_dir .. '/rebase-merge') or vim.uv.fs_stat(git_dir .. '/rebase-apply') then
    context.kind = 'rebase'
    context.prefix = 'Rebasing'
    if vim.uv.fs_stat(git_dir .. '/REBASE_HEAD') then
      context.theirs_ref = 'REBASE_HEAD'
      context.theirs_display = ref_display('REBASE_HEAD') or 'REBASE_HEAD'
    else
      local onto = read_trimmed_file(git_dir .. '/rebase-merge/onto')
        or read_trimmed_file(git_dir .. '/rebase-apply/onto')
      if onto then
        context.theirs_ref = onto
        context.theirs_display = short_ref_oid(onto) or onto
      end
    end
    return context
  end

  if vim.uv.fs_stat(git_dir .. '/MERGE_HEAD') then
    context.kind = 'merge'
    context.theirs_ref = 'MERGE_HEAD'
    context.theirs_display = ref_display('MERGE_HEAD') or 'MERGE_HEAD'
    return context
  end

  if vim.uv.fs_stat(git_dir .. '/CHERRY_PICK_HEAD') then
    context.kind = 'cherry_pick'
    context.prefix = 'Cherry-picking'
    context.theirs_ref = 'CHERRY_PICK_HEAD'
    context.theirs_display = ref_display('CHERRY_PICK_HEAD') or 'CHERRY_PICK_HEAD'
    return context
  end

  if vim.uv.fs_stat(git_dir .. '/REVERT_HEAD') then
    context.kind = 'revert'
    context.prefix = 'Reverting'
    context.theirs_ref = 'REVERT_HEAD'
    context.theirs_display = ref_display('REVERT_HEAD') or 'REVERT_HEAD'
    return context
  end

  return context
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
--- @return string          Raw file text
function M.get_file_text(filepath, ref)
  if ref == nil then
    -- Read from working tree (disk)
    local root = M.repo_root()
    if not root then
      return ''
    end
    local full_path = root .. '/' .. filepath
    local f = io.open(full_path, 'rb')
    if not f then
      return ''
    end
    local content = f:read('*a')
    f:close()
    return content or ''
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
    return ''
  end

  return result or ''
end

local function split_content_lines(text)
  if type(text) ~= 'string' or text == '' then
    return {}
  end

  local lines = {}
  for line in (text .. '\n'):gmatch('(.-)\n') do
    table.insert(lines, line)
  end
  if #lines > 0 and lines[#lines] == '' then
    table.remove(lines)
  end
  return lines
end

--- Retrieve file content at a specific git ref.
--- @param filepath string  Path relative to repo root
--- @param ref string|nil   "HEAD", ":" (index), or nil (working tree / disk)
--- @return string[]        Lines of file content
function M.get_file_content(filepath, ref)
  return split_content_lines(M.get_file_text(filepath, ref))
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

  local context = M.get_operation_context()
  if context.kind == 'merge' then
    return true
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

--- Stage a completed merge result for a conflicted path.
--- This intentionally bypasses ordinary stage safety, because resolving an
--- unmerged index entry is exactly the operation merge completion needs.
--- @param file { path: string }|nil
--- @return boolean, string|nil
function M.stage_merge_result(file)
  if type(file) ~= 'table' or type(file.path) ~= 'string' or file.path == '' then
    return false, 'invalid file target'
  end

  return run_git({ 'add', '--', file.path })
end

local function conflict_side_entry(info, side)
  if type(info) ~= 'table' or type(info.stage_entries) ~= 'table' then
    return nil
  end

  if side == 'ours' then
    return info.stage_entries[2]
  end
  if side == 'theirs' then
    return info.stage_entries[3]
  end

  return nil
end

local function write_conflict_entry(entry)
  local root = M.repo_root()
  if not root or not entry or type(entry.path) ~= 'string' or entry.path == '' then
    return false, 'invalid conflict entry'
  end

  local path = root .. '/' .. entry.path
  ensure_parent_dir(path)

  local file, open_err = io.open(path, 'wb')
  if not file then
    return false, tostring(open_err)
  end

  file:write(M.get_blob_text(entry.oid))
  file:close()
  return true
end

local function conflict_paths(info)
  local paths = {}
  local seen = {}
  for _, path in ipairs((type(info) == 'table' and info.paths) or {}) do
    if type(path) == 'string' and path ~= '' and not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  return paths
end

function M.special_conflict_side_kind(file_or_info, side)
  local info = file_or_info
  if type(info) == 'table' and not info.stage_entries then
    info = M.get_conflict_info(info)
  end
  if not info then
    return nil
  end

  return conflict_side_entry(info, side) and 'content' or 'deletion'
end

function M.apply_special_conflict_choice(file_or_info, side)
  local info = file_or_info
  if type(info) == 'table' and not info.stage_entries then
    local err
    info, err = M.get_conflict_info(info)
    if not info then
      return false, err
    end
  end

  local entry = conflict_side_entry(info, side)
  local paths = conflict_paths(info)
  if #paths == 0 then
    return false, 'no conflict paths found'
  end

  if entry then
    local ok, err = write_conflict_entry(entry)
    if not ok then
      return false, err
    end

    for _, path in ipairs(paths) do
      if path ~= entry.path then
        delete_worktree_path(path)
      end
    end
    return true
  end

  for _, path in ipairs(paths) do
    delete_worktree_path(path)
  end
  return true
end

function M.complete_special_conflict_choice(file_or_info, side)
  local info = file_or_info
  if type(info) == 'table' and not info.stage_entries then
    local err
    info, err = M.get_conflict_info(info)
    if not info then
      return false, err
    end
  end

  local entry = conflict_side_entry(info, side)
  local paths = conflict_paths(info)
  if #paths == 0 then
    return false, 'no conflict paths found'
  end

  if entry then
    local ok, err = run_git({ 'add', '--', entry.path })
    if not ok then
      return false, err
    end

    local remove_paths = {}
    for _, path in ipairs(paths) do
      if path ~= entry.path then
        remove_paths[#remove_paths + 1] = path
      end
    end

    if #remove_paths > 0 then
      local args = { 'rm', '-f', '--' }
      vim.list_extend(args, remove_paths)
      ok, err = run_git(args)
      if not ok then
        return false, err
      end
    end

    return true
  end

  local args = { 'rm', '-f', '--' }
  vim.list_extend(args, paths)
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

--- Continue the active sequencer-style Git operation.
--- @param context table|nil
--- @return boolean, string|nil
function M.continue_operation(context)
  context = context or M.get_operation_context()
  local kind = context and context.kind or nil

  if kind == 'rebase' then
    return run_git({ '-c', 'core.editor=true', 'rebase', '--continue' })
  end
  if kind == 'cherry_pick' then
    return run_git({ '-c', 'core.editor=true', 'cherry-pick', '--continue' })
  end
  if kind == 'revert' then
    return run_git({ '-c', 'core.editor=true', 'revert', '--continue' })
  end

  return false, 'no continuable git operation is active'
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
