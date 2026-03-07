local config = require('glance.config')

local M = {}

-- State
M.buf = nil
M.win = nil
M.files = nil        -- The full files table { staged, changes, untracked }
M.line_map = {}      -- Maps buffer line number -> file object (nil for headers/blanks)
M.active_file = nil  -- Currently viewed file in diff mode
M.selected_line = nil -- Tracks the cursor line set by j/k/J/K navigation

--- Create the file tree buffer with appropriate settings.
function M.create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'swapfile', false)
  vim.api.nvim_buf_set_option(buf, 'filetype', 'glance')
  vim.api.nvim_buf_set_name(buf, 'glance://files')
  M.buf = buf
  M.setup_keymaps()
  return buf
end

--- Render the file list with section headers into the buffer.
function M.render(files)
  M.files = files
  M.line_map = {}

  local lines = {}
  local highlights = {} -- { line, col_start, col_end, hl_group }

  local function add_section(title, file_list)
    if #file_list == 0 then
      return
    end

    -- Blank line before section (except at the very start)
    if #lines > 0 then
      table.insert(lines, '')
      -- line_map entry is nil by default (no action needed)
    end

    -- Section header
    local header = '  ' .. title
    table.insert(lines, header)
    table.insert(highlights, { #lines, 0, #header, 'GlanceSectionHeader' })
    -- line_map entry is nil by default (no action needed)

    -- File entries
    for _, file in ipairs(file_list) do
      local display_path = file.path
      if file.old_path then
        display_path = file.old_path .. ' → ' .. file.path
      end
      local line = '    ' .. file.status .. ' ' .. display_path
      table.insert(lines, line)
      M.line_map[#lines] = file

      -- Highlight the status character
      local hl_group = M.status_highlight(file.status)
      if hl_group then
        table.insert(highlights, { #lines, 4, 5, hl_group })
      end
    end
  end

  add_section('Staged Changes', files.staged)
  add_section('Changes', files.changes)
  add_section('Untracked', files.untracked)

  -- Handle empty state
  if #lines == 0 then
    lines = { '', '  No changes found' }
    M.line_map = { nil, nil }
    highlights = { { 2, 0, 20, 'Comment' } }
  end

  -- Write to buffer
  vim.api.nvim_buf_set_option(M.buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.buf, 'modifiable', false)

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace('glance_filetree')
  vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(M.buf, ns, hl[4], hl[1] - 1, hl[2], hl[3])
  end

  -- Place cursor on the first file entry
  M.move_to_first_file()
end

--- Get the highlight group for a status character.
function M.status_highlight(status)
  local map = {
    M = 'GlanceStatusM',
    A = 'GlanceStatusA',
    D = 'GlanceStatusD',
    R = 'GlanceStatusR',
    ['?'] = 'GlanceStatusU',
  }
  return map[status]
end

--- Get the file object under the cursor.
function M.get_selected_file()
  if not M.selected_line then
    return nil
  end
  return M.line_map[M.selected_line]
end

--- Move cursor to the next file entry (skip headers and blanks).
function M.move_down()
  local current = M.selected_line or 0
  local total = vim.api.nvim_buf_line_count(M.buf)

  for i = current + 1, total do
    if M.line_map[i] then
      M.selected_line = i
      vim.api.nvim_win_set_cursor(M.win, { i, 4 })
      return
    end
  end
end

--- Move cursor to the previous file entry (skip headers and blanks).
function M.move_up()
  local current = M.selected_line or 2

  for i = current - 1, 1, -1 do
    if M.line_map[i] then
      M.selected_line = i
      vim.api.nvim_win_set_cursor(M.win, { i, 4 })
      return
    end
  end
end

--- Jump to the first file in the next section.
function M.next_section()
  local current = M.selected_line or 0
  local total = vim.api.nvim_buf_line_count(M.buf)
  local found_blank = false

  for i = current + 1, total do
    if M.line_map[i] == nil then
      found_blank = true
    elseif found_blank and M.line_map[i] then
      M.selected_line = i
      vim.api.nvim_win_set_cursor(M.win, { i, 4 })
      return
    end
  end
end

--- Jump to the first file in the previous section.
function M.prev_section()
  local current = M.selected_line or 2

  -- First, find the start of the current section (go up to the header)
  local current_section_start = nil
  for i = current - 1, 1, -1 do
    if M.line_map[i] == nil then
      current_section_start = i
      break
    end
  end

  if not current_section_start then
    return
  end

  -- Now find the first file in the previous section
  local found_file_in_prev = false
  for i = current_section_start - 1, 1, -1 do
    if M.line_map[i] then
      found_file_in_prev = true
    elseif found_file_in_prev and M.line_map[i] == nil then
      for j = i + 1, current_section_start - 1 do
        if M.line_map[j] then
          M.selected_line = j
          vim.api.nvim_win_set_cursor(M.win, { j, 4 })
          return
        end
      end
    end
  end

  if found_file_in_prev then
    for i = 1, current_section_start - 1 do
      if M.line_map[i] then
        M.selected_line = i
        vim.api.nvim_win_set_cursor(M.win, { i, 4 })
        return
      end
    end
  end
end

--- Move cursor to the first file entry in the buffer.
function M.move_to_first_file()
  if not M.win or not vim.api.nvim_win_is_valid(M.win) then
    return
  end
  local total = vim.api.nvim_buf_line_count(M.buf)
  for i = 1, total do
    if M.line_map[i] then
      M.selected_line = i
      vim.api.nvim_win_set_cursor(M.win, { i, 4 })
      return
    end
  end
end

--- Highlight the currently active file (being viewed in diff).
function M.highlight_active(file)
  M.active_file = file
  local ns = vim.api.nvim_create_namespace('glance_active')
  vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)

  if not file then
    return
  end

  local total = vim.api.nvim_buf_line_count(M.buf)
  for i = 1, total do
    local f = M.line_map[i]
    if f and f.path == file.path and f.section == file.section then
      vim.api.nvim_buf_add_highlight(M.buf, ns, 'GlanceActiveFile', i - 1, 0, -1)
      break
    end
  end
end

--- Re-fetch git status and re-render the file tree.
function M.refresh()
  -- Save selected line before re-rendering
  local saved_line = M.selected_line

  local git = require('glance.git')
  local files = git.get_changed_files()
  M.render(files)

  -- Restore cursor position (use saved selected_line, not cursor)
  if saved_line and M.win and vim.api.nvim_win_is_valid(M.win) then
    local line_count = vim.api.nvim_buf_line_count(M.buf)
    local target_line = math.min(saved_line, line_count)
    M.selected_line = target_line
    vim.api.nvim_win_set_cursor(M.win, { target_line, 4 })
    -- If we landed on a header/blank, move to the nearest file entry
    if not M.line_map[target_line] then
      M.move_down()
    end
  end
end

--- Set up buffer-local keymaps for the file tree.
function M.setup_keymaps()
  local opts = { noremap = true, silent = true, buffer = M.buf }
  local km = config.options.keymaps

  vim.keymap.set('n', 'j', function() M.move_down() end, opts)
  vim.keymap.set('n', 'k', function() M.move_up() end, opts)
  vim.keymap.set('n', km.next_section, function() M.next_section() end, opts)
  vim.keymap.set('n', km.prev_section, function() M.prev_section() end, opts)
  vim.keymap.set('n', km.quit, function() vim.cmd('qa!') end, opts)
  vim.keymap.set('n', km.refresh, function() M.refresh() end, opts)
  vim.keymap.set('n', km.open_file, function()
    local file = M.get_selected_file()
    if file then
      local ui = require('glance.ui')
      ui.open_file(file)
    end
  end, opts)
end

return M
