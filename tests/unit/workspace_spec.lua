local A = require('tests.helpers.assert')

return {
  name = 'workspace-unit',
  cases = {
    {
      name = 'preserves declared role order and appends new roles',
      run = function()
        local workspace = require('glance.workspace')
        local ws = workspace.new({
          name = 'diffview',
          roles = {
            { role = 'filetree', kind = 'sidebar' },
            { role = 'diff_old', kind = 'content' },
            { role = 'diff_new', kind = 'content' },
          },
          preferred_focus_role = 'diff_new',
          editable_role = 'diff_new',
        })

        workspace.set_win(ws, 'diff_old', 10)
        workspace.set_buf(ws, 'diff_new', 20)
        workspace.set_pane(ws, 'merge_base', {
          win = 30,
          buf = 40,
        })

        A.same(workspace.role_list(ws), {
          'filetree',
          'diff_old',
          'diff_new',
          'merge_base',
        })
        A.equal(workspace.get_win(ws, 'diff_old'), 10)
        A.equal(workspace.get_buf(ws, 'diff_new'), 20)
        A.equal(workspace.get_win(ws, 'merge_base'), 30)
        A.equal(workspace.get_buf(ws, 'merge_base'), 40)
        A.equal(workspace.get_role_def(ws, 'filetree').kind, 'sidebar')
        A.equal(workspace.get_role_def(ws, 'merge_base').role, 'merge_base')
        A.equal(workspace.get_preferred_focus_role(ws), 'diff_new')
        A.equal(workspace.get_editable_role(ws), 'diff_new')
      end,
    },
    {
      name = 'collects panes in role order with filters',
      run = function()
        local workspace = require('glance.workspace')
        local ws = workspace.new({
          roles = {
            { role = 'filetree', kind = 'sidebar' },
            { role = 'diff_old', kind = 'content' },
            { role = 'diff_new', kind = 'content' },
            { role = 'merge_base', kind = 'content' },
          },
        })

        workspace.set_pane(ws, 'filetree', { win = 1, buf = 2 })
        workspace.set_pane(ws, 'diff_old', { win = 3, buf = 4 })
        workspace.set_pane(ws, 'diff_new', { win = 5, buf = 6 })
        workspace.set_pane(ws, 'merge_base', { win = 7, buf = 8 })

        local roles = {}
        for _, item in ipairs(workspace.collect_panes(ws, {
          filter = function(role)
            return role ~= 'filetree'
          end,
        })) do
          roles[#roles + 1] = item.role
        end

        A.same(roles, {
          'diff_old',
          'diff_new',
          'merge_base',
        })
        A.same(workspace.collect_windows(ws, {
          filter = function(_, _, role_def)
            return role_def.kind == 'content'
          end,
        }), { 3, 5, 7 })
        A.same(workspace.collect_buffers(ws, {
          filter = function(_, _, role_def)
            return role_def.kind == 'content'
          end,
        }), { 4, 6, 8 })
        A.same(workspace.collect_roles(ws, {
          filter = function(_, _, role_def)
            return role_def.kind == 'content'
          end,
        }), {
          'diff_old',
          'diff_new',
          'merge_base',
        })
      end,
    },
    {
      name = 'drops empty pane entries without dropping role declarations',
      run = function()
        local workspace = require('glance.workspace')
        local ws = workspace.new({
          roles = { 'filetree', 'diff_old' },
        })

        workspace.set_win(ws, 'diff_old', 12)
        workspace.set_buf(ws, 'diff_old', 34)
        workspace.set_win(ws, 'diff_old', nil)
        workspace.set_buf(ws, 'diff_old', nil)

        A.equal(workspace.get_pane(ws, 'diff_old'), nil)
        A.same(workspace.role_list(ws), {
          'filetree',
          'diff_old',
        })
      end,
    },
    {
      name = 'configure replaces role metadata and preserves matching panes',
      run = function()
        local workspace = require('glance.workspace')
        local ws = workspace.new({
          roles = {
            { role = 'filetree', kind = 'sidebar' },
            { role = 'diff_old', kind = 'content' },
            { role = 'diff_new', kind = 'content' },
          },
          preferred_focus_role = 'diff_new',
          editable_role = 'diff_new',
        })

        workspace.set_pane(ws, 'filetree', { win = 1, buf = 2 })
        workspace.set_pane(ws, 'diff_new', { win = 3, buf = 4 })

        workspace.configure(ws, {
          roles = {
            { role = 'filetree', kind = 'sidebar' },
            { role = 'merge_theirs', kind = 'content' },
            { role = 'merge_result', kind = 'content' },
          },
          preferred_focus_role = 'merge_result',
          editable_role = 'merge_result',
        })

        A.same(workspace.role_list(ws), {
          'filetree',
          'merge_theirs',
          'merge_result',
        })
        A.truthy(workspace.get_pane(ws, 'filetree'))
        A.equal(workspace.get_pane(ws, 'diff_new'), nil)
        A.equal(workspace.get_role_def(ws, 'merge_result').kind, 'content')
        A.equal(workspace.get_preferred_focus_role(ws), 'merge_result')
        A.equal(workspace.get_editable_role(ws), 'merge_result')
      end,
    },
  },
}
