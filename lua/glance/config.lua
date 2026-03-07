local M = {}

M.defaults = {
  filetree_width = 30,
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

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', M.defaults, opts or {})
end

return M
