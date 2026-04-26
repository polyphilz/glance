local git = require('glance.git')
local config = require('glance.config')
local filetree = require('glance.filetree')
local pane_navigation = require('glance.pane_navigation')
local workspace = require('glance.workspace')

local FILETREE_ROLE = 'filetree'
local OLD_ROLE = 'diff_old'
local NEW_ROLE = 'diff_new'
local COMPAT_ALIAS = {
  old_buf = { role = OLD_ROLE, field = 'buf' },
  old_win = { role = OLD_ROLE, field = 'win' },
  new_buf = { role = NEW_ROLE, field = 'buf' },
  new_win = { role = NEW_ROLE, field = 'win' },
}

local function default_workspace_spec()
  return {
    roles = {
      { role = FILETREE_ROLE, kind = 'sidebar' },
      { role = OLD_ROLE, kind = 'content' },
      { role = NEW_ROLE, kind = 'content' },
    },
    preferred_focus_role = NEW_ROLE,
    editable_role = NEW_ROLE,
  }
end

local state = {
  workspace = workspace.new(vim.tbl_extend('force', { name = 'diffview' }, default_workspace_spec())),
}
local M = setmetatable({
  fs_watcher = nil,
  closing = false,
  autocmd_group = vim.api.nvim_create_augroup('GlanceDiffView', { clear = true }),
}, {
  __index = function(_, key)
    local alias = COMPAT_ALIAS[key]
    if alias then
      if alias.field == 'buf' then
        return workspace.get_buf(state.workspace, alias.role)
      end
      return workspace.get_win(state.workspace, alias.role)
    end

    if key == 'workspace' then
      return state.workspace
    end

    return rawget(_, key)
  end,
  __newindex = function(_, key, value)
    local alias = COMPAT_ALIAS[key]
    if alias then
      if alias.field == 'buf' then
        workspace.set_buf(state.workspace, alias.role, value)
      else
        workspace.set_win(state.workspace, alias.role, value)
      end
      return
    end

    if key == 'workspace' then
      state.workspace = value
      return
    end

    rawset(_, key, value)
  end,
})
local PANEL_NS = vim.api.nvim_create_namespace('glance_panel')
local DELETED_NS = vim.api.nvim_create_namespace('glance_deleted')
local CONFLICT_NS = vim.api.nvim_create_namespace('glance_conflict')

local function filetree_options()
  return config.options.windows.filetree
end

local function diff_options()
  return config.options.windows.diff
end

local function minimap_options()
  return config.options.minimap
end

local function watch_options()
  return config.options.watch
end

local function sync_filetree_pane()
  workspace.set_win(M.workspace, FILETREE_ROLE, filetree.win)
  workspace.set_buf(M.workspace, FILETREE_ROLE, filetree.buf)
end

local function pane_win(role)
  return workspace.get_win(M.workspace, role)
end

local function pane_buf(role)
  return workspace.get_buf(M.workspace, role)
end

local function content_roles()
  return workspace.collect_roles(M.workspace, {
    filter = function(_, _, role_def)
      return role_def.kind == 'content'
    end,
  })
end

local function content_windows()
  return workspace.collect_windows(M.workspace, {
    valid_win = true,
    filter = function(_, _, role_def)
      return role_def.kind == 'content'
    end,
  })
end

local function rightmost_anchor_win()
  local wins = content_windows()
  if #wins > 0 then
    return wins[#wins]
  end
  if filetree.win and vim.api.nvim_win_is_valid(filetree.win) then
    return filetree.win
  end
  return nil
end

local function resize_filetree()
  sync_filetree_pane()
  vim.api.nvim_win_set_width(filetree.win, filetree_options().width)
  vim.api.nvim_win_set_option(filetree.win, 'winfixwidth', filetree_options().winfixwidth)
end

function M.configure_workspace(spec)
  workspace.configure(M.workspace, spec or default_workspace_spec())
  sync_filetree_pane()
end

function M.restore_default_workspace()
  M.configure_workspace(default_workspace_spec())
end

function M.open_workspace_pane(role)
  workspace.register_role(M.workspace, role, { kind = 'content' })
  local anchor = rightmost_anchor_win()
  if anchor and vim.api.nvim_win_is_valid(anchor) then
    vim.api.nvim_set_current_win(anchor)
  end
  vim.cmd('rightbelow vnew')
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  workspace.set_pane(M.workspace, role, {
    win = win,
    buf = buf,
  })
  M.set_win_options(win)
  return win, buf
end

local function open_content_pane(role)
  return M.open_workspace_pane(role)
end

local function open_single_pane()
  return open_content_pane(NEW_ROLE)
end

local function prepare_default_workspace()
  M.restore_default_workspace()
  resize_filetree()
end

local function placeholder_message(file, override)
  if override and override ~= '' then
    return override
  end
  return 'this git state is not supported yet'
end

local function old_content_ref(file)
  if file.section == 'staged' then
    return 'HEAD'
  end
  return ':'
end

local function old_content_path(file)
  if file.old_path then
    return file.old_path
  end
  return file.path
end

local function format_file_size(bytes)
  if type(bytes) ~= 'number' then
    return nil
  end
  if bytes < 1024 then
    return string.format('%d B', bytes)
  end
  if bytes < 1048576 then
    return string.format('%.1f KB', bytes / 1024)
  end
  if bytes < 1073741824 then
    return string.format('%.1f MB', bytes / 1048576)
  end
  return string.format('%.1f GB', bytes / 1073741824)
end

local function section_label(section)
  local labels = {
    staged = 'Staged',
    changes = 'Unstaged',
    untracked = 'Untracked',
    conflicts = 'Conflicts',
  }

  return labels[section] or section or 'Unknown'
end

local function set_window_label(win, label)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  vim.api.nvim_set_option_value('winbar', label or '', { win = win })
end

local function set_path_winbars(file)
  if file and file.old_path then
    set_window_label(M.old_win, 'Old: ' .. file.old_path)
    set_window_label(M.new_win, 'New: ' .. file.path)
    return
  end

  set_window_label(M.old_win, '')
  set_window_label(M.new_win, '')
end

local function set_readonly_lines(buf, lines)
  local readonly = vim.api.nvim_buf_get_option(buf, 'readonly')
  vim.api.nvim_buf_set_option(buf, 'readonly', false)
  vim.api.nvim_buf_set_option(buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(buf, 'readonly', readonly)
end

local function apply_deleted_highlights(buf, line_count)
  vim.api.nvim_buf_clear_namespace(buf, DELETED_NS, 0, -1)
  for i = 0, line_count - 1 do
    vim.api.nvim_buf_add_highlight(buf, DELETED_NS, 'DiffDelete', i, 0, -1)
  end
end

local function set_panel_lines(buf, lines)
  vim.api.nvim_buf_set_option(buf, 'readonly', false)
  vim.api.nvim_buf_set_option(buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(buf, 'readonly', true)
  vim.api.nvim_buf_set_option(buf, 'swapfile', false)
end

local function add_panel_highlight(buf, line, start_col, end_col, group)
  vim.api.nvim_buf_add_highlight(buf, PANEL_NS, group, line, start_col, end_col)
end

local function render_placeholder_panel(buf, file, message)
  vim.api.nvim_buf_clear_namespace(buf, PANEL_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, DELETED_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, CONFLICT_NS, 0, -1)
  local lines = {
    'Glance',
    '',
    'Path: ' .. file.path,
    'Section: ' .. (file.section or 'unknown'),
    'Raw status: ' .. (file.raw_status or file.status or 'unknown'),
    'Kind: ' .. (file.kind or 'unknown'),
  }

  if file.old_path then
    table.insert(lines, 'Old path: ' .. file.old_path)
  end

  table.insert(lines, '')
  table.insert(lines, placeholder_message(file, message))
  set_panel_lines(buf, lines)
end

local function render_binary_panel(buf, file)
  vim.api.nvim_buf_clear_namespace(buf, PANEL_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, DELETED_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, CONFLICT_NS, 0, -1)
  local info = git.get_binary_info(file)
  local old_value = format_file_size(info.old_size) or '—'
  local new_value = format_file_size(info.new_size) or '—'
  local old_prefix = '  Old size   '
  local new_prefix = '  New size   '
  local lines = {
    '  Binary File',
    '',
    '  ' .. file.path,
  }

  if file.old_path then
    lines[#lines + 1] = '  ' .. file.old_path .. ' →'
  end

  lines[#lines + 1] = '  ' .. section_label(file.section)
  lines[#lines + 1] = ''
  lines[#lines + 1] = old_prefix .. old_value
  lines[#lines + 1] = new_prefix .. new_value

  set_panel_lines(buf, lines)
  add_panel_highlight(buf, 0, 0, -1, 'GlanceAccentText')
  if file.old_path then
    add_panel_highlight(buf, 3, 0, -1, 'Comment')
  end

  local section_line = file.old_path and 4 or 3
  local old_size_line = section_line + 2
  local new_size_line = old_size_line + 1

  add_panel_highlight(buf, section_line, 0, -1, 'Comment')
  add_panel_highlight(buf, old_size_line, 0, #old_prefix, 'Comment')
  add_panel_highlight(buf, new_size_line, 0, #new_prefix, 'Comment')
  if old_value == '—' then
    add_panel_highlight(buf, old_size_line, #old_prefix, -1, 'Comment')
  end
  if new_value == '—' then
    add_panel_highlight(buf, new_size_line, #new_prefix, -1, 'Comment')
  end
end

local function render_copied_panel(buf, file)
  vim.api.nvim_buf_clear_namespace(buf, PANEL_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, DELETED_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, CONFLICT_NS, 0, -1)
  local lines = {
    '  Copied File',
    '',
    '  ' .. (file.old_path or 'unknown') .. ' → ' .. file.path,
    '  ' .. section_label(file.section),
  }

  local diff_stat = git.get_diff_stat(file)
  if diff_stat ~= '' then
    lines[#lines + 1] = ''
    for _, line in ipairs(vim.split(diff_stat, '\n', { plain = true, trimempty = true })) do
      lines[#lines + 1] = '  ' .. line
    end
  end

  set_panel_lines(buf, lines)
  add_panel_highlight(buf, 0, 0, -1, 'GlanceAccentText')
  add_panel_highlight(buf, 3, 0, -1, 'Comment')
end

local function render_type_changed_panel(buf, file)
  vim.api.nvim_buf_clear_namespace(buf, PANEL_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, DELETED_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, CONFLICT_NS, 0, -1)
  local info = git.get_type_change_info(file)
  local lines = {
    '  Type Changed',
    '',
    '  ' .. file.path,
    '  ' .. section_label(file.section),
    '',
    '  ' .. info.old_type .. ' → ' .. info.new_type,
  }

  if info.diff_text then
    lines[#lines + 1] = ''
    for _, line in ipairs(vim.split(info.diff_text, '\n', { plain = true, trimempty = true })) do
      lines[#lines + 1] = '  ' .. line
    end
  end

  set_panel_lines(buf, lines)
  add_panel_highlight(buf, 0, 0, -1, 'GlanceAccentText')
  add_panel_highlight(buf, 3, 0, -1, 'Comment')
  add_panel_highlight(buf, 5, 0, -1, 'Comment')
end

local function apply_conflict_highlights(buf)
  vim.api.nvim_buf_clear_namespace(buf, PANEL_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, DELETED_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, CONFLICT_NS, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:match('^<<<<<<<') then
      vim.api.nvim_buf_add_highlight(buf, CONFLICT_NS, 'DiffDelete', i - 1, 0, -1)
    elseif line:match('^=======') then
      vim.api.nvim_buf_add_highlight(buf, CONFLICT_NS, 'DiffChange', i - 1, 0, -1)
    elseif line:match('^>>>>>>>') then
      vim.api.nvim_buf_add_highlight(buf, CONFLICT_NS, 'DiffAdd', i - 1, 0, -1)
    end
  end
end

local function jump_to_next_conflict()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i = cursor[1] + 1, #lines do
    if lines[i]:match('^<<<<<<<') then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end

  for i = 1, cursor[1] do
    if lines[i]:match('^<<<<<<<') then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
end

local function jump_to_prev_conflict()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i = cursor[1] - 1, 1, -1 do
    if lines[i]:match('^<<<<<<<') then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end

  for i = #lines, cursor[1], -1 do
    if lines[i]:match('^<<<<<<<') then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
end

--- Open a standard 2-pane side-by-side diff for a modified file.
function M.open(file)
  local root = git.repo_root()
  if not root then return end

  local old_lines = git.get_file_content(old_content_path(file), old_content_ref(file))

  prepare_default_workspace()

  -- Create the old (left) pane: vertical split to the right of file tree
  open_content_pane(OLD_ROLE)
  M.old_win = pane_win(OLD_ROLE)
  local scratch_buf = vim.api.nvim_get_current_buf()

  -- Set up old buffer: write to temp file with correct extension so
  -- syntax highlighting works identically to the right pane via edit
  local ext = vim.fn.fnamemodify(file.path, ':e')
  local tmpfile = vim.fn.tempname() .. '.' .. ext
  local f = io.open(tmpfile, 'w')
  if f then
    f:write(table.concat(old_lines, '\n'))
    f:close()
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(tmpfile))
  M.old_buf = vim.api.nvim_get_current_buf()
  vim.fn.delete(tmpfile)
  -- Clean up the scratch buffer vnew created
  if vim.api.nvim_buf_is_valid(scratch_buf) and scratch_buf ~= M.old_buf then
    vim.api.nvim_buf_delete(scratch_buf, { force = true })
  end
  -- Make it read-only and non-saveable
  vim.api.nvim_buf_set_option(M.old_buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(M.old_buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(M.old_buf, 'readonly', true)
  vim.api.nvim_buf_set_option(M.old_buf, 'swapfile', false)

  -- Create the new (right) pane: vertical split to the right of old pane
  open_content_pane(NEW_ROLE)
  M.new_win = pane_win(NEW_ROLE)

  -- Open the actual file on disk (editable)
  local full_path = root .. '/' .. file.path
  if file.section == 'staged' then
    -- For staged files, show the index version via temp file (for syntax highlighting)
    local index_lines = git.get_file_content(file.path, ':')
    local new_scratch = vim.api.nvim_get_current_buf()
    local new_ext = vim.fn.fnamemodify(file.path, ':e')
    local new_tmpfile = vim.fn.tempname() .. '.' .. new_ext
    local nf = io.open(new_tmpfile, 'w')
    if nf then
      nf:write(table.concat(index_lines, '\n'))
      nf:close()
    end
    vim.cmd('edit ' .. vim.fn.fnameescape(new_tmpfile))
    M.new_buf = vim.api.nvim_get_current_buf()
    vim.fn.delete(new_tmpfile)
    if vim.api.nvim_buf_is_valid(new_scratch) and new_scratch ~= M.new_buf then
      vim.api.nvim_buf_delete(new_scratch, { force = true })
    end
    vim.api.nvim_buf_set_option(M.new_buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(M.new_buf, 'modifiable', false)
    vim.api.nvim_buf_set_option(M.new_buf, 'readonly', true)
    vim.api.nvim_buf_set_option(M.new_buf, 'swapfile', false)
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(full_path))
    M.new_buf = vim.api.nvim_get_current_buf()
  end

  -- Enable diff mode on both panes
  vim.api.nvim_set_current_win(M.old_win)
  vim.cmd('diffthis')
  vim.api.nvim_set_current_win(M.new_win)
  vim.cmd('diffthis')

  -- Disable diff folding (must be after diffthis which forces foldenable=true)
  vim.api.nvim_win_set_option(M.old_win, 'foldenable', diff_options().foldenable)
  vim.api.nvim_win_set_option(M.new_win, 'foldenable', diff_options().foldenable)

  -- Per-pane diff colors: old=red tones, new=green tones (like VS Code/Cursor)
  vim.api.nvim_win_set_option(M.old_win, 'winhighlight',
    'DiffChange:GlanceDiffChangeOld,DiffText:GlanceDiffTextOld')
  vim.api.nvim_win_set_option(M.new_win, 'winhighlight',
    'DiffChange:GlanceDiffChangeNew,DiffText:GlanceDiffTextNew')
  set_path_winbars(file)

  -- Explicitly size all panes: file tree fixed, diff panes split the rest
  M.equalize_panes()

  -- Focus the new (right) pane
  vim.api.nvim_set_current_win(M.new_win)

  -- Watch for external changes to the file
  if file.section ~= 'staged' and watch_options().enabled then
    M.watch_file(full_path)
  end

  -- Set up autocmds and keymaps
  M.setup_autocmds(file)
  M.bind_buffer_keymaps()

  -- Open diff minimap on the new (right) pane
  if minimap_options().enabled then
    local minimap = require('glance.minimap')
    minimap.open(M.new_win, old_lines)
  end
end

--- Open a single read-only pane for a deleted file.
function M.open_deleted(file)
  local old_ref
  if file.section == 'staged' then
    old_ref = 'HEAD'
  else
    old_ref = ':'
  end

  local lines = git.get_file_content(file.path, old_ref)

  prepare_default_workspace()

  -- Create a single pane
  open_single_pane()
  M.new_buf = vim.api.nvim_get_current_buf()

  local buf_name = 'glance://deleted/' .. file.path
  pcall(vim.api.nvim_buf_set_name, M.new_buf, buf_name)
  vim.api.nvim_buf_set_lines(M.new_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.new_buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(M.new_buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(M.new_buf, 'readonly', true)
  vim.api.nvim_buf_set_option(M.new_buf, 'swapfile', false)
  M.set_filetype_from_path(M.new_buf, file.path)

  -- Highlight all lines as deleted
  apply_deleted_highlights(M.new_buf, #lines)

  M.equalize_panes()
  M.setup_autocmds(file)
  M.bind_buffer_keymaps()
end

--- Open a single editable pane for an untracked file.
function M.open_untracked(file)
  local root = git.repo_root()
  if not root then return end

  prepare_default_workspace()

  -- Create a single pane and open the file
  open_single_pane()

  local full_path = root .. '/' .. file.path
  vim.cmd('edit ' .. vim.fn.fnameescape(full_path))
  M.new_buf = vim.api.nvim_get_current_buf()

  if watch_options().enabled then
    M.watch_file(full_path)
  end

  M.equalize_panes()
  M.setup_autocmds(file)
  M.bind_buffer_keymaps()
end

--- Open a single editable pane for a conflicted working-tree file.
function M.open_conflict(file)
  require('glance.merge').open(M, file)
end

--- Open a single read-only placeholder pane for visible-but-unsupported states.
--- @param file table
--- @param message string|nil
function M.open_placeholder(file, message)
  prepare_default_workspace()
  open_single_pane()
  M.new_buf = vim.api.nvim_get_current_buf()

  local buf_name = 'glance://placeholder/' .. (file.kind or 'unknown') .. '/' .. file.path
  pcall(vim.api.nvim_buf_set_name, M.new_buf, buf_name)
  render_placeholder_panel(M.new_buf, file, message)

  M.equalize_panes()
  M.setup_autocmds(file)
  M.bind_buffer_keymaps()
end

function M.open_binary(file)
  prepare_default_workspace()
  open_single_pane()
  M.new_buf = vim.api.nvim_get_current_buf()

  local buf_name = 'glance://binary/' .. file.path
  pcall(vim.api.nvim_buf_set_name, M.new_buf, buf_name)
  render_binary_panel(M.new_buf, file)

  M.equalize_panes()
  M.setup_autocmds(file)
  M.bind_buffer_keymaps()
end

function M.open_copied(file)
  prepare_default_workspace()
  open_single_pane()
  M.new_buf = vim.api.nvim_get_current_buf()

  local buf_name = 'glance://copied/' .. file.path
  pcall(vim.api.nvim_buf_set_name, M.new_buf, buf_name)
  render_copied_panel(M.new_buf, file)

  M.equalize_panes()
  M.setup_autocmds(file)
  M.bind_buffer_keymaps()
end

function M.open_type_changed(file)
  prepare_default_workspace()
  open_single_pane()
  M.new_buf = vim.api.nvim_get_current_buf()

  local buf_name = 'glance://type_changed/' .. file.path
  pcall(vim.api.nvim_buf_set_name, M.new_buf, buf_name)
  render_type_changed_panel(M.new_buf, file)

  M.equalize_panes()
  M.setup_autocmds(file)
  M.bind_buffer_keymaps()
end

local function check_new_buffer()
  local buf = M.editable_buf()
  local win = M.editable_win()

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  vim.api.nvim_win_call(win, function()
    vim.cmd('silent! checktime')
  end)
end

--- Watch a file on disk and trigger Neovim's native file-change handling immediately.
function M.watch_file(path)
  M.stop_watching()
  local w = vim.uv.new_fs_poll()
  if not w then return end
  M.fs_watcher = w
  w:start(path, watch_options().interval_ms, function(err)
    if err then return end
    vim.schedule(function()
      check_new_buffer()
    end)
  end)
end

--- Stop watching the current file.
function M.stop_watching()
  if M.fs_watcher then
    M.fs_watcher:stop()
    M.fs_watcher:close()
    M.fs_watcher = nil
  end
end

local function collect_view_buffers()
  return workspace.collect_buffers(M.workspace, {
    valid_buf = true,
    filter = function(_, _, role_def)
      return role_def.kind == 'content'
    end,
  })
end

local function collect_diff_buffers()
  return workspace.collect_buffers(M.workspace, {
    valid_buf = true,
    filter = function(_, pane, role_def)
      return role_def.kind == 'content'
        and pane.win ~= nil
        and vim.api.nvim_win_is_valid(pane.win)
        and vim.api.nvim_get_option_value('diff', { win = pane.win })
    end,
  })
end

local function set_buffer_keymap(buf, lhs, rhs)
  if lhs == nil or lhs == '' then
    return
  end

  vim.keymap.set('n', lhs, rhs, {
    noremap = true,
    silent = true,
    buffer = buf,
  })
end

local function jump_hunk(keys)
  return function()
    vim.cmd.normal({ args = { keys }, bang = true })
  end
end

--- Bind buffer-local keymaps on Glance view buffers.
function M.bind_buffer_keymaps()
  local km = config.options.keymaps
  local hunk = config.options.hunk_navigation or {}

  for _, buf in ipairs(collect_view_buffers()) do
    pane_navigation.bind(buf)
    set_buffer_keymap(buf, km.toggle_filetree, function()
      filetree.toggle()
    end)
  end

  for _, buf in ipairs(collect_diff_buffers()) do
    set_buffer_keymap(buf, hunk.next, jump_hunk(']c'))
    set_buffer_keymap(buf, hunk.prev, jump_hunk('[c'))
  end
end

--- Set up autocmds for managing diff view lifecycle.
function M.setup_autocmds(file)
  vim.api.nvim_clear_autocmds({ group = M.autocmd_group })

  -- Track which windows belong to the diff view
  local diff_wins = content_windows()

  -- When any diff window is closed, close them all and return to file tree
  vim.api.nvim_create_autocmd('WinClosed', {
    group = M.autocmd_group,
    callback = function(args)
      local closed_win = tonumber(args.match)
      local is_diff_win = false
      for _, w in ipairs(diff_wins) do
        if w == closed_win then
          is_diff_win = true
          break
        end
      end

      if is_diff_win and not M.closing then
        M.close()
      end
    end,
  })

  local editable_buf = M.editable_buf()
  local merge = package.loaded['glance.merge']
  local merge_active = merge and merge.is_active and merge.is_active()

  -- When the workspace's editable buffer is saved, refresh the diff.
  if editable_buf and vim.api.nvim_buf_get_option(editable_buf, 'buftype') == '' then
      vim.api.nvim_create_autocmd('FileChangedShellPost', {
        group = M.autocmd_group,
        buffer = editable_buf,
        callback = function()
          vim.schedule(function()
            M.refresh(file)
            filetree.note_repo_activity()
          end)
        end,
      })

      if not merge_active then
        vim.api.nvim_create_autocmd('BufWritePost', {
          group = M.autocmd_group,
          buffer = editable_buf,
          callback = function()
            vim.schedule(function()
              M.refresh(file)
              filetree.note_repo_activity()
            end)
          end,
        })
      end
  end
end

function M.content_roles()
  return content_roles()
end

function M.editable_role()
  return workspace.get_editable_role(M.workspace) or content_roles()[#content_roles()]
end

function M.editable_buf()
  local role = M.editable_role()
  return role and pane_buf(role) or nil
end

function M.editable_win()
  local role = M.editable_role()
  return role and pane_win(role) or nil
end

function M.preferred_focus_role()
  return workspace.get_preferred_focus_role(M.workspace) or M.editable_role()
end

function M.content_wins()
  return content_windows()
end

function M.hoverable_separator_wins()
  local merge = package.loaded['glance.merge']
  if merge and merge.is_active and merge.is_active() then
    local wins = merge.hoverable_separator_wins(M)
    if wins then
      return wins
    end
  end

  sync_filetree_pane()

  local wins = {}
  if filetree.win and vim.api.nvim_win_is_valid(filetree.win) then
    wins[#wins + 1] = filetree.win
  end

  local content = content_windows()
  for i = 1, math.max(#content - 1, 0) do
    wins[#wins + 1] = content[i]
  end

  return wins
end

function M.focus_content_pane()
  local role = M.preferred_focus_role()
  local win = role and pane_win(role) or nil
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    return true
  end

  local wins = content_windows()
  if #wins > 0 then
    vim.api.nvim_set_current_win(wins[#wins])
    return true
  end

  return false
end

function M.primary_edit_role()
  return M.editable_role()
end

function M.primary_buf()
  return M.editable_buf()
end

function M.primary_win()
  return M.editable_win()
end

function M.focus_preferred_pane()
  return M.focus_content_pane()
end

function M.reset_workspace()
  workspace.clear(M.workspace)
  sync_filetree_pane()
end

local function workspace_buffer_delete_options(role, buf, discard_new_changes)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  local buftype = vim.api.nvim_buf_get_option(buf, 'buftype')
  if buftype == 'nofile' then
    return { force = true }
  end

  if vim.fn.bufwinid(buf) ~= -1 then
    return nil
  end

  if role == M.editable_role() then
    return { force = discard_new_changes }
  end

  return nil
end

--- Clean up diff windows and buffers, return to file tree.
--- @param force boolean|nil  If true, discard unsaved changes. Otherwise prompt.
function M.close(force)
  if M.closing then
    return
  end
  M.closing = true
  local discard_new_changes = force == true
  local editable_buf = M.editable_buf()
  local editable_win = M.editable_win()

  -- Check for unsaved changes in the workspace's editable buffer before closing.
  if not force
    and editable_buf and vim.api.nvim_buf_is_valid(editable_buf)
    and vim.api.nvim_buf_get_option(editable_buf, 'buftype') == ''
    and vim.api.nvim_buf_get_option(editable_buf, 'modified')
  then
    if editable_win and vim.api.nvim_win_is_valid(editable_win) then
      vim.api.nvim_set_current_win(editable_win)
    end

    local choice = vim.fn.confirm(
      'Save changes?',
      '&Yes\n&No\n&Cancel', 3
    )
    if choice == 1 then
      vim.api.nvim_buf_call(editable_buf, function() vim.cmd('write') end)
    elseif choice == 3 or choice == 0 then
      M.closing = false
      return
    else
      discard_new_changes = true
    end
  end

  local old_lazyredraw = vim.o.lazyredraw
  local ok, err = xpcall(function()
    vim.o.lazyredraw = true

    local minimap = require('glance.minimap')
    minimap.close()

    M.stop_watching()
    vim.api.nvim_clear_autocmds({ group = M.autocmd_group })

    local function safe_diffoff(win)
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        vim.cmd('diffoff')
      end
    end

    for _, win in ipairs(content_windows()) do
      safe_diffoff(win)
    end

    if not filetree.win or not vim.api.nvim_win_is_valid(filetree.win) then
      vim.cmd('topleft vnew')
      local restored_win = vim.api.nvim_get_current_win()
      local scratch_buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_win_set_buf(restored_win, filetree.buf)
      if vim.api.nvim_buf_is_valid(scratch_buf) and scratch_buf ~= filetree.buf then
        vim.api.nvim_buf_delete(scratch_buf, { force = true })
      end
      filetree.win = restored_win
    end
    sync_filetree_pane()

    for _, role in ipairs(content_roles()) do
      local win = pane_win(role)
      local buf = pane_buf(role)

      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end

      local delete_opts = workspace_buffer_delete_options(role, buf, discard_new_changes)
      if delete_opts then
        vim.api.nvim_buf_delete(buf, delete_opts)
      end
    end

    M.reset_workspace()

    local merge = package.loaded['glance.merge']
    if merge and merge.reset then
      merge.reset()
    end

    local ui = require('glance.ui')
    ui.close_diff()
  end, debug.traceback)

  vim.o.lazyredraw = old_lazyredraw
  M.closing = false
  if not ok then
    error(err)
  end
  vim.cmd('redraw')
end

--- Refresh the diff after a save (re-read old content, update diff).
function M.refresh(file)
  if not file then
    return
  end

  local merge = package.loaded['glance.merge']
  if merge and merge.is_active and merge.is_active() then
    merge.refresh(M, file)
    return
  end

  local kind = git.infer_stage_kind(file)
  local old_lines = git.get_file_content(old_content_path(file), old_content_ref(file))
  local old_side_open = M.old_buf and vim.api.nvim_buf_is_valid(M.old_buf)
    and M.old_win and vim.api.nvim_win_is_valid(M.old_win)
  local panel_open = not old_side_open
    and M.new_buf and vim.api.nvim_buf_is_valid(M.new_buf)
    and vim.api.nvim_buf_get_option(M.new_buf, 'buftype') == 'nofile'
  local staged_diff_open = old_side_open
    and file.section == 'staged'
    and M.new_buf and vim.api.nvim_buf_is_valid(M.new_buf)
    and vim.api.nvim_buf_get_option(M.new_buf, 'buftype') == 'nofile'

  if staged_diff_open then
    local index_lines = git.get_file_content(file.path, ':')
    set_readonly_lines(M.new_buf, index_lines)
  end

  if old_side_open then
    set_readonly_lines(M.old_buf, old_lines)
    set_path_winbars(file)

    -- Refresh diff
    vim.cmd('diffupdate')

    -- Keep the minimap's git baseline in sync with the left pane refresh.
    local minimap = require('glance.minimap')
    minimap.old_lines = old_lines
    minimap.flush_content_update({ run_even_if_clean = true })
    return
  end

  if staged_diff_open then
    local minimap = require('glance.minimap')
    minimap.old_lines = old_lines
    minimap.flush_content_update({ run_even_if_clean = true })
    return
  end

  if panel_open then
    if kind == 'deleted' or file.status == 'D' then
      set_panel_lines(M.new_buf, old_lines)
      vim.api.nvim_buf_clear_namespace(M.new_buf, PANEL_NS, 0, -1)
      vim.api.nvim_buf_clear_namespace(M.new_buf, CONFLICT_NS, 0, -1)
      apply_deleted_highlights(M.new_buf, #old_lines)
    elseif git.ensure_file_binary(file) then
      render_binary_panel(M.new_buf, file)
    elseif kind == 'copied' then
      render_copied_panel(M.new_buf, file)
    elseif kind == 'type_changed' then
      render_type_changed_panel(M.new_buf, file)
    else
      render_placeholder_panel(M.new_buf, file)
    end
    return
  end

  if kind == 'conflicted' and M.new_buf and vim.api.nvim_buf_is_valid(M.new_buf) then
    apply_conflict_highlights(M.new_buf)
    set_window_label(M.new_win, 'Conflict: unresolved markers')
  end
end

--- Explicitly size panes: file tree gets its fixed width, diff panes split the rest.
function M.equalize_panes()
  local merge = package.loaded['glance.merge']
  if merge and merge.is_active and merge.is_active() and merge.equalize_panes(M) then
    return
  end

  sync_filetree_pane()
  local tree_visible = filetree.win and vim.api.nvim_win_is_valid(filetree.win)
  local tree_width = 0

  if tree_visible then
    tree_width = filetree_options().width
    vim.api.nvim_win_set_width(filetree.win, tree_width)
  end

  local wins = content_windows()
  if #wins > 1 then
    local separators = (tree_visible and 1 or 0) + (#wins - 1)
    local remaining = math.max(vim.o.columns - tree_width - separators, #wins)
    local pane_width = math.max(math.floor(remaining / #wins), 1)

    for i = 1, #wins - 1 do
      vim.api.nvim_win_set_width(wins[i], pane_width)
    end
  end
end

--- Apply standard window options to a diff pane (line numbers, etc).
function M.set_win_options(win)
  local options = diff_options()
  vim.api.nvim_win_set_option(win, 'number', options.number)
  vim.api.nvim_win_set_option(win, 'relativenumber', options.relativenumber)
  vim.api.nvim_win_set_option(win, 'signcolumn', options.signcolumn)
  vim.api.nvim_win_set_option(win, 'cursorline', options.cursorline)
  vim.api.nvim_win_set_option(win, 'foldenable', options.foldenable)
  set_window_label(win, '')
end

--- Set the filetype of a buffer based on the file extension for syntax highlighting.
--- Also explicitly starts tree-sitter, which doesn't auto-attach to nofile buffers.
function M.set_filetype_from_path(buf, path)
  local ft = vim.filetype.match({ filename = path })
  if ft then
    vim.api.nvim_buf_set_option(buf, 'filetype', ft)
    -- Don't pass ft as lang; let treesitter resolve via get_lang()
    -- which handles filetype != parser name (e.g. typescriptreact -> tsx)
    pcall(vim.treesitter.start, buf)
  end
end

return M
