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
  },
}
