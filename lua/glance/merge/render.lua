local config = require('glance.config')
local help = require('glance.merge.help')
local layout = require('glance.merge.layout')

local M = {}

local NS = vim.api.nvim_create_namespace('glance_merge')

local function set_lines(buf, lines, opts)
  opts = opts or {}

  vim.api.nvim_buf_set_option(buf, 'readonly', false)
  vim.api.nvim_buf_set_option(buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', opts.modifiable == true)
  vim.api.nvim_buf_set_option(buf, 'readonly', opts.readonly ~= false)

  if opts.swapfile ~= nil then
    vim.api.nvim_buf_set_option(buf, 'swapfile', opts.swapfile)
  end

  if opts.buftype then
    vim.api.nvim_buf_set_option(buf, 'buftype', opts.buftype)
  end

  if opts.modified ~= nil then
    vim.api.nvim_set_option_value('modified', opts.modified, { buf = buf })
  end
end

local function set_window_label(win, label)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  vim.api.nvim_set_option_value('winbar', label or '', { win = win })
end

local function pretty_state(state)
  local labels = {
    ours = 'ours',
    theirs = 'theirs',
    both_ours_then_theirs = 'both o/t',
    both_theirs_then_ours = 'both t/o',
    base_only = 'base',
    manual_resolved = 'manual resolved',
    manual_unresolved = 'manual unresolved',
    unresolved = 'unresolved',
  }

  return labels[state] or tostring(state):gsub('_', ' ')
end

local function conflict_state_label(conflict)
  if not conflict then
    return nil
  end

  if conflict.state == 'manual_unresolved' then
    return 'manual unresolved'
  end
  if conflict.state == 'manual_resolved' then
    return 'manual resolved'
  end
  if conflict.handled then
    return 'handled: ' .. pretty_state(conflict.state)
  end
  if conflict.state == 'unresolved' then
    return 'unresolved'
  end

  return 'pending: ' .. pretty_state(conflict.state)
end

local function conflict_marker_group(conflict)
  if conflict.state == 'manual_unresolved' then
    return 'GlanceConflictMarkerManual'
  end
  if conflict.handled then
    return 'GlanceConflictMarkerHandled'
  end
  return 'GlanceConflictMarkerUnresolved'
end

local function conflict_state_group(conflict)
  if conflict.state == 'manual_unresolved' then
    return 'GlanceConflictStateManual'
  end
  if conflict.handled then
    return 'GlanceConflictStateHandled'
  end
  return 'GlanceConflictStateUnresolved'
end

local function action_bar_padding()
  local minimap = config.options.minimap or {}
  if not minimap.enabled then
    return ''
  end

  return string.rep(' ', (minimap.width or 1) + 1)
end

local function result_label(model, active_conflict_index)
  local op = model.operation or {}
  local parts = {}
  local conflict = active_conflict_index and model.conflicts[active_conflict_index] or nil

  if op.prefix then
    parts[#parts + 1] = op.prefix
  end

  parts[#parts + 1] = 'Result'
  if conflict then
    parts[#parts + 1] = string.format('%d/%d', active_conflict_index, #model.conflicts)
    parts[#parts + 1] = conflict_state_label(conflict)
  end
  parts[#parts + 1] = string.format('%d unresolved', model.unresolved_count)
  if model.inference_failed then
    parts[#parts + 1] = 'inference fallback'
  end

  local hints = {}
  if model.unresolved_count == 0 then
    local complete_hint = help.complete_hint()
    if complete_hint ~= '' then
      hints[#hints + 1] = complete_hint
    end
  end
  local help_hint = help.winbar_hint()
  if help_hint ~= '' then
    hints[#hints + 1] = help_hint
  end

  local label = table.concat(parts, ' | ')
  if #hints > 0 then
    return label .. '%=' .. table.concat(hints, ' | ') .. action_bar_padding()
  end
  return label
end

local function role_label(model, role, active_conflict_index)
  local op = model.operation or {}
  local parts = {}

  if op.prefix then
    parts[#parts + 1] = op.prefix
  end

  if role == layout.THEIRS_ROLE then
    parts[#parts + 1] = 'Theirs'
    parts[#parts + 1] = 'stage 3'
    if op.theirs_display then
      parts[#parts + 1] = op.theirs_display
    end
  elseif role == layout.OURS_ROLE then
    parts[#parts + 1] = 'Ours'
    parts[#parts + 1] = 'stage 2'
    if op.ours_display then
      parts[#parts + 1] = op.ours_display
    end
  elseif role == layout.RESULT_ROLE then
    return result_label(model, active_conflict_index)
  end

  return table.concat(parts, ' | ')
end

local function clear_buffer(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
end

local function add_line_range(buf, start_line, count, group)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not start_line or count <= 0 then
    return
  end

  for index = start_line, start_line + count - 1 do
    vim.api.nvim_buf_add_highlight(buf, NS, group, index - 1, 0, -1)
  end
end

local function add_result_range(buf, start_line, count, line_group, opts)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not start_line or count <= 0 then
    return
  end

  opts = opts or {}
  for index = start_line, start_line + count - 1 do
    local extmark_opts = {
      line_hl_group = line_group,
      priority = opts.priority or 90,
    }

    if opts.number_group then
      extmark_opts.number_hl_group = opts.number_group
    end

    vim.api.nvim_buf_set_extmark(buf, NS, index - 1, 0, extmark_opts)
  end
end

local function zero_line_placeholder(conflict)
  return '  ' .. conflict_state_label(conflict) .. ' insert'
end

local function zero_line_anchor(conflict, line_count)
  local start_line = conflict.result_range.start or 1
  if start_line <= line_count then
    return math.max(start_line, 1) - 1, true
  end

  return math.max(line_count, 1) - 1, false
end

local function decorate_sources(buffers, model, active_conflict_index)
  clear_buffer(buffers.theirs)
  clear_buffer(buffers.ours)
  clear_buffer(buffers.result)

  for index, conflict in ipairs(model.conflicts) do
    add_line_range(buffers.theirs, conflict.theirs_range.start, conflict.theirs_range.count, 'GlanceDiffChangeOld')
    add_line_range(buffers.ours, conflict.ours_range.start, conflict.ours_range.count, 'GlanceDiffChangeNew')

    local state_group = conflict_state_group(conflict)
    local active_number_group = index == active_conflict_index and 'GlanceConflictActiveNumber' or nil

    add_result_range(buffers.result, conflict.result_range.start, conflict.result_range.count, state_group, {
      number_group = active_number_group,
    })

    if conflict.result_range.count == 0 then
      local line_count = math.max(vim.api.nvim_buf_line_count(buffers.result), 1)
      local anchor_line, virt_lines_above = zero_line_anchor(conflict, line_count)
      local extmark_opts = {
        virt_lines = { { { zero_line_placeholder(conflict), conflict_marker_group(conflict) } } },
        virt_lines_above = virt_lines_above,
        priority = 100,
      }
      if active_number_group then
        extmark_opts.number_hl_group = active_number_group
      end

      vim.api.nvim_buf_set_extmark(buffers.result, NS, anchor_line, 0, {
        virt_lines = extmark_opts.virt_lines,
        virt_lines_above = extmark_opts.virt_lines_above,
        priority = extmark_opts.priority,
        number_hl_group = extmark_opts.number_hl_group,
      })
    end
  end
end

local function prepare_source_buffer(diffview, buf, name, lines, path)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  set_lines(buf, lines, {
    buftype = 'nofile',
    modifiable = false,
    readonly = true,
    swapfile = false,
    modified = false,
  })
  diffview.set_filetype_from_path(buf, path)
end

local function prepare_result_buffer(diffview, buf, lines, path, ends_with_newline)
  set_lines(buf, lines, {
    modifiable = true,
    readonly = false,
    modified = false,
  })
  diffview.set_filetype_from_path(buf, path)
  vim.api.nvim_set_option_value('endofline', ends_with_newline ~= false, { buf = buf })
end

function M.decorate(panes, model, active_conflict_index)
  set_window_label(panes.theirs.win, role_label(model, layout.THEIRS_ROLE, active_conflict_index))
  set_window_label(panes.ours.win, role_label(model, layout.OURS_ROLE, active_conflict_index))
  set_window_label(panes.result.win, role_label(model, layout.RESULT_ROLE, active_conflict_index))

  decorate_sources({
    theirs = panes.theirs.buf,
    ours = panes.ours.buf,
    result = panes.result.buf,
  }, model, active_conflict_index)
end

function M.apply(diffview, panes, model, file, opts)
  opts = opts or {}

  if opts.refresh_sources ~= false then
    prepare_source_buffer(
      diffview,
      panes.theirs.buf,
      'glance://merge/theirs/' .. file.path,
      model.theirs_lines,
      file.path
    )
    prepare_source_buffer(
      diffview,
      panes.ours.buf,
      'glance://merge/ours/' .. file.path,
      model.ours_lines,
      file.path
    )
  end

  if opts.refresh_result ~= false then
    prepare_result_buffer(diffview, panes.result.buf, model.result_lines, file.path, model.result_ends_with_newline)
  end

  M.decorate(panes, model, opts.active_conflict_index)
end

return M
