local A = require('tests.helpers.assert')

return {
  name = 'minimap-logic',
  cases = {
    {
      name = 'compute line types classifies add delete and change hunks',
      run = function()
        local logic = require('glance.minimap_logic')

        local add_lines = logic.compute_line_types({ 'a', 'b' }, { 'a', 'b', 'c' })
        A.equal(add_lines[3], logic.states.ADD)

        local delete_lines = logic.compute_line_types({ 'a', 'b' }, { 'a' })
        local saw_delete = false
        for _, state in pairs(delete_lines) do
          if state == logic.states.DELETE then
            saw_delete = true
          end
        end
        A.truthy(saw_delete)

        local change_lines = logic.compute_line_types({ 'a', 'b' }, { 'a', 'x' })
        A.equal(change_lines[2], logic.states.CHANGE)
      end,
    },
    {
      name = 'downsample stays stable across small and large counts',
      run = function()
        local logic = require('glance.minimap_logic')
        A.same(logic.downsample({ [2] = logic.states.ADD }, 2, 4), {
          logic.states.NONE,
          logic.states.NONE,
          logic.states.ADD,
          logic.states.ADD,
        })

        local pixels = logic.downsample({
          [1] = logic.states.DELETE,
          [50] = logic.states.ADD,
          [99] = logic.states.CHANGE,
        }, 100, 10)
        A.length(pixels, 10)
        A.contains(pixels, logic.states.DELETE)
        A.contains(pixels, logic.states.ADD)
        A.contains(pixels, logic.states.CHANGE)
      end,
    },
    {
      name = 'viewport and cursor pixels stay in bounds',
      run = function()
        local logic = require('glance.minimap_logic')
        local start_px, end_px = logic.viewport_pixels(3, 8, 10, 20)
        A.equal(start_px, 5)
        A.equal(end_px, 16)
        A.equal(logic.cursor_pixel(1, 10, 20), 1)
        A.equal(logic.cursor_pixel(10, 10, 20), 19)
        A.equal(logic.cursor_pixel(10, 10, 0), nil)
      end,
    },
    {
      name = 'compute merge line types maps conflict states and zero-line ranges',
      run = function()
        local logic = require('glance.minimap_logic')
        local line_types = logic.compute_merge_line_types({
          {
            state = 'unresolved',
            handled = false,
            result_range = { start = 2, count = 0 },
          },
          {
            state = 'ours',
            handled = true,
            result_range = { start = 5, count = 2 },
          },
          {
            state = 'manual_unresolved',
            handled = false,
            result_range = { start = 10, count = 1 },
          },
          {
            state = 'manual_resolved',
            handled = true,
            result_range = { start = 12, count = 1 },
          },
        }, 12)

        A.equal(line_types[2], logic.states.MERGE_UNRESOLVED)
        A.equal(line_types[5], logic.states.MERGE_HANDLED)
        A.equal(line_types[6], logic.states.MERGE_HANDLED)
        A.equal(line_types[10], logic.states.MERGE_MANUAL)
        A.equal(line_types[12], logic.states.MERGE_HANDLED)

        local active_types = logic.compute_merge_line_types({
          {
            state = 'unresolved',
            handled = false,
            result_range = { start = 3, count = 2 },
          },
        }, 8, 1)

        A.equal(active_types[3], logic.states.MERGE_ACTIVE)
        A.equal(active_types[4], logic.states.MERGE_ACTIVE)
      end,
    },
  },
}
