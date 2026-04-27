local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

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
      name = 'build rehydrates a clean ours resolution without conflict markers',
      run = function()
        N.with_repo('repo_conflict', function(repo)
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]

          repo:write(repo.files.tracked, 'main\n')

          local built = assert(merge_model.build(file))

          A.equal(built.unresolved_count, 0)
          A.equal(built.conflicts[1].state, 'ours')
          A.truthy(built.conflicts[1].handled)
          A.same(built.result_lines, { 'main' })
        end)
      end,
    },
    {
      name = 'build keeps mixed handled and unresolved conflicts in order',
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
          A.equal(built.conflicts[1].state, 'ours')
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
      name = 'build preserves stable edits around recognized conflict states',
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
          A.equal(built.conflicts[1].state, 'ours')
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
      name = 'prepare_write reconstructs marker form while preserving stable edits and handled conflicts',
      run = function()
        N.with_repo('repo_conflict_multi', function(repo)
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]
          local previous_model = assert(merge_model.build(file))

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
      name = 'prepare_write preserves no-trailing-newline state',
      run = function()
        N.with_repo('repo_conflict_noeol', function()
          local git = require('glance.git')
          local merge_model = require('glance.merge.model')
          local file = git.get_changed_files().conflicts[1]

          local prepared = assert(merge_model.prepare_write(file, { 'main' }, {
            current_ends_with_newline = false,
            previous_model = assert(merge_model.build(file)),
          }))

          A.equal(prepared.persisted_text, 'main')
        end)
      end,
    },
    {
      name = 'prepare_write does not treat plain base text as resolved without an explicit action',
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
  },
}
