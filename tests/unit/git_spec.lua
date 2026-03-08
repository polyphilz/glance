local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

return {
  name = 'git',
  cases = {
    {
      name = 'parse handles empty output',
      run = function()
        local git = require('glance.git')
        A.same(git.parse_porcelain_status(''), {
          staged = {},
          changes = {},
          untracked = {},
        })
      end,
    },
    {
      name = 'parse categorizes modified staged and untracked entries',
      run = function()
        local git = require('glance.git')
        local parsed = git.parse_porcelain_status(table.concat({
          ' M changed.txt',
          'M  staged.txt',
          '?? new.txt',
        }, '\n'))

        A.length(parsed.changes, 1)
        A.same(parsed.changes[1], {
          path = 'changed.txt',
          status = 'M',
          section = 'changes',
          old_path = nil,
        })
        A.length(parsed.staged, 1)
        A.same(parsed.staged[1], {
          path = 'staged.txt',
          status = 'M',
          section = 'staged',
          old_path = nil,
        })
        A.length(parsed.untracked, 1)
        A.same(parsed.untracked[1], {
          path = 'new.txt',
          status = '?',
          section = 'untracked',
        })
      end,
    },
    {
      name = 'parse keeps MM entries in staged and changes',
      run = function()
        local git = require('glance.git')
        local parsed = git.parse_porcelain_status('MM mixed.txt')

        A.length(parsed.staged, 1)
        A.length(parsed.changes, 1)
        A.equal(parsed.staged[1].path, 'mixed.txt')
        A.equal(parsed.changes[1].path, 'mixed.txt')
      end,
    },
    {
      name = 'parse preserves rename old path and deletes',
      run = function()
        local git = require('glance.git')
        local parsed = git.parse_porcelain_status(table.concat({
          'R  old/name.txt -> new/name.txt',
          ' D gone.txt',
        }, '\n'))

        A.length(parsed.staged, 1)
        A.equal(parsed.staged[1].old_path, 'old/name.txt')
        A.equal(parsed.staged[1].path, 'new/name.txt')
        A.length(parsed.changes, 1)
        A.equal(parsed.changes[1].status, 'D')
        A.equal(parsed.changes[1].path, 'gone.txt')
      end,
    },
    {
      name = 'integration reads repo state and file content',
      run = function()
        N.with_repo('repo_mixed_mm', function(repo)
          local git = require('glance.git')
          A.truthy(git.is_repo())
          A.equal(git.repo_root(), repo.root)

          local files = git.get_changed_files()
          A.length(files.staged, 1)
          A.length(files.changes, 1)
          A.equal(files.staged[1].path, repo.files.tracked)
          A.equal(files.changes[1].path, repo.files.tracked)

          A.same(git.get_file_content(repo.files.tracked, 'HEAD'), {
            'alpha',
            'beta',
            'gamma',
          })
          A.same(git.get_file_content(repo.files.tracked, ':'), {
            'alpha',
            'beta staged',
            'gamma',
          })
          A.same(git.get_file_content(repo.files.tracked, nil), {
            'alpha',
            'beta staged',
            'gamma',
            'unstaged tail',
          })
          A.same(git.get_file_content('missing.txt', 'HEAD'), {})
        end)
      end,
    },
    {
      name = 'integration handles newline stability and binary detection',
      run = function()
        N.with_repo('repo_binary', function(repo)
          local git = require('glance.git')
          A.same(git.get_file_content(repo.files.tracked, 'HEAD'), {
            'alpha',
            'beta',
            'gamma',
          })
          A.truthy(git.is_binary(repo:path(repo.files.binary)))
          A.falsy(git.is_binary(repo:path(repo.files.tracked)))
        end)
      end,
    },
  },
}
