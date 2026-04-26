local M = {}

local function ensure_workspace(workspace)
  assert(type(workspace) == 'table', 'workspace must be a table')
  workspace.roles = workspace.roles or {}
  workspace.role_defs = workspace.role_defs or {}
  workspace.panes = workspace.panes or {}
  workspace.preferred_focus_role = workspace.preferred_focus_role
  workspace.editable_role = workspace.editable_role
  return workspace
end

local function assert_role(role)
  assert(type(role) == 'string' and role ~= '', 'role must be a non-empty string')
end

local function normalize_role_spec(role, opts)
  if type(role) == 'table' then
    local spec = vim.deepcopy(role)
    local name = spec.role or spec.name
    assert_role(name)
    spec.role = name
    spec.name = nil
    return name, spec
  end

  assert_role(role)
  local spec = vim.deepcopy(opts or {})
  spec.role = role
  spec.name = nil
  return role, spec
end

local function has_role(workspace, role)
  for _, existing in ipairs(workspace.roles) do
    if existing == role then
      return true
    end
  end
  return false
end

local function ensure_role(workspace, role)
  if not has_role(workspace, role) then
    table.insert(workspace.roles, role)
  end
end

local function cleanup_pane(workspace, role)
  local pane = workspace.panes[role]
  if not pane then
    return
  end

  if pane.win == nil and pane.buf == nil then
    workspace.panes[role] = nil
  end
end

function M.register_role(workspace, role, opts)
  workspace = ensure_workspace(workspace)
  local name, spec = normalize_role_spec(role, opts)
  ensure_role(workspace, name)

  local current = workspace.role_defs[name] or { role = name }
  workspace.role_defs[name] = vim.tbl_extend('force', current, spec)
  workspace.role_defs[name].role = name
  return workspace.role_defs[name]
end

function M.configure(workspace, opts)
  workspace = ensure_workspace(workspace)
  opts = opts or {}

  if opts.roles then
    local retained_panes = {}
    local previous_panes = workspace.panes

    workspace.roles = {}
    workspace.role_defs = {}
    for _, role_spec in ipairs(opts.roles) do
      local name = M.register_role(workspace, role_spec).role
      if previous_panes[name] then
        retained_panes[name] = previous_panes[name]
      end
    end
    workspace.panes = retained_panes

    if workspace.preferred_focus_role and not has_role(workspace, workspace.preferred_focus_role) then
      workspace.preferred_focus_role = nil
    end
    if workspace.editable_role and not has_role(workspace, workspace.editable_role) then
      workspace.editable_role = nil
    end
  end

  if opts.preferred_focus_role ~= nil then
    if opts.preferred_focus_role then
      M.register_role(workspace, opts.preferred_focus_role)
    end
    workspace.preferred_focus_role = opts.preferred_focus_role
  end

  if opts.editable_role ~= nil then
    if opts.editable_role then
      M.register_role(workspace, opts.editable_role)
    end
    workspace.editable_role = opts.editable_role
  end

  return workspace
end

function M.new(opts)
  local workspace = ensure_workspace({
    name = (opts and opts.name) or 'workspace',
  })

  M.configure(workspace, opts)
  return workspace
end

function M.clear(workspace)
  workspace = ensure_workspace(workspace)
  workspace.panes = {}
  return workspace
end

function M.get_pane(workspace, role)
  workspace = ensure_workspace(workspace)
  assert_role(role)
  return workspace.panes[role]
end

function M.set_pane(workspace, role, pane)
  workspace = ensure_workspace(workspace)
  M.register_role(workspace, role)

  if pane == nil then
    workspace.panes[role] = nil
    return nil
  end

  local current = workspace.panes[role] or { role = role }
  if pane.win ~= nil then
    current.win = pane.win
  end
  if pane.buf ~= nil then
    current.buf = pane.buf
  end
  workspace.panes[role] = current
  cleanup_pane(workspace, role)
  return workspace.panes[role]
end

function M.clear_pane(workspace, role)
  return M.set_pane(workspace, role, nil)
end

function M.set_win(workspace, role, win)
  workspace = ensure_workspace(workspace)
  M.register_role(workspace, role)

  local current = workspace.panes[role] or { role = role }
  current.win = win
  workspace.panes[role] = current
  cleanup_pane(workspace, role)
end

function M.set_buf(workspace, role, buf)
  workspace = ensure_workspace(workspace)
  M.register_role(workspace, role)

  local current = workspace.panes[role] or { role = role }
  current.buf = buf
  workspace.panes[role] = current
  cleanup_pane(workspace, role)
end

function M.get_win(workspace, role)
  local pane = M.get_pane(workspace, role)
  return pane and pane.win or nil
end

function M.get_buf(workspace, role)
  local pane = M.get_pane(workspace, role)
  return pane and pane.buf or nil
end

function M.is_valid_win(workspace, role)
  local win = M.get_win(workspace, role)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

function M.is_valid_buf(workspace, role)
  local buf = M.get_buf(workspace, role)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

function M.get_role_def(workspace, role)
  workspace = ensure_workspace(workspace)
  assert_role(role)
  return workspace.role_defs[role]
end

function M.role_list(workspace)
  workspace = ensure_workspace(workspace)
  return vim.deepcopy(workspace.roles)
end

function M.collect_roles(workspace, opts)
  workspace = ensure_workspace(workspace)
  opts = opts or {}

  local roles = {}
  for _, role in ipairs(workspace.roles) do
    local pane = workspace.panes[role]
    local role_def = workspace.role_defs[role] or { role = role }
    local include = true

    if opts.with_pane then
      include = pane ~= nil
    end
    if include and opts.valid_win then
      include = M.is_valid_win(workspace, role)
    end
    if include and opts.valid_buf then
      include = M.is_valid_buf(workspace, role)
    end
    if include and opts.filter then
      include = opts.filter(role, pane, role_def)
    end

    if include then
      roles[#roles + 1] = role
    end
  end

  return roles
end

function M.collect_panes(workspace, opts)
  workspace = ensure_workspace(workspace)
  opts = opts or {}

  local items = {}
  for _, role in ipairs(workspace.roles) do
    local pane = workspace.panes[role]
    if pane then
      local role_def = workspace.role_defs[role] or { role = role }
      local include = true

      if opts.valid_win then
        include = M.is_valid_win(workspace, role)
      end
      if include and opts.valid_buf then
        include = M.is_valid_buf(workspace, role)
      end
      if include and opts.filter then
        include = opts.filter(role, pane, role_def)
      end

      if include then
        items[#items + 1] = {
          role = role,
          pane = pane,
          role_def = role_def,
        }
      end
    end
  end

  return items
end

function M.collect_windows(workspace, opts)
  local wins = {}
  for _, item in ipairs(M.collect_panes(workspace, opts)) do
    wins[#wins + 1] = item.pane.win
  end
  return wins
end

function M.collect_buffers(workspace, opts)
  local bufs = {}
  for _, item in ipairs(M.collect_panes(workspace, opts)) do
    bufs[#bufs + 1] = item.pane.buf
  end
  return bufs
end

function M.set_preferred_focus_role(workspace, role)
  workspace = ensure_workspace(workspace)
  if role ~= nil then
    M.register_role(workspace, role)
  end
  workspace.preferred_focus_role = role
end

function M.get_preferred_focus_role(workspace)
  workspace = ensure_workspace(workspace)
  return workspace.preferred_focus_role
end

function M.set_editable_role(workspace, role)
  workspace = ensure_workspace(workspace)
  if role ~= nil then
    M.register_role(workspace, role)
  end
  workspace.editable_role = role
end

function M.get_editable_role(workspace)
  workspace = ensure_workspace(workspace)
  return workspace.editable_role
end

return M
