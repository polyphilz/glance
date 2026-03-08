local M = {}

local function format(value)
  return vim.inspect(value, { newline = ' ', indent = '' })
end

function M.fail(message, level)
  error(message, (level or 1) + 1)
end

function M.truthy(value, message)
  if not value then
    M.fail(message or ('expected truthy value, got ' .. format(value)), 2)
  end
end

function M.falsy(value, message)
  if value then
    M.fail(message or ('expected falsy value, got ' .. format(value)), 2)
  end
end

function M.equal(actual, expected, message)
  if actual ~= expected then
    M.fail(message or ('expected ' .. format(expected) .. ', got ' .. format(actual)), 2)
  end
end

function M.same(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    M.fail(message or ('expected ' .. format(expected) .. ', got ' .. format(actual)), 2)
  end
end

function M.not_equal(actual, expected, message)
  if actual == expected then
    M.fail(message or ('did not expect ' .. format(expected)), 2)
  end
end

function M.contains(haystack, needle, message)
  if type(haystack) == 'string' then
    if not haystack:find(needle, 1, true) then
      M.fail(message or ('expected "' .. haystack .. '" to contain "' .. needle .. '"'), 2)
    end
    return
  end

  if type(haystack) == 'table' then
    for _, value in pairs(haystack) do
      if vim.deep_equal(value, needle) then
        return
      end
    end
  end

  M.fail(message or ('expected ' .. format(haystack) .. ' to contain ' .. format(needle)), 2)
end

function M.match(value, pattern, message)
  if type(value) ~= 'string' or not value:match(pattern) then
    M.fail(message or ('expected "' .. tostring(value) .. '" to match "' .. pattern .. '"'), 2)
  end
end

function M.length(value, expected, message)
  M.equal(#value, expected, message)
end

return M
