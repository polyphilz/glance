local M = {}

M.defaults = {
  filetree_width = 30,
  hide_statusline = false,
  hunk_navigation = {},
  keymaps = {
    open_file = '<CR>',
    quit = 'q',
    refresh = 'r',
    next_section = 'J',
    prev_section = 'K',
    toggle_filetree = '<Tab>',
  },
  signs = {
    modified = 'M',
    added = 'A',
    deleted = 'D',
    renamed = 'R',
    untracked = '?',
  },
}

M.options = vim.deepcopy(M.defaults)

local function validate_hunk_navigation(options)
  local hunk = options.hunk_navigation or {}
  local next_key = hunk.next
  local prev_key = hunk.prev
  local toggle_key = options.keymaps and options.keymaps.toggle_filetree or nil

  if next_key ~= nil and type(next_key) ~= 'string' then
    error('glance: hunk_navigation.next must be a string or nil')
  end
  if prev_key ~= nil and type(prev_key) ~= 'string' then
    error('glance: hunk_navigation.prev must be a string or nil')
  end
  if next_key ~= nil and prev_key ~= nil and next_key == prev_key then
    error('glance: hunk_navigation.next and hunk_navigation.prev must be different')
  end
  if next_key ~= nil and next_key == toggle_key then
    error('glance: hunk_navigation.next conflicts with keymaps.toggle_filetree')
  end
  if prev_key ~= nil and prev_key == toggle_key then
    error('glance: hunk_navigation.prev conflicts with keymaps.toggle_filetree')
  end
end

function M.setup(opts)
  local merged = vim.tbl_deep_extend('force', M.defaults, opts or {})
  validate_hunk_navigation(merged)
  M.options = merged
end

return M
