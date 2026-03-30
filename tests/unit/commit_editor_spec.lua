local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

return {
  name = 'commit-editor',
  cases = {
    {
      name = 'open and close manage the floating editor lifecycle',
      run = function()
        local commit_editor = require('glance.commit_editor')

        commit_editor.open({})

        A.truthy(commit_editor.is_open())
        A.equal(vim.api.nvim_get_current_win(), commit_editor.win)
        A.equal(vim.api.nvim_get_option_value('buftype', { buf = commit_editor.buf }), 'acwrite')
        A.equal(vim.api.nvim_get_option_value('bufhidden', { buf = commit_editor.buf }), 'hide')
        A.equal(vim.api.nvim_get_option_value('swapfile', { buf = commit_editor.buf }), false)
        A.equal(vim.api.nvim_get_option_value('filetype', { buf = commit_editor.buf }), 'gitcommit')
        A.equal(vim.api.nvim_get_option_value('textwidth', { buf = commit_editor.buf }), 0)
        A.equal(vim.api.nvim_get_option_value('wrap', { win = commit_editor.win }), true)
        A.equal(vim.api.nvim_get_option_value('linebreak', { win = commit_editor.win }), true)
        A.equal(vim.api.nvim_get_option_value('spell', { win = commit_editor.win }), false)
        A.equal(vim.api.nvim_get_option_value('winhighlight', { win = commit_editor.win }), 'FloatTitle:GlanceLegendKey')

        commit_editor.close({
          force = true,
          notify_cancel = false,
        })

        A.falsy(commit_editor.is_open())
      end,
    },
    {
      name = 'dirty draft cancel confirmation keeps the editor open until discard is confirmed',
      run = function()
        local commit_editor = require('glance.commit_editor')
        local cancel_calls = 0

        commit_editor.open({
          on_cancel = function()
            cancel_calls = cancel_calls + 1
          end,
        })
        vim.api.nvim_buf_set_lines(commit_editor.buf, 0, -1, false, {
          'Subject',
        })

        N.with_confirm(2, function()
          commit_editor.close({
            notify_cancel = true,
          })
        end)
        A.truthy(commit_editor.is_open())
        A.equal(cancel_calls, 0)

        N.with_confirm(1, function()
          commit_editor.close({
            notify_cancel = true,
          })
        end)
        A.falsy(commit_editor.is_open())
        A.equal(cancel_calls, 1)
      end,
    },
    {
      name = 'closing the float window honors dirty-draft confirmation',
      run = function()
        local commit_editor = require('glance.commit_editor')

        commit_editor.open({})
        vim.api.nvim_buf_set_lines(commit_editor.buf, 0, -1, false, {
          'Subject',
        })

        N.with_confirm(2, function()
          vim.api.nvim_win_close(commit_editor.win, true)
          N.wait(200, function()
            return commit_editor.is_open()
          end)
        end)
        A.truthy(commit_editor.is_open())

        N.with_confirm(1, function()
          vim.api.nvim_win_close(commit_editor.win, true)
          N.wait(200, function()
            return not commit_editor.is_open()
          end)
        end)
        A.falsy(commit_editor.is_open())
      end,
    },
    {
      name = 'insert mode does not install a ctrl-c cancel binding',
      run = function()
        local commit_editor = require('glance.commit_editor')
        local map

        commit_editor.open({})
        A.truthy(commit_editor.is_open())

        map = vim.fn.maparg('<C-c>', 'i', false, true)
        A.falsy(type(map) == 'table' and map.buffer == 1 and map.lhs ~= '')

        commit_editor.close({
          force = true,
          notify_cancel = false,
        })
      end,
    },
    {
      name = 'write submits the current multiline draft to the callback',
      run = function()
        local commit_editor = require('glance.commit_editor')
        local submitted

        commit_editor.open({
          on_submit = function(lines)
            submitted = lines
          end,
        })
        vim.api.nvim_buf_set_lines(commit_editor.buf, 0, -1, false, {
          'Subject',
          '',
          'Body line',
        })

        vim.api.nvim_buf_call(commit_editor.buf, function()
          vim.cmd('write')
        end)

        A.same(submitted, {
          'Subject',
          '',
          'Body line',
        })

        commit_editor.close({
          force = true,
          notify_cancel = false,
        })
      end,
    },
    {
      name = 'x submits and closes only the commit modal',
      run = function()
        local commit_editor = require('glance.commit_editor')
        local initial_win = vim.api.nvim_get_current_win()
        local initial_buf = vim.api.nvim_get_current_buf()
        local submit_calls = 0

        commit_editor.open({
          on_submit = function(lines)
            submit_calls = submit_calls + 1
            A.same(lines, { 'Subject' })
            return true
          end,
        })
        vim.api.nvim_buf_set_lines(commit_editor.buf, 0, -1, false, { 'Subject' })

        vim.api.nvim_buf_call(commit_editor.buf, function()
          vim.cmd('x')
        end)

        N.wait(200, function()
          return not commit_editor.is_open()
        end)

        A.equal(submit_calls, 1)
        A.truthy(vim.api.nvim_win_is_valid(initial_win))
        A.equal(vim.api.nvim_get_current_win(), initial_win)
        A.equal(vim.api.nvim_get_current_buf(), initial_buf)
      end,
    },
  },
}
