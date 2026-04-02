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
  },
}
