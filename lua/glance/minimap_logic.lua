local M = {}

M.states = {
  NONE = 0,
  ADD = 1,
  DELETE = 2,
  CHANGE = 3,
  CURSOR = 4,
  MERGE_UNRESOLVED = 5,
  MERGE_HANDLED = 6,
  MERGE_MANUAL = 7,
  MERGE_ACTIVE = 8,
}

local STATE_PRIORITY = {
  [M.states.NONE] = 0,
  [M.states.ADD] = 1,
  [M.states.DELETE] = 2,
  [M.states.MERGE_HANDLED] = 3,
  [M.states.MERGE_UNRESOLVED] = 4,
  [M.states.MERGE_MANUAL] = 5,
  [M.states.CHANGE] = 6,
  [M.states.CURSOR] = 7,
  [M.states.MERGE_ACTIVE] = 8,
}

local function higher_priority(left, right)
  return (STATE_PRIORITY[left] or 0) > (STATE_PRIORITY[right] or 0)
end

--- Extract diff regions from old_lines vs new_lines using vim.diff().
--- Returns a sparse table: line_types[lnum] = ADD|DELETE|CHANGE or nil.
--- @param old_lines string[]
--- @param new_lines string[]
--- @return table, integer
function M.compute_line_types(old_lines, new_lines)
  local total = #new_lines
  local old_text = table.concat(old_lines, '\n') .. '\n'
  local new_text = table.concat(new_lines, '\n') .. '\n'

  local ok, hunks = pcall(vim.diff, old_text, new_text, {
    result_type = 'indices',
    algorithm = 'histogram',
  })
  if not ok or not hunks then
    return {}, total
  end

  local line_types = {}
  for _, hunk in ipairs(hunks) do
    local old_count, new_start, new_count = hunk[2], hunk[3], hunk[4]

    if old_count == 0 then
      for lnum = new_start, new_start + new_count - 1 do
        line_types[lnum] = M.states.ADD
      end
    elseif new_count == 0 then
      local mark = math.min(new_start + 1, total)
      if mark >= 1 then
        line_types[mark] = line_types[mark] or M.states.DELETE
      end
    else
      for lnum = new_start, new_start + new_count - 1 do
        line_types[lnum] = M.states.CHANGE
      end
    end
  end

  return line_types, total
end

local function conflict_state(conflict, is_active)
  if is_active then
    return M.states.MERGE_ACTIVE
  end
  if conflict.state == 'manual_unresolved' then
    return M.states.MERGE_MANUAL
  end
  if conflict.handled then
    return M.states.MERGE_HANDLED
  end
  return M.states.MERGE_UNRESOLVED
end

--- Convert merge conflict result ranges into minimap line states.
--- Zero-line conflicts are anchored to their insertion line so they remain visible.
--- @param conflicts table[]
--- @param total_lines integer
--- @param active_conflict_index integer|nil
--- @return table, integer
function M.compute_merge_line_types(conflicts, total_lines, active_conflict_index)
  total_lines = math.max(total_lines or 0, 1)
  local line_types = {}

  for index, conflict in ipairs(conflicts or {}) do
    local range = conflict.result_range or {}
    local start_line = range.start or 1
    local count = range.count or 0
    local state = conflict_state(conflict, index == active_conflict_index)

    if count == 0 then
      local mark = math.max(1, math.min(start_line, total_lines))
      line_types[mark] = state
    else
      local stop_line = math.min(start_line + count - 1, total_lines)
      for lnum = math.max(start_line, 1), stop_line do
        line_types[lnum] = state
      end
    end
  end

  return line_types, total_lines
end

--- Downsample line_types into pixel_count logical pixels.
--- Each pixel represents a proportional range of file lines.
--- @param line_types table
--- @param total_lines integer
--- @param pixel_count integer
--- @return integer[]
function M.downsample(line_types, total_lines, pixel_count)
  local pixels = {}
  if total_lines == 0 or pixel_count == 0 then
    for i = 1, pixel_count do
      pixels[i] = M.states.NONE
    end
    return pixels
  end

  for i = 1, pixel_count do
    local src_start = math.floor((i - 1) * total_lines / pixel_count) + 1
    local src_end = math.floor(i * total_lines / pixel_count)
    src_end = math.max(src_end, src_start)

    local best = M.states.NONE
    for lnum = src_start, math.min(src_end, total_lines) do
      local state = line_types[lnum]
      if state and higher_priority(state, best) then
        best = state
      end
    end
    pixels[i] = best
  end

  return pixels
end

--- Compute viewport pixel range from visible lines.
--- @param vp_top integer
--- @param vp_bot integer
--- @param total_lines integer
--- @param pixel_count integer
--- @return integer, integer
function M.viewport_pixels(vp_top, vp_bot, total_lines, pixel_count)
  if total_lines == 0 then
    return 1, pixel_count
  end

  local start_px = math.floor((vp_top - 1) / total_lines * pixel_count) + 1
  local end_px = math.ceil(vp_bot / total_lines * pixel_count)
  return math.max(1, math.min(start_px, pixel_count)), math.max(1, math.min(end_px, pixel_count))
end

--- Map a cursor line to a logical pixel.
--- @param cursor_line integer
--- @param total_lines integer
--- @param pixel_count integer
--- @return integer|nil
function M.cursor_pixel(cursor_line, total_lines, pixel_count)
  if total_lines == 0 or pixel_count == 0 then
    return nil
  end

  local pixel = math.floor((cursor_line - 1) / total_lines * pixel_count) + 1
  return math.max(1, math.min(pixel, pixel_count))
end

return M
