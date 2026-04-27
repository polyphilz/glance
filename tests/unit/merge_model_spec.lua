local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

local function snapshot(conflict)
  return {
    state = conflict.state,
    ours_handled = conflict.ours_handled == true,
    theirs_handled = conflict.theirs_handled == true,
    handled = conflict.handled == true,
    current_result_lines = vim.deepcopy(conflict.current_result_lines or conflict.current_lines or {}),
  }
end

local function expected_snapshot(state, ours_handled, theirs_handled, lines)
  return {
    state = state,
    ours_handled = ours_handled == true,
    theirs_handled = theirs_handled == true,
    handled = state == 'manual_resolved' or (ours_handled == true and theirs_handled == true),
    current_result_lines = vim.deepcopy(lines),
  }
end

return {
  name = 'merge_model',
  cases = {
    {
      name = 'build reconstructs a text conflict from stages and shows base in the result projection',
      run = function()
        N.with_repo('repo_conflict', function(repo)
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]
          local built = assert(merge_model.build(file))

          A.equal(built.operation.kind, 'merge')
          A.equal(built.unresolved_count, 1)
          A.same(built.base_lines, { 'base' })
          A.same(built.ours_lines, { 'main' })
          A.same(built.theirs_lines, { 'feature' })
          A.equal(built.conflicts[1].state, 'unresolved')
          A.same(built.result_lines, { 'base' })
          A.contains(built.operation.theirs_display, 'MERGE_HEAD')
          A.contains(built.operation.theirs_display, 'feature')
          A.equal(repo:read(repo.files.tracked):match('^<<<<<<<') ~= nil, true)
        end)
      end,
    },
    {
      name = 'build treats clean canonical matches without conflict markers as manual_resolved',
      run = function()
        N.with_repo('repo_conflict', function(repo)
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]
          local cases = {
            { text = 'main\n', lines = { 'main' } },
            { text = 'feature\n', lines = { 'feature' } },
            { text = 'base\n', lines = { 'base' } },
            { text = 'main\nfeature\n', lines = { 'main', 'feature' } },
          }

          for _, case in ipairs(cases) do
            repo:write(repo.files.tracked, case.text)
            local built = assert(merge_model.build(file))

            A.equal(built.unresolved_count, 0)
            A.equal(built.conflicts[1].state, 'manual_resolved')
            A.truthy(built.conflicts[1].handled)
            A.same(built.result_lines, case.lines)
          end
        end)
      end,
    },
    {
      name = 'build keeps mixed manual_resolved and unresolved conflicts in order',
      run = function()
        N.with_repo('repo_conflict_multi', function(repo)
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]

          repo:write(repo.files.tracked, table.concat({
            'intro',
            'first main',
            'gap one',
            'gap two',
            'gap three',
            '<<<<<<< HEAD',
            'second main',
            '=======',
            'second feature',
            '>>>>>>> feature',
            'outro',
            '',
          }, '\n'))

          local built = assert(merge_model.build(file))

          A.equal(built.unresolved_count, 1)
          A.equal(#built.conflicts, 2)
          A.equal(built.conflicts[1].state, 'manual_resolved')
          A.equal(built.conflicts[2].state, 'unresolved')
          A.same(built.result_lines, {
            'intro',
            'first main',
            'gap one',
            'gap two',
            'gap three',
            'second base',
            'outro',
          })
          A.equal(built.conflicts[1].result_range.start, 2)
          A.equal(built.conflicts[2].result_range.start, 6)
        end)
      end,
    },
    {
      name = 'build preserves stable edits around manual_resolved and unresolved conflicts',
      run = function()
        N.with_repo('repo_conflict_multi', function(repo)
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]

          repo:write(repo.files.tracked, table.concat({
            'intro updated',
            'first main',
            'gap one adjusted',
            'gap two',
            'gap three',
            '<<<<<<< HEAD',
            'second main',
            '=======',
            'second feature',
            '>>>>>>> feature',
            'outro updated',
            '',
          }, '\n'))

          local built = assert(merge_model.build(file))

          A.equal(built.unresolved_count, 1)
          A.equal(built.conflicts[1].state, 'manual_resolved')
          A.equal(built.conflicts[2].state, 'unresolved')
          A.same(built.result_lines, {
            'intro updated',
            'first main',
            'gap one adjusted',
            'gap two',
            'gap three',
            'second base',
            'outro updated',
          })
        end)
      end,
    },
    {
      name = 'prepare_write reconstructs marker form while preserving stable edits and explicit handled conflicts',
      run = function()
        N.with_repo('repo_conflict_multi', function()
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]
          local previous_model = assert(merge_model.build(file))

          assert(merge_model.apply_action(previous_model, 1, 'accept_ours'))
          assert(merge_model.apply_action(previous_model, 1, 'ignore_theirs'))

          local prepared = assert(merge_model.prepare_write(file, {
            'intro updated',
            'first main',
            'gap one adjusted',
            'gap two',
            'gap three',
            'second base',
            'outro updated',
          }, {
            previous_model = previous_model,
          }))

          A.equal(prepared.model.unresolved_count, 1)
          A.equal(prepared.model.conflicts[1].state, 'ours')
          A.truthy(prepared.model.conflicts[1].handled)
          A.same(prepared.persisted_lines, {
            'intro updated',
            'first main',
            'gap one adjusted',
            'gap two',
            'gap three',
            '<<<<<<< Ours',
            'second main',
            '||||||| Base',
            'second base',
            '=======',
            'second feature',
            '>>>>>>> Theirs',
            'outro updated',
          })
        end)
      end,
    },
    {
      name = 'build keeps add/add conflicts addressable even without base lines',
      run = function()
        N.with_repo('repo_conflict_add_add', function()
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]
          local built = assert(merge_model.build(file))

          A.equal(built.unresolved_count, 1)
          A.same(built.base_lines, {})
          A.equal(built.conflicts[1].result_range.start, 1)
          A.equal(built.conflicts[1].result_range.count, 0)
        end)
      end,
    },
    {
      name = 'prepare_write preserves no-trailing-newline state after an explicit full resolution',
      run = function()
        N.with_repo('repo_conflict_noeol', function()
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]
          local previous_model = assert(merge_model.build(file))

          assert(merge_model.apply_action(previous_model, 1, 'accept_ours'))
          assert(merge_model.apply_action(previous_model, 1, 'ignore_theirs'))

          local prepared = assert(merge_model.prepare_write(file, { 'main' }, {
            current_ends_with_newline = false,
            previous_model = previous_model,
          }))

          A.equal(prepared.persisted_text, 'main')
        end)
      end,
    },
    {
      name = 'prepare_write keeps plain base text unresolved without an explicit action',
      run = function()
        N.with_repo('repo_conflict', function()
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]
          local previous_model = assert(merge_model.build(file))

          local prepared = assert(merge_model.prepare_write(file, { 'base' }, {
            previous_model = previous_model,
          }))

          A.equal(prepared.model.conflicts[1].state, 'unresolved')
          A.falsy(prepared.model.conflicts[1].handled)
          A.same(prepared.persisted_lines, {
            '<<<<<<< Ours',
            'main',
            '||||||| Base',
            'base',
            '=======',
            'feature',
            '>>>>>>> Theirs',
          })
        end)
      end,
    },
    {
      name = 'rebuild preserves explicit in-session states when the clean result text is unchanged',
      run = function()
        N.with_repo('repo_conflict', function()
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]

          local pending = assert(merge_model.build(file))
          assert(merge_model.apply_action(pending, 1, 'accept_ours'))

          local rebuilt_pending = assert(merge_model.build(file, {
            current_lines = { 'main' },
            current_ends_with_newline = true,
            previous_model = pending,
            manual_clean_state = 'manual_unresolved',
          }))

          A.same(snapshot(rebuilt_pending.conflicts[1]), {
            state = 'ours',
            ours_handled = true,
            theirs_handled = false,
            handled = false,
            current_result_lines = { 'main' },
          })

          local handled_base = assert(merge_model.build(file))
          assert(merge_model.apply_action(handled_base, 1, 'ignore_ours'))
          assert(merge_model.apply_action(handled_base, 1, 'ignore_theirs'))

          local rebuilt_base = assert(merge_model.build(file, {
            current_lines = { 'base' },
            current_ends_with_newline = true,
            previous_model = handled_base,
            manual_clean_state = 'manual_unresolved',
          }))

          A.same(snapshot(rebuilt_base.conflicts[1]), {
            state = 'base_only',
            ours_handled = true,
            theirs_handled = true,
            handled = true,
            current_result_lines = { 'base' },
          })
        end)
      end,
    },
    {
      name = 'text-conflict action transitions use replacement semantics instead of additive semantics',
      run = function()
        N.with_repo('repo_conflict', function()
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]
          local cases = {
            {
              actions = { 'accept_ours' },
              expected = {
                state = 'ours',
                ours_handled = true,
                theirs_handled = false,
                handled = false,
                current_result_lines = { 'main' },
              },
            },
            {
              actions = { 'accept_theirs' },
              expected = {
                state = 'theirs',
                ours_handled = false,
                theirs_handled = true,
                handled = false,
                current_result_lines = { 'feature' },
              },
            },
            {
              actions = { 'ignore_ours' },
              expected = {
                state = 'base_only',
                ours_handled = true,
                theirs_handled = false,
                handled = false,
                current_result_lines = { 'base' },
              },
            },
            {
              actions = { 'ignore_theirs' },
              expected = {
                state = 'base_only',
                ours_handled = false,
                theirs_handled = true,
                handled = false,
                current_result_lines = { 'base' },
              },
            },
            {
              actions = { 'accept_theirs', 'accept_ours' },
              expected = {
                state = 'ours',
                ours_handled = true,
                theirs_handled = true,
                handled = true,
                current_result_lines = { 'main' },
              },
            },
            {
              actions = { 'accept_ours', 'accept_theirs' },
              expected = {
                state = 'theirs',
                ours_handled = true,
                theirs_handled = true,
                handled = true,
                current_result_lines = { 'feature' },
              },
            },
            {
              actions = { 'ignore_theirs', 'accept_ours' },
              expected = {
                state = 'ours',
                ours_handled = true,
                theirs_handled = true,
                handled = true,
                current_result_lines = { 'main' },
              },
            },
            {
              actions = { 'ignore_ours', 'accept_theirs' },
              expected = {
                state = 'theirs',
                ours_handled = true,
                theirs_handled = true,
                handled = true,
                current_result_lines = { 'feature' },
              },
            },
            {
              actions = { 'accept_ours', 'ignore_theirs' },
              expected = {
                state = 'ours',
                ours_handled = true,
                theirs_handled = true,
                handled = true,
                current_result_lines = { 'main' },
              },
            },
            {
              actions = { 'accept_theirs', 'ignore_ours' },
              expected = {
                state = 'theirs',
                ours_handled = true,
                theirs_handled = true,
                handled = true,
                current_result_lines = { 'feature' },
              },
            },
            {
              actions = { 'ignore_theirs', 'ignore_ours' },
              expected = {
                state = 'base_only',
                ours_handled = true,
                theirs_handled = true,
                handled = true,
                current_result_lines = { 'base' },
              },
            },
            {
              actions = { 'accept_both_ours_then_theirs', 'accept_ours' },
              expected = {
                state = 'ours',
                ours_handled = true,
                theirs_handled = true,
                handled = true,
                current_result_lines = { 'main' },
              },
            },
            {
              actions = { 'accept_both_theirs_then_ours', 'accept_theirs' },
              expected = {
                state = 'theirs',
                ours_handled = true,
                theirs_handled = true,
                handled = true,
                current_result_lines = { 'feature' },
              },
            },
            {
              actions = { 'accept_ours', 'reset_conflict' },
              expected = {
                state = 'unresolved',
                ours_handled = false,
                theirs_handled = false,
                handled = false,
                current_result_lines = { 'base' },
              },
            },
          }

          for _, case in ipairs(cases) do
            local built = assert(merge_model.build(file))
            for _, action in ipairs(case.actions) do
              assert(merge_model.apply_action(built, 1, action))
            end

            A.same(snapshot(built.conflicts[1]), case.expected)
          end
        end)
      end,
    },
    {
      name = 'text-conflict action matrix covers every reachable state and action pair',
      run = function()
        N.with_repo('repo_conflict', function()
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]
          local lines = {
            base = { 'base' },
            ours = { 'main' },
            theirs = { 'feature' },
            both_ours_then_theirs = { 'main', 'feature' },
            both_theirs_then_ours = { 'feature', 'main' },
            manual = { 'custom merge draft' },
          }
          local invalid_mark_resolved = 'mark resolved is only available for manual unresolved conflicts'
          local invalid_manual_ignore = 'ignore actions are not available for manual merge states'

          local expected = {
            unresolved = expected_snapshot('unresolved', false, false, lines.base),
            pending_ours = expected_snapshot('ours', true, false, lines.ours),
            pending_theirs = expected_snapshot('theirs', false, true, lines.theirs),
            pending_base_from_ignore_ours = expected_snapshot('base_only', true, false, lines.base),
            pending_base_from_ignore_theirs = expected_snapshot('base_only', false, true, lines.base),
            handled_ours = expected_snapshot('ours', true, true, lines.ours),
            handled_theirs = expected_snapshot('theirs', true, true, lines.theirs),
            handled_both_ours_then_theirs =
              expected_snapshot('both_ours_then_theirs', true, true, lines.both_ours_then_theirs),
            handled_both_theirs_then_ours =
              expected_snapshot('both_theirs_then_ours', true, true, lines.both_theirs_then_ours),
            handled_base = expected_snapshot('base_only', true, true, lines.base),
            manual_unresolved = expected_snapshot('manual_unresolved', false, false, lines.manual),
            manual_resolved = expected_snapshot('manual_resolved', true, true, lines.manual),
          }

          local function build_base_model()
            return assert(merge_model.build(file))
          end

          local function build_manual_variant(mark_resolved)
            local previous_model = build_base_model()
            local manual_model = assert(merge_model.build(file, {
              current_lines = lines.manual,
              current_ends_with_newline = true,
              previous_model = previous_model,
              manual_clean_state = 'manual_unresolved',
            }))
            if mark_resolved then
              assert(merge_model.apply_action(manual_model, 1, 'mark_resolved'))
            end
            return manual_model
          end

          local variants = {
            {
              name = 'unresolved',
              model = build_base_model(),
            },
            {
              name = 'pending_ours',
              model = (function()
                local model = build_base_model()
                assert(merge_model.apply_action(model, 1, 'accept_ours'))
                return model
              end)(),
            },
            {
              name = 'pending_theirs',
              model = (function()
                local model = build_base_model()
                assert(merge_model.apply_action(model, 1, 'accept_theirs'))
                return model
              end)(),
            },
            {
              name = 'pending_base_from_ignore_ours',
              model = (function()
                local model = build_base_model()
                assert(merge_model.apply_action(model, 1, 'ignore_ours'))
                return model
              end)(),
            },
            {
              name = 'pending_base_from_ignore_theirs',
              model = (function()
                local model = build_base_model()
                assert(merge_model.apply_action(model, 1, 'ignore_theirs'))
                return model
              end)(),
            },
            {
              name = 'handled_ours',
              model = (function()
                local model = build_base_model()
                assert(merge_model.apply_action(model, 1, 'accept_theirs'))
                assert(merge_model.apply_action(model, 1, 'accept_ours'))
                return model
              end)(),
            },
            {
              name = 'handled_theirs',
              model = (function()
                local model = build_base_model()
                assert(merge_model.apply_action(model, 1, 'accept_ours'))
                assert(merge_model.apply_action(model, 1, 'accept_theirs'))
                return model
              end)(),
            },
            {
              name = 'handled_both_ours_then_theirs',
              model = (function()
                local model = build_base_model()
                assert(merge_model.apply_action(model, 1, 'accept_both_ours_then_theirs'))
                return model
              end)(),
            },
            {
              name = 'handled_both_theirs_then_ours',
              model = (function()
                local model = build_base_model()
                assert(merge_model.apply_action(model, 1, 'accept_both_theirs_then_ours'))
                return model
              end)(),
            },
            {
              name = 'handled_base',
              model = (function()
                local model = build_base_model()
                assert(merge_model.apply_action(model, 1, 'ignore_ours'))
                assert(merge_model.apply_action(model, 1, 'ignore_theirs'))
                return model
              end)(),
            },
            {
              name = 'manual_unresolved',
              model = build_manual_variant(false),
            },
            {
              name = 'manual_resolved',
              model = build_manual_variant(true),
            },
          }

          local transitions = {
            unresolved = {
              mark_resolved = { err = invalid_mark_resolved },
              reset_conflict = expected.unresolved,
              accept_both_ours_then_theirs = expected.handled_both_ours_then_theirs,
              accept_both_theirs_then_ours = expected.handled_both_theirs_then_ours,
              accept_ours = expected.pending_ours,
              accept_theirs = expected.pending_theirs,
              ignore_ours = expected.pending_base_from_ignore_ours,
              ignore_theirs = expected.pending_base_from_ignore_theirs,
            },
            pending_ours = {
              mark_resolved = { err = invalid_mark_resolved },
              reset_conflict = expected.unresolved,
              accept_both_ours_then_theirs = expected.handled_both_ours_then_theirs,
              accept_both_theirs_then_ours = expected.handled_both_theirs_then_ours,
              accept_ours = expected.pending_ours,
              accept_theirs = expected.handled_theirs,
              ignore_ours = expected.pending_ours,
              ignore_theirs = expected.handled_ours,
            },
            pending_theirs = {
              mark_resolved = { err = invalid_mark_resolved },
              reset_conflict = expected.unresolved,
              accept_both_ours_then_theirs = expected.handled_both_ours_then_theirs,
              accept_both_theirs_then_ours = expected.handled_both_theirs_then_ours,
              accept_ours = expected.handled_ours,
              accept_theirs = expected.pending_theirs,
              ignore_ours = expected.handled_theirs,
              ignore_theirs = expected.pending_theirs,
            },
            pending_base_from_ignore_ours = {
              mark_resolved = { err = invalid_mark_resolved },
              reset_conflict = expected.unresolved,
              accept_both_ours_then_theirs = expected.handled_both_ours_then_theirs,
              accept_both_theirs_then_ours = expected.handled_both_theirs_then_ours,
              accept_ours = expected.pending_ours,
              accept_theirs = expected.handled_theirs,
              ignore_ours = expected.pending_base_from_ignore_ours,
              ignore_theirs = expected.handled_base,
            },
            pending_base_from_ignore_theirs = {
              mark_resolved = { err = invalid_mark_resolved },
              reset_conflict = expected.unresolved,
              accept_both_ours_then_theirs = expected.handled_both_ours_then_theirs,
              accept_both_theirs_then_ours = expected.handled_both_theirs_then_ours,
              accept_ours = expected.handled_ours,
              accept_theirs = expected.pending_theirs,
              ignore_ours = expected.handled_base,
              ignore_theirs = expected.pending_base_from_ignore_theirs,
            },
            handled_ours = {
              mark_resolved = { err = invalid_mark_resolved },
              reset_conflict = expected.unresolved,
              accept_both_ours_then_theirs = expected.handled_both_ours_then_theirs,
              accept_both_theirs_then_ours = expected.handled_both_theirs_then_ours,
              accept_ours = expected.handled_ours,
              accept_theirs = expected.handled_theirs,
              ignore_ours = expected.handled_ours,
              ignore_theirs = expected.handled_ours,
            },
            handled_theirs = {
              mark_resolved = { err = invalid_mark_resolved },
              reset_conflict = expected.unresolved,
              accept_both_ours_then_theirs = expected.handled_both_ours_then_theirs,
              accept_both_theirs_then_ours = expected.handled_both_theirs_then_ours,
              accept_ours = expected.handled_ours,
              accept_theirs = expected.handled_theirs,
              ignore_ours = expected.handled_theirs,
              ignore_theirs = expected.handled_theirs,
            },
            handled_both_ours_then_theirs = {
              mark_resolved = { err = invalid_mark_resolved },
              reset_conflict = expected.unresolved,
              accept_both_ours_then_theirs = expected.handled_both_ours_then_theirs,
              accept_both_theirs_then_ours = expected.handled_both_theirs_then_ours,
              accept_ours = expected.handled_ours,
              accept_theirs = expected.handled_theirs,
              ignore_ours = expected.handled_both_ours_then_theirs,
              ignore_theirs = expected.handled_both_ours_then_theirs,
            },
            handled_both_theirs_then_ours = {
              mark_resolved = { err = invalid_mark_resolved },
              reset_conflict = expected.unresolved,
              accept_both_ours_then_theirs = expected.handled_both_ours_then_theirs,
              accept_both_theirs_then_ours = expected.handled_both_theirs_then_ours,
              accept_ours = expected.handled_ours,
              accept_theirs = expected.handled_theirs,
              ignore_ours = expected.handled_both_theirs_then_ours,
              ignore_theirs = expected.handled_both_theirs_then_ours,
            },
            handled_base = {
              mark_resolved = { err = invalid_mark_resolved },
              reset_conflict = expected.unresolved,
              accept_both_ours_then_theirs = expected.handled_both_ours_then_theirs,
              accept_both_theirs_then_ours = expected.handled_both_theirs_then_ours,
              accept_ours = expected.handled_ours,
              accept_theirs = expected.handled_theirs,
              ignore_ours = expected.handled_base,
              ignore_theirs = expected.handled_base,
            },
            manual_unresolved = {
              mark_resolved = expected.manual_resolved,
              reset_conflict = expected.unresolved,
              accept_both_ours_then_theirs = expected.handled_both_ours_then_theirs,
              accept_both_theirs_then_ours = expected.handled_both_theirs_then_ours,
              accept_ours = expected.pending_ours,
              accept_theirs = expected.pending_theirs,
              ignore_ours = { err = invalid_manual_ignore },
              ignore_theirs = { err = invalid_manual_ignore },
            },
            manual_resolved = {
              mark_resolved = { err = invalid_mark_resolved },
              reset_conflict = expected.unresolved,
              accept_both_ours_then_theirs = expected.handled_both_ours_then_theirs,
              accept_both_theirs_then_ours = expected.handled_both_theirs_then_ours,
              accept_ours = expected.handled_ours,
              accept_theirs = expected.handled_theirs,
              ignore_ours = { err = invalid_manual_ignore },
              ignore_theirs = { err = invalid_manual_ignore },
            },
          }

          local actions = {
            'mark_resolved',
            'reset_conflict',
            'accept_both_ours_then_theirs',
            'accept_both_theirs_then_ours',
            'accept_ours',
            'accept_theirs',
            'ignore_ours',
            'ignore_theirs',
          }
          local exercised = 0

          for _, variant in ipairs(variants) do
            A.same(snapshot(variant.model.conflicts[1]), expected[variant.name])
            for _, action in ipairs(actions) do
              local merge_state = vim.deepcopy(variant.model)
              local outcome = transitions[variant.name][action]
              local updated, err = merge_model.apply_action(merge_state, 1, action)

              exercised = exercised + 1
              if outcome.err then
                A.equal(updated, nil)
                A.contains(err or '', outcome.err)
              else
                A.truthy(updated)
                A.same(snapshot(merge_state.conflicts[1]), outcome)
              end
            end
          end

          A.equal(exercised, #variants * #actions)
        end)
      end,
    },
    {
      name = 'accept ours persists and rehydrates as a partial unresolved state',
      run = function()
        N.with_repo('repo_conflict', function(repo)
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]
          local previous_model = assert(merge_model.build(file))

          local updated = assert(merge_model.apply_action(previous_model, 1, 'accept_ours'))
          A.equal(updated.state, 'ours')
          A.truthy(updated.ours_handled)
          A.falsy(updated.theirs_handled)
          A.falsy(updated.handled)

          local prepared = assert(merge_model.prepare_write(file, { 'main' }, {
            previous_model = previous_model,
          }))

          A.same(prepared.persisted_lines, {
            '<<<<<<< Ours',
            'main',
            '||||||| Base',
            'main',
            '=======',
            'feature',
            '>>>>>>> Theirs',
          })

          repo:write(repo.files.tracked, prepared.persisted_text)

          local reopened = assert(merge_model.build(file))
          A.equal(reopened.conflicts[1].state, 'ours')
          A.truthy(reopened.conflicts[1].ours_handled)
          A.falsy(reopened.conflicts[1].theirs_handled)
          A.falsy(reopened.conflicts[1].handled)
          A.equal(reopened.unresolved_count, 1)
          A.same(reopened.result_lines, { 'main' })
        end)
      end,
    },
    {
      name = 'mark resolved persists clean manual text and reopens as manual_resolved',
      run = function()
        N.with_repo('repo_conflict', function(repo)
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]
          local manual_lines = { 'base + feature rewrite' }

          local previous_model = assert(merge_model.build(file))
          local rejected, err = merge_model.prepare_write(file, manual_lines, {
            previous_model = previous_model,
          })
          A.equal(rejected, nil)
          A.contains(err, 'cannot safely save unresolved manual merge edits yet')

          local manual_model = assert(merge_model.build(file, {
            current_lines = manual_lines,
            current_ends_with_newline = true,
            previous_model = previous_model,
            manual_clean_state = 'manual_unresolved',
          }))

          A.equal(manual_model.conflicts[1].state, 'manual_unresolved')
          assert(merge_model.apply_action(manual_model, 1, 'mark_resolved'))

          local prepared = assert(merge_model.prepare_write(file, manual_lines, {
            previous_model = manual_model,
          }))

          A.equal(prepared.persisted_text, 'base + feature rewrite\n')
          repo:write(repo.files.tracked, prepared.persisted_text)

          local reopened = assert(merge_model.build(file))
          A.equal(reopened.conflicts[1].state, 'manual_resolved')
          A.truthy(reopened.conflicts[1].handled)
          A.same(reopened.result_lines, manual_lines)
        end)
      end,
    },
    {
      name = 'accept ours keeps add/add conflicts visible and serializable with an empty base',
      run = function()
        N.with_repo('repo_conflict_add_add', function(repo)
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]
          local previous_model = assert(merge_model.build(file))

          assert(merge_model.apply_action(previous_model, 1, 'accept_ours'))

          local prepared = assert(merge_model.prepare_write(file, { 'main add' }, {
            previous_model = previous_model,
          }))

          A.same(prepared.persisted_lines, {
            '<<<<<<< Ours',
            'main add',
            '||||||| Base',
            'main add',
            '=======',
            'feature add',
            '>>>>>>> Theirs',
          })

          repo:write(repo.files.tracked, prepared.persisted_text)

          local reopened = assert(merge_model.build(file))
          A.equal(reopened.conflicts[1].state, 'ours')
          A.equal(reopened.conflicts[1].result_range.start, 1)
          A.equal(reopened.conflicts[1].result_range.count, 1)
          A.equal(reopened.unresolved_count, 1)
          A.same(reopened.result_lines, { 'main add' })
        end)
      end,
    },
    {
      name = 'zero-line conflicts stay unresolved when empty and reset back to unresolved empty',
      run = function()
        N.with_repo('repo_conflict_zero_line', function()
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]
          local built = assert(merge_model.build(file))

          A.equal(built.unresolved_count, 1)
          A.equal(built.conflicts[1].state, 'unresolved')
          A.equal(built.conflicts[1].result_range.start, 2)
          A.equal(built.conflicts[1].result_range.count, 0)
          A.same(built.result_lines, { 'alpha', 'omega' })

          local edited = assert(merge_model.build(file, {
            current_lines = { 'alpha', 'draft', 'omega' },
            current_ends_with_newline = true,
            previous_model = built,
            manual_clean_state = 'manual_unresolved',
          }))

          A.equal(edited.conflicts[1].state, 'manual_unresolved')
          A.falsy(edited.conflicts[1].handled)

          local reverted = assert(merge_model.build(file, {
            current_lines = { 'alpha', 'omega' },
            current_ends_with_newline = true,
            previous_model = edited,
            manual_clean_state = 'manual_unresolved',
          }))

          A.equal(reverted.conflicts[1].state, 'manual_unresolved')
          A.falsy(reverted.conflicts[1].handled)

          assert(merge_model.apply_action(reverted, 1, 'reset_conflict'))
          A.equal(reverted.conflicts[1].state, 'unresolved')
          A.same(reverted.conflicts[1].current_result_lines, {})
          A.falsy(reverted.conflicts[1].handled)
        end)
      end,
    },
    {
      name = 'prepare_write serializes unresolved zero-line conflicts without changing their semantic state',
      run = function()
        N.with_repo('repo_conflict_zero_line', function()
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]
          local previous_model = assert(merge_model.build(file))

          local prepared = assert(merge_model.prepare_write(file, { 'alpha', 'omega' }, {
            previous_model = previous_model,
          }))

          A.equal(prepared.model.conflicts[1].state, 'unresolved')
          A.same(prepared.persisted_lines, {
            'alpha',
            '<<<<<<< Ours',
            'main insert',
            '||||||| Base',
            '=======',
            'feature insert',
            '>>>>>>> Theirs',
            'omega',
          })
        end)
      end,
    },
  },
}
