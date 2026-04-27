local model = require('glance.merge.model')

local M = {}

local DEFINITIONS = {
  { id = 'accept_ours', short = 'ours' },
  { id = 'accept_theirs', short = 'theirs' },
  { id = 'accept_both_ours_then_theirs', short = 'both o/t' },
  { id = 'accept_both_theirs_then_ours', short = 'both t/o' },
  { id = 'ignore_ours', short = 'skip ours' },
  { id = 'ignore_theirs', short = 'skip theirs' },
  { id = 'reset_conflict', short = 'reset' },
  { id = 'mark_resolved', short = 'resolve' },
}

local function display_key(lhs)
  if type(lhs) ~= 'string' then
    return ''
  end

  return lhs:gsub('<Leader>', '\\'):gsub('<leader>', '\\')
end

function M.available(conflict)
  local actions = {}
  if type(conflict) ~= 'table' then
    return actions
  end

  for _, definition in ipairs(DEFINITIONS) do
    local id = definition.id
    if id == 'mark_resolved' then
      if conflict.state == 'manual_unresolved' then
        actions[#actions + 1] = definition
      end
    elseif id == 'ignore_ours' or id == 'ignore_theirs' then
      if conflict.state ~= 'manual_unresolved' and conflict.state ~= 'manual_resolved' then
        actions[#actions + 1] = definition
      end
    else
      actions[#actions + 1] = definition
    end
  end

  return actions
end

function M.hint_text(conflict, keymaps)
  local parts = {}
  for _, definition in ipairs(M.available(conflict)) do
    local lhs = keymaps and keymaps[definition.id] or nil
    local key = display_key(lhs)
    if key ~= '' then
      parts[#parts + 1] = string.format('%s %s', key, definition.short)
    else
      parts[#parts + 1] = definition.short
    end
  end

  return table.concat(parts, ' | ')
end

function M.apply(merge_model, index, action)
  return model.apply_action(merge_model, index, action)
end

return M
