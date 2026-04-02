local git = require('glance.git')

local M = {}

local function split_text(text)
  if type(text) ~= 'string' or text == '' then
    return {}, false
  end

  local lines = {}
  for line in (text .. '\n'):gmatch('(.-)\n') do
    lines[#lines + 1] = line
  end
  if #lines > 0 and lines[#lines] == '' then
    table.remove(lines)
  end

  return lines, text:sub(-1) == '\n'
end

local function join_text(lines, ends_with_newline)
  if type(lines) ~= 'table' or #lines == 0 then
    return ends_with_newline and '\n' or ''
  end

  local text = table.concat(lines, '\n')
  if ends_with_newline then
    text = text .. '\n'
  end

  return text
end

local function write_text(path, text)
  local file = assert(io.open(path, 'w'))
  file:write(text or '')
  file:close()
end

local function same_lines(left, right)
  if #left ~= #right then
    return false
  end

  for index = 1, #left do
    if left[index] ~= right[index] then
      return false
    end
  end

  return true
end

local function same_lines_at(lines, start_idx, needle)
  if #needle == 0 then
    return true
  end

  if start_idx < 1 or (start_idx + #needle - 1) > #lines then
    return false
  end

  for index = 1, #needle do
    if lines[start_idx + index - 1] ~= needle[index] then
      return false
    end
  end

  return true
end

local function slice_lines(lines, start_idx, end_idx)
  if start_idx > end_idx then
    return {}
  end

  local slice = {}
  for index = start_idx, end_idx do
    slice[#slice + 1] = lines[index]
  end
  return slice
end

local function find_next_sequence(lines, needle, start_idx)
  start_idx = math.max(start_idx or 1, 1)
  if #needle == 0 then
    return start_idx
  end

  local last_start = #lines - #needle + 1
  for index = start_idx, last_start do
    if same_lines_at(lines, index, needle) then
      return index
    end
  end

  return nil
end

local function find_sequence_positions(lines, needle, start_idx)
  local positions = {}
  start_idx = math.max(start_idx or 1, 1)

  if #needle == 0 then
    positions[1] = start_idx
    return positions
  end

  local last_start = #lines - #needle + 1
  for index = start_idx, last_start do
    if same_lines_at(lines, index, needle) then
      positions[#positions + 1] = index
    end
  end

  return positions
end

local function contains_conflict_markers(lines)
  for _, line in ipairs(lines) do
    if line:match('^<<<<<<<')
      or line:match('^|||||||')
      or line:match('^=======')
      or line:match('^>>>>>>>')
    then
      return true
    end
  end

  return false
end

local function parse_conflict_block(lines, start_idx)
  local first = lines[start_idx]
  if type(first) ~= 'string' or not first:match('^<<<<<<<') then
    return nil
  end

  local block = {
    ours_lines = {},
    base_lines = {},
    theirs_lines = {},
    full_lines = {},
  }

  local index = start_idx + 1
  while index <= #lines do
    local line = lines[index]
    if line:match('^|||||||') or line:match('^=======') then
      break
    end
    block.ours_lines[#block.ours_lines + 1] = line
    index = index + 1
  end

  if index > #lines then
    return nil
  end

  if lines[index]:match('^|||||||') then
    index = index + 1
    while index <= #lines and not lines[index]:match('^=======') do
      block.base_lines[#block.base_lines + 1] = lines[index]
      index = index + 1
    end
    if index > #lines then
      return nil
    end
  end

  if not lines[index]:match('^=======') then
    return nil
  end

  index = index + 1
  while index <= #lines and not lines[index]:match('^>>>>>>>') do
    block.theirs_lines[#block.theirs_lines + 1] = lines[index]
    index = index + 1
  end

  if index > #lines then
    return nil
  end

  block.full_lines = slice_lines(lines, start_idx, index)
  return block, index + 1
end

local function parse_canonical_sequence(lines)
  local stable_segments = {}
  local conflicts = {}
  local stable = {}
  local index = 1

  while index <= #lines do
    if lines[index]:match('^<<<<<<<') then
      stable_segments[#stable_segments + 1] = stable
      stable = {}

      local block, next_index = parse_conflict_block(lines, index)
      if not block then
        return nil, nil, 'failed to parse canonical merge output'
      end

      conflicts[#conflicts + 1] = {
        id = #conflicts + 1,
        ours_lines = block.ours_lines,
        base_lines = block.base_lines,
        theirs_lines = block.theirs_lines,
        canonical_lines = block.full_lines,
      }
      index = next_index
    else
      stable[#stable + 1] = lines[index]
      index = index + 1
    end
  end

  stable_segments[#stable_segments + 1] = stable
  return stable_segments, conflicts
end

local function canonical_merge_lines(base_text, ours_text, theirs_text)
  local tempdir = vim.fn.tempname() .. '-glance-merge'
  vim.fn.mkdir(tempdir, 'p')

  local base_path = tempdir .. '/base'
  local ours_path = tempdir .. '/ours'
  local theirs_path = tempdir .. '/theirs'

  write_text(base_path, base_text)
  write_text(ours_path, ours_text)
  write_text(theirs_path, theirs_text)

  local result = vim.system({
    'git',
    'merge-file',
    '--stdout',
    '--diff3',
    '-L',
    'Ours',
    '-L',
    'Base',
    '-L',
    'Theirs',
    ours_path,
    base_path,
    theirs_path,
  }, { text = true }):wait()

  vim.fn.delete(tempdir, 'rf')

  if result.code < 0 or result.code >= 128 then
    local message = vim.trim((result.stderr ~= '' and result.stderr) or (result.stdout or ''))
    if message == '' then
      message = 'git merge-file failed'
    end
    return nil, message
  end

  local lines = split_text(result.stdout or '')
  return lines
end

local function source_range(lines, needle, start_idx)
  local start = find_next_sequence(lines, needle, start_idx)
  if not start then
    return {
      start = nil,
      count = #needle,
    }
  end

  return {
    start = start,
    count = #needle,
  }
end

local function assign_source_ranges(conflicts, base_lines, ours_lines, theirs_lines)
  local base_cursor = 1
  local ours_cursor = 1
  local theirs_cursor = 1

  for _, conflict in ipairs(conflicts) do
    conflict.base_range = source_range(base_lines, conflict.base_lines, base_cursor)
    conflict.ours_range = source_range(ours_lines, conflict.ours_lines, ours_cursor)
    conflict.theirs_range = source_range(theirs_lines, conflict.theirs_lines, theirs_cursor)

    if conflict.base_range.start then
      base_cursor = conflict.base_range.start + conflict.base_range.count
    end
    if conflict.ours_range.start then
      ours_cursor = conflict.ours_range.start + conflict.ours_range.count
    end
    if conflict.theirs_range.start then
      theirs_cursor = conflict.theirs_range.start + conflict.theirs_range.count
    end
  end
end

local function clean_candidates(conflict)
  return {
    { state = 'ours', lines = conflict.ours_lines },
    { state = 'theirs', lines = conflict.theirs_lines },
    { state = 'both_ours_then_theirs', lines = vim.list_extend(vim.deepcopy(conflict.ours_lines), conflict.theirs_lines) },
    { state = 'both_theirs_then_ours', lines = vim.list_extend(vim.deepcopy(conflict.theirs_lines), conflict.ours_lines) },
    { state = 'base_only', lines = conflict.base_lines },
  }
end

local function collect_outcomes_strict(conflict, current_lines, cursor, next_stable, is_last)
  local outcomes = {}
  local seen = {}

  local function add_outcome(state, current_segment, next_cursor, kind)
    local key = table.concat({
      state,
      tostring(next_cursor),
      tostring(#current_segment),
      kind,
    }, ':')
    if seen[key] then
      return
    end

    seen[key] = true
    outcomes[#outcomes + 1] = {
      state = state,
      current_lines = current_segment,
      next_cursor = next_cursor,
      kind = kind,
    }
  end

  local block, block_next = parse_conflict_block(current_lines, cursor)
  if block then
    if same_lines(block.ours_lines, conflict.ours_lines)
      and same_lines(block.theirs_lines, conflict.theirs_lines)
      and (#block.base_lines == 0 or same_lines(block.base_lines, conflict.base_lines))
    then
      add_outcome('unresolved', block.full_lines, block_next, 'marker')
    else
      add_outcome('manual_unresolved', block.full_lines, block_next, 'marker')
    end
  end

  for _, candidate in ipairs(clean_candidates(conflict)) do
    if same_lines_at(current_lines, cursor, candidate.lines) then
      add_outcome(candidate.state, candidate.lines, cursor + #candidate.lines, 'clean')
    end
  end

  if is_last then
    if #next_stable == 0 then
      add_outcome('manual_unresolved', slice_lines(current_lines, cursor, #current_lines), #current_lines + 1, 'manual')
    else
      for _, position in ipairs(find_sequence_positions(current_lines, next_stable, cursor)) do
        if position + #next_stable - 1 == #current_lines then
          add_outcome('manual_unresolved', slice_lines(current_lines, cursor, position - 1), position, 'manual')
        end
      end
    end
  elseif #next_stable > 0 then
    for _, position in ipairs(find_sequence_positions(current_lines, next_stable, cursor)) do
      if position > cursor then
        add_outcome('manual_unresolved', slice_lines(current_lines, cursor, position - 1), position, 'manual')
      end
    end
  end

  return outcomes
end

local function infer_conflict_states_strict(stable_segments, conflicts, current_lines)
  local memo = {}

  local function solve(index, cursor)
    local key = index .. ':' .. cursor
    if memo[key] ~= nil then
      return memo[key] or nil
    end

    if index > #conflicts then
      local suffix = stable_segments[#conflicts + 1] or {}
      if same_lines_at(current_lines, cursor, suffix) and (cursor + #suffix - 1) == #current_lines then
        memo[key] = {}
        return memo[key]
      end
      memo[key] = false
      return nil
    end

    local before = stable_segments[index] or {}
    if not same_lines_at(current_lines, cursor, before) then
      memo[key] = false
      return nil
    end

    local after_before = cursor + #before
    local next_stable = stable_segments[index + 1] or {}
    local outcomes = collect_outcomes_strict(conflicts[index], current_lines, after_before, next_stable, index == #conflicts)

    for _, outcome in ipairs(outcomes) do
      local tail = solve(index + 1, outcome.next_cursor)
      if tail then
        local resolved = { outcome }
        for _, item in ipairs(tail) do
          resolved[#resolved + 1] = item
        end
        memo[key] = resolved
        return resolved
      end
    end

    memo[key] = false
    return nil
  end

  return solve(1, 1)
end

local function conflict_marker_ranges(lines)
  local ranges = {}
  local index = 1

  while index <= #lines do
    if lines[index]:match('^<<<<<<<') then
      local _, next_index = parse_conflict_block(lines, index)
      if next_index then
        ranges[#ranges + 1] = {
          start = index,
          stop = next_index - 1,
        }
        index = next_index
      else
        index = index + 1
      end
    else
      index = index + 1
    end
  end

  return ranges
end

local function position_in_ranges(position, ranges)
  for _, range in ipairs(ranges) do
    if position >= range.start and position <= range.stop then
      return true
    end
  end

  return false
end

local function occurrence_key(occurrence)
  return table.concat({
    occurrence.state,
    occurrence.kind,
    tostring(occurrence.start),
    tostring(occurrence.stop),
  }, ':')
end

local function collect_relaxed_occurrences(conflict, current_lines, cursor, marker_ranges)
  local occurrences = {}
  local seen = {}

  local function add_occurrence(occurrence)
    local key = occurrence_key(occurrence)
    if seen[key] then
      return
    end

    seen[key] = true
    occurrences[#occurrences + 1] = occurrence
  end

  for index = cursor, #current_lines do
    if current_lines[index]:match('^<<<<<<<') then
      local block, next_index = parse_conflict_block(current_lines, index)
      if block then
        local state = 'manual_unresolved'
        if same_lines(block.ours_lines, conflict.ours_lines)
          and same_lines(block.theirs_lines, conflict.theirs_lines)
          and (#block.base_lines == 0 or same_lines(block.base_lines, conflict.base_lines))
        then
          state = 'unresolved'
        end

        add_occurrence({
          state = state,
          current_lines = block.full_lines,
          kind = 'marker',
          start = index,
          stop = next_index - 1,
        })
      end
    end
  end

  for _, candidate in ipairs(clean_candidates(conflict)) do
    if #candidate.lines == 0 then
      for position = cursor, #current_lines + 1 do
        add_occurrence({
          state = candidate.state,
          current_lines = candidate.lines,
          kind = 'clean',
          start = position,
          stop = position - 1,
        })
      end
    else
      for _, position in ipairs(find_sequence_positions(current_lines, candidate.lines, cursor)) do
        if not position_in_ranges(position, marker_ranges) then
          add_occurrence({
            state = candidate.state,
            current_lines = candidate.lines,
            kind = 'clean',
            start = position,
            stop = position + #candidate.lines - 1,
          })
        end
      end
    end
  end

  table.sort(occurrences, function(left, right)
    if left.start ~= right.start then
      return left.start < right.start
    end
    if left.stop ~= right.stop then
      return left.stop < right.stop
    end
    if left.kind ~= right.kind then
      return left.kind < right.kind
    end
    return left.state < right.state
  end)

  return occurrences
end

local function infer_conflict_states_relaxed(canonical_stable_segments, conflicts, current_lines)
  local marker_ranges = conflict_marker_ranges(current_lines)
  local memo = {}

  local function solve(index, cursor)
    local key = index .. ':' .. cursor
    if memo[key] ~= nil then
      return memo[key] or nil
    end

    if index > #conflicts then
      local suffix = slice_lines(current_lines, cursor, #current_lines)
      local solution = {
        cost = math.abs(#suffix - #(canonical_stable_segments[#conflicts + 1] or {})),
        stable_segments = { suffix },
        outcomes = {},
      }
      memo[key] = solution
      return solution
    end

    local best = nil
    local expected_stable = canonical_stable_segments[index] or {}

    for _, occurrence in ipairs(collect_relaxed_occurrences(conflicts[index], current_lines, cursor, marker_ranges)) do
      local tail = solve(index + 1, occurrence.stop + 1)
      if tail then
        local stable_before = slice_lines(current_lines, cursor, occurrence.start - 1)
        local cost = math.abs(#stable_before - #expected_stable) + tail.cost

        local stable_segments = { stable_before }
        for _, segment in ipairs(tail.stable_segments) do
          stable_segments[#stable_segments + 1] = segment
        end

        local outcomes = {
          {
            state = occurrence.state,
            current_lines = occurrence.current_lines,
            next_cursor = occurrence.stop + 1,
            kind = occurrence.kind,
          },
        }
        for _, item in ipairs(tail.outcomes) do
          outcomes[#outcomes + 1] = item
        end

        local solution = {
          cost = cost,
          stable_segments = stable_segments,
          outcomes = outcomes,
        }

        if not best
          or solution.cost < best.cost
          or (solution.cost == best.cost and occurrence.start < best.outcomes[1].next_cursor)
        then
          best = solution
        end
      end
    end

    memo[key] = best or false
    return best
  end

  local resolved = solve(1, 1)
  if not resolved then
    return nil, nil
  end

  return resolved.stable_segments, resolved.outcomes
end

local function display_lines_for(conflict)
  if conflict.state == 'unresolved' then
    return conflict.base_lines
  end

  if conflict.state == 'manual_unresolved' then
    if conflict.current_kind == 'marker' or contains_conflict_markers(conflict.current_lines) then
      return conflict.base_lines
    end
    return conflict.current_lines
  end

  return conflict.current_lines
end

local function display_ends_with_newline(conflict, current_ends_with_newline)
  if conflict.state == 'unresolved' then
    return conflict.base_ends_with_newline
  end

  if conflict.state == 'manual_unresolved' then
    if conflict.current_kind == 'marker' or contains_conflict_markers(conflict.current_lines) then
      return conflict.base_ends_with_newline
    end
    return current_ends_with_newline
  end

  if conflict.state == 'ours' then
    return conflict.ours_ends_with_newline
  end
  if conflict.state == 'theirs' then
    return conflict.theirs_ends_with_newline
  end
  if conflict.state == 'both_ours_then_theirs' then
    return conflict.theirs_ends_with_newline
  end
  if conflict.state == 'both_theirs_then_ours' then
    return conflict.ours_ends_with_newline
  end
  if conflict.state == 'base_only' then
    return conflict.base_ends_with_newline
  end

  return current_ends_with_newline
end

local function apply_states(stable_segments, conflicts, outcomes)
  if not outcomes then
    for _, conflict in ipairs(conflicts) do
      conflict.state = 'unresolved'
      conflict.current_lines = conflict.canonical_lines
      conflict.current_kind = 'marker'
      conflict.handled = false
    end
    return
  end

  for index, conflict in ipairs(conflicts) do
    local outcome = outcomes[index]
    conflict.state = outcome.state
    conflict.current_lines = outcome.current_lines
    conflict.current_kind = outcome.kind
    conflict.handled = conflict.state ~= 'unresolved' and conflict.state ~= 'manual_unresolved'
  end
end

local function build_result_projection(stable_segments, conflicts, current_ends_with_newline)
  local lines = {}
  local unresolved_count = 0

  for index, conflict in ipairs(conflicts) do
    local before = stable_segments[index] or {}
    for _, line in ipairs(before) do
      lines[#lines + 1] = line
    end

    local display_lines = display_lines_for(conflict)
    conflict.display_lines = display_lines
    conflict.result_range = {
      start = #lines + 1,
      count = #display_lines,
    }
    if not conflict.handled then
      unresolved_count = unresolved_count + 1
    end

    for _, line in ipairs(display_lines) do
      lines[#lines + 1] = line
    end
  end

  local suffix = stable_segments[#conflicts + 1] or {}
  for _, line in ipairs(suffix) do
    lines[#lines + 1] = line
  end

  if #suffix > 0 or #conflicts == 0 then
    return lines, unresolved_count, current_ends_with_newline
  end

  return lines, unresolved_count, display_ends_with_newline(conflicts[#conflicts], current_ends_with_newline)
end

local function build_model(file, opts)
  opts = opts or {}
  local stage_entries = git.get_unmerged_stage_entries(file.path)
  if not stage_entries[2] or not stage_entries[3] then
    return nil, 'Glance merge inspector currently supports text conflicts with stage 2 and stage 3 entries only'
  end

  local base_text = stage_entries[1] and git.get_file_text(file.path, ':1') or ''
  local ours_text = git.get_file_text(file.path, ':2')
  local theirs_text = git.get_file_text(file.path, ':3')

  local current_lines = opts.current_lines
  local current_ends_with_newline = opts.current_ends_with_newline
  if not current_lines then
    local current_text = git.get_file_text(file.path)
    current_lines, current_ends_with_newline = split_text(current_text)
  elseif current_ends_with_newline == nil then
    current_ends_with_newline = true
  end

  local base_lines, base_ends_with_newline = split_text(base_text)
  local ours_lines, ours_ends_with_newline = split_text(ours_text)
  local theirs_lines, theirs_ends_with_newline = split_text(theirs_text)

  local canonical_lines, canonical_err = canonical_merge_lines(base_text, ours_text, theirs_text)
  if not canonical_lines then
    return nil, canonical_err
  end

  local stable_segments, conflicts, parse_err = parse_canonical_sequence(canonical_lines)
  if not stable_segments then
    return nil, parse_err
  end

  if #conflicts == 0 then
    return nil, 'Glance merge inspector only opens text conflicts with merge hunks'
  end

  assign_source_ranges(conflicts, base_lines, ours_lines, theirs_lines)
  for _, conflict in ipairs(conflicts) do
    conflict.base_ends_with_newline = base_ends_with_newline
    conflict.ours_ends_with_newline = ours_ends_with_newline
    conflict.theirs_ends_with_newline = theirs_ends_with_newline
  end
  local resolved_stable_segments = stable_segments
  local outcomes = infer_conflict_states_strict(stable_segments, conflicts, current_lines)
  if not outcomes then
    resolved_stable_segments, outcomes = infer_conflict_states_relaxed(stable_segments, conflicts, current_lines)
  end

  apply_states(stable_segments, conflicts, outcomes)
  resolved_stable_segments = resolved_stable_segments or stable_segments

  local result_lines, unresolved_count, result_ends_with_newline =
    build_result_projection(resolved_stable_segments, conflicts, current_ends_with_newline)

  return {
    file = file,
    operation = git.get_operation_context(),
    stage_entries = stage_entries,
    canonical_stable_segments = stable_segments,
    stable_segments = resolved_stable_segments,
    conflicts = conflicts,
    base_lines = base_lines,
    ours_lines = ours_lines,
    theirs_lines = theirs_lines,
    current_lines = current_lines,
    current_ends_with_newline = current_ends_with_newline,
    result_lines = result_lines,
    result_ends_with_newline = result_ends_with_newline,
    unresolved_count = unresolved_count,
    inference_failed = outcomes == nil,
  }
end

local function persisted_conflict_lines(conflict)
  if conflict.state == 'unresolved' then
    return conflict.canonical_lines
  end

  if conflict.state == 'manual_unresolved' then
    if conflict.current_kind == 'marker' or contains_conflict_markers(conflict.current_lines) then
      return conflict.current_lines
    end

    return nil, 'cannot safely save unresolved manual merge edits yet'
  end

  return conflict.current_lines
end

local function build_persisted_lines(merge_model)
  local lines = {}
  local stable_segments = merge_model.stable_segments or merge_model.canonical_stable_segments or {}

  for index, conflict in ipairs(merge_model.conflicts) do
    for _, line in ipairs(stable_segments[index] or {}) do
      lines[#lines + 1] = line
    end

    local persisted_lines, err = persisted_conflict_lines(conflict)
    if not persisted_lines then
      return nil, err
    end

    for _, line in ipairs(persisted_lines) do
      lines[#lines + 1] = line
    end
  end

  for _, line in ipairs(stable_segments[#merge_model.conflicts + 1] or {}) do
    lines[#lines + 1] = line
  end

  return lines
end

local function reconcile_with_previous_model(merge_model, previous_model)
  if type(previous_model) ~= 'table' or type(previous_model.conflicts) ~= 'table' then
    return
  end

  for index, conflict in ipairs(merge_model.conflicts) do
    local previous = previous_model.conflicts[index]
    -- Untouched unresolved conflicts project base text in the clean result pane, so
    -- base_only stays ambiguous until a later slice adds explicit resolution actions.
    if previous and previous.handled == false and conflict.state == 'base_only' then
      conflict.state = 'unresolved'
      conflict.handled = false
    end
  end

  local unresolved_count = 0
  for _, conflict in ipairs(merge_model.conflicts) do
    if not conflict.handled then
      unresolved_count = unresolved_count + 1
    end
  end
  merge_model.unresolved_count = unresolved_count
end

function M.build(file, opts)
  return build_model(file, opts)
end

function M.prepare_write(file, current_lines, opts)
  opts = opts or {}
  local merge_model, err = build_model(file, {
    current_lines = current_lines,
    current_ends_with_newline = opts.current_ends_with_newline,
  })
  if not merge_model then
    return nil, err
  end
  reconcile_with_previous_model(merge_model, opts.previous_model)
  if merge_model.inference_failed then
    return nil, 'cannot safely map the current merge result back to git conflict state'
  end

  local persisted_lines, persisted_err = build_persisted_lines(merge_model)
  if not persisted_lines then
    return nil, persisted_err
  end

  return {
    model = merge_model,
    persisted_lines = persisted_lines,
    persisted_text = join_text(persisted_lines, merge_model.current_ends_with_newline),
  }
end

return M
