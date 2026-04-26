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

local function role_label(model, role)
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
    parts[#parts + 1] = 'Result'
    parts[#parts + 1] = string.format('%d unresolved', model.unresolved_count)
    if model.inference_failed then
      parts[#parts + 1] = 'inference fallback'
    end
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

local function decorate_sources(buffers, model)
  clear_buffer(buffers.theirs)
  clear_buffer(buffers.ours)
  clear_buffer(buffers.result)

  for _, conflict in ipairs(model.conflicts) do
    add_line_range(buffers.theirs, conflict.theirs_range.start, conflict.theirs_range.count, 'GlanceDiffChangeOld')
    add_line_range(buffers.ours, conflict.ours_range.start, conflict.ours_range.count, 'GlanceDiffChangeNew')

    local group = conflict.handled and 'GlanceAccentText' or 'DiffChange'
    add_line_range(buffers.result, conflict.result_range.start, conflict.result_range.count, group)

    local label = conflict.handled and ('handled: ' .. conflict.state) or 'unresolved'
    local line_count = math.max(vim.api.nvim_buf_line_count(buffers.result), 1)
    local anchor_line = math.min(math.max(conflict.result_range.start, 1), line_count) - 1

    if conflict.result_range.count > 0 then
      vim.api.nvim_buf_set_extmark(buffers.result, NS, conflict.result_range.start - 1, 0, {
        virt_text = { { label, 'Comment' } },
        virt_text_pos = 'eol',
      })
    else
      vim.api.nvim_buf_set_extmark(buffers.result, NS, anchor_line, 0, {
        virt_lines = { { { label, 'Comment' } } },
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

function M.apply(diffview, panes, model, file)
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
  prepare_result_buffer(diffview, panes.result.buf, model.result_lines, file.path, model.result_ends_with_newline)

  set_window_label(panes.theirs.win, role_label(model, layout.THEIRS_ROLE))
  set_window_label(panes.ours.win, role_label(model, layout.OURS_ROLE))
  set_window_label(panes.result.win, role_label(model, layout.RESULT_ROLE))

  decorate_sources({
    theirs = panes.theirs.buf,
    ours = panes.ours.buf,
    result = panes.result.buf,
  }, model)
end

return M
