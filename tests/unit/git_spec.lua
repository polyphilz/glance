local A = require('tests.helpers.assert')
local N = require('tests.helpers.nvim')

local function files(overrides)
  return vim.tbl_extend('force', {
    staged = {},
    changes = {},
    untracked = {},
    conflicts = {},
  }, overrides or {})
end

local function file(overrides)
  return vim.tbl_extend('force', {
    path = '',
    section = '',
    status = '',
    display_status = '',
    kind = '',
    is_binary = false,
    x = '',
    y = '',
    raw_status = '',
  }, overrides or {})
end

return {
  name = 'git',
  cases = {
    {
      name = 'parse handles empty output',
      run = function()
        local git = require('glance.git')
        A.same(git.parse_porcelain_status(''), files())
      end,
    },
    {
      name = 'low-level parse preserves raw status and old path for rename and copy entries',
      run = function()
        local git = require('glance.git')
        local entries = git.parse_porcelain_entries(table.concat({
          'R  old/name.txt -> new/name.txt',
          'C  src/original.txt -> src/copy.txt',
          '?? scratch.txt',
        }, '\n'))

        A.same(entries, {
          {
            path = 'new/name.txt',
            old_path = 'old/name.txt',
            x = 'R',
            y = ' ',
            raw_status = 'R ',
          },
          {
            path = 'src/copy.txt',
            old_path = 'src/original.txt',
            x = 'C',
            y = ' ',
            raw_status = 'C ',
          },
          {
            path = 'scratch.txt',
            x = '?',
            y = '?',
            raw_status = '??',
          },
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

        A.same(parsed, files({
          changes = {
            file({
              path = 'changed.txt',
              section = 'changes',
              status = 'M',
              display_status = 'M',
              kind = 'modified',
              x = ' ',
              y = 'M',
              raw_status = ' M',
            }),
          },
          staged = {
            file({
              path = 'staged.txt',
              section = 'staged',
              status = 'M',
              display_status = 'M',
              kind = 'modified',
              x = 'M',
              y = ' ',
              raw_status = 'M ',
            }),
          },
          untracked = {
            file({
              path = 'new.txt',
              section = 'untracked',
              status = '?',
              display_status = '?',
              kind = 'untracked',
              x = '?',
              y = '?',
              raw_status = '??',
            }),
          },
        }))
      end,
    },
    {
      name = 'parse keeps MM entries in staged and changes',
      run = function()
        local git = require('glance.git')
        local parsed = git.parse_porcelain_status('MM mixed.txt')

        A.same(parsed.staged, {
          file({
            path = 'mixed.txt',
            section = 'staged',
            status = 'M',
            display_status = 'M',
            kind = 'modified',
            x = 'M',
            y = 'M',
            raw_status = 'MM',
          }),
        })
        A.same(parsed.changes, {
          file({
            path = 'mixed.txt',
            section = 'changes',
            status = 'M',
            display_status = 'M',
            kind = 'modified',
            x = 'M',
            y = 'M',
            raw_status = 'MM',
          }),
        })
        A.same(parsed.conflicts, {})
      end,
    },
    {
      name = 'parse preserves rename old path and classifies deletes',
      run = function()
        local git = require('glance.git')
        local parsed = git.parse_porcelain_status(table.concat({
          'R  old/name.txt -> new/name.txt',
          ' D gone.txt',
        }, '\n'))

        A.same(parsed.staged, {
          file({
            path = 'new/name.txt',
            old_path = 'old/name.txt',
            section = 'staged',
            status = 'R',
            display_status = 'R',
            kind = 'renamed',
            x = 'R',
            y = ' ',
            raw_status = 'R ',
          }),
        })
        A.same(parsed.changes, {
          file({
            path = 'gone.txt',
            section = 'changes',
            status = 'D',
            display_status = 'D',
            kind = 'deleted',
            x = ' ',
            y = 'D',
            raw_status = ' D',
          }),
        })
      end,
    },
    {
      name = 'parse routes all unmerged status pairs into conflicts',
      run = function()
        local git = require('glance.git')
        local pairs = {
          'DD',
          'AU',
          'UD',
          'UA',
          'DU',
          'AA',
          'UU',
        }
        local lines = {}
        local expected = {}

        for _, pair in ipairs(pairs) do
          local path = pair:lower() .. '.txt'
          lines[#lines + 1] = pair .. ' ' .. path
          expected[#expected + 1] = file({
            path = path,
            section = 'conflicts',
            status = 'U',
            display_status = 'U',
            kind = 'conflicted',
            x = pair:sub(1, 1),
            y = pair:sub(2, 2),
            raw_status = pair,
          })
        end

        local parsed = git.parse_porcelain_status(table.concat(lines, '\n'))

        A.same(parsed, files({
          conflicts = expected,
        }))
      end,
    },
    {
      name = 'classify handles type-changed copied conflicted and unsupported entries',
      run = function()
        local git = require('glance.git')

        A.same(git.classify_entry({
          path = 'symlink.txt',
          x = 'T',
          y = ' ',
          raw_status = 'T ',
        }, 'staged'), {
          kind = 'type_changed',
          status = 'T',
          display_status = 'T',
        })

        A.same(git.classify_entry({
          path = 'copy.txt',
          x = ' ',
          y = 'C',
          raw_status = ' C',
        }, 'changes'), {
          kind = 'copied',
          status = 'C',
          display_status = 'C',
        })

        A.same(git.classify_entry({
          path = 'conflict.txt',
          x = 'U',
          y = 'U',
          raw_status = 'UU',
        }, 'staged'), {
          kind = 'conflicted',
          status = 'U',
          display_status = 'U',
        })

        A.same(git.classify_entry({
          path = 'mystery.txt',
          x = 'X',
          y = ' ',
          raw_status = 'X ',
        }, 'staged'), {
          kind = 'unsupported',
          status = 'X',
          display_status = 'X',
        })
      end,
    },
    {
      name = 'discard safety allows ordinary states and blocks non-ordinary or binary entries',
      run = function()
        local git = require('glance.git')
        local ok, err, blocked

        ok, err = git.can_discard_file({
          path = 'tracked.txt',
          kind = 'modified',
          status = 'M',
          section = 'changes',
        })
        A.truthy(ok, err)
        A.equal(err, nil)

        ok, err = git.can_discard_file({
          path = 'scratch.txt',
          kind = 'untracked',
          status = '?',
          section = 'untracked',
        })
        A.truthy(ok, err)
        A.equal(err, nil)

        ok, err = git.can_discard_file({
          path = 'conflict.txt',
          kind = 'conflicted',
          status = 'U',
          section = 'conflicts',
        })
        A.falsy(ok)
        A.equal(err, git.UNSUPPORTED_DISCARD_MESSAGE)

        ok, err = git.can_discard_file({
          path = 'typed.txt',
          status = 'T',
          section = 'changes',
        })
        A.falsy(ok)
        A.equal(err, git.UNSUPPORTED_DISCARD_MESSAGE)

        ok, err = git.can_discard_file({
          path = 'image.png',
          kind = 'added',
          status = 'A',
          section = 'staged',
          is_binary = true,
        })
        A.falsy(ok)
        A.equal(err, git.UNSUPPORTED_DISCARD_MESSAGE)

        ok, err, blocked = git.can_discard_all(files({
          staged = {
            file({
              path = 'copied.txt',
              kind = 'copied',
              status = 'C',
              section = 'staged',
            }),
          },
        }))
        A.falsy(ok)
        A.equal(err, git.UNSUPPORTED_DISCARD_MESSAGE)
        A.equal(blocked.path, 'copied.txt')
      end,
    },
    {
      name = 'integration reads repo state and file content',
      run = function()
        N.with_repo('repo_mixed_mm', function(repo)
          local git = require('glance.git')
          A.truthy(git.is_repo())
          A.equal(git.repo_root(), repo.root)

          local files_in_repo = git.get_changed_files()
          A.length(files_in_repo.staged, 1)
          A.length(files_in_repo.changes, 1)
          A.length(files_in_repo.conflicts, 0)
          A.equal(files_in_repo.staged[1].path, repo.files.tracked)
          A.equal(files_in_repo.staged[1].kind, 'modified')
          A.equal(files_in_repo.staged[1].raw_status, 'MM')
          A.equal(files_in_repo.changes[1].path, repo.files.tracked)
          A.equal(files_in_repo.changes[1].kind, 'modified')
          A.equal(files_in_repo.changes[1].raw_status, 'MM')

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
      name = 'integration classifies real merge conflicts into the conflicts section',
      run = function()
        N.with_repo('repo_conflict', function(repo)
          local git = require('glance.git')
          local changed = git.get_changed_files()

          A.same(changed.staged, {})
          A.same(changed.changes, {})
          A.same(changed.untracked, {})
          A.same(changed.conflicts, {
            file({
              path = repo.files.tracked,
              section = 'conflicts',
              status = 'U',
              display_status = 'U',
              kind = 'conflicted',
              x = 'U',
              y = 'U',
              raw_status = 'UU',
            }),
          })
        end)
      end,
    },
    {
      name = 'integration classifies type changes from git status',
      run = function()
        N.with_repo('repo_type_change', function(repo)
          local git = require('glance.git')
          local changed = git.get_changed_files()

          A.same(changed.staged, {})
          A.same(changed.untracked, {})
          A.same(changed.conflicts, {})
          A.same(changed.changes, {
            file({
              path = repo.files.tracked,
              section = 'changes',
              status = 'T',
              display_status = 'T',
              kind = 'type_changed',
              x = ' ',
              y = 'T',
              raw_status = ' T',
            }),
          })
        end)
      end,
    },
    {
      name = 'integration handles newline stability and untracked binary detection',
      run = function()
        N.with_repo('repo_binary', function(repo)
          local git = require('glance.git')
          local changed = git.get_changed_files()

          A.same(git.get_file_content(repo.files.tracked, 'HEAD'), {
            'alpha',
            'beta',
            'gamma',
          })
          A.same(changed.untracked, {
            file({
              path = repo.files.binary,
              section = 'untracked',
              status = '?',
              display_status = '?',
              kind = 'untracked',
              is_binary = true,
              x = '?',
              y = '?',
              raw_status = '??',
            }),
          })
          A.truthy(git.entry_is_binary(changed.untracked[1]))
          A.falsy(git.entry_is_binary({
            path = repo.files.tracked,
            section = 'changes',
            kind = 'modified',
          }))
        end)
      end,
    },
    {
      name = 'integration detects binary staged adds and unstaged binary modifications',
      run = function()
        local git = require('glance.git')

        N.with_repo('repo_binary_staged_add', function(repo)
          local changed = git.get_changed_files()

          A.same(changed.staged, {
            file({
              path = repo.files.binary,
              section = 'staged',
              status = 'A',
              display_status = 'A',
              kind = 'added',
              is_binary = true,
              x = 'A',
              y = ' ',
              raw_status = 'A ',
            }),
          })
        end)

        N.with_repo('repo_binary_modified', function(repo)
          local changed = git.get_changed_files()

          A.same(changed.changes, {
            file({
              path = repo.files.binary,
              section = 'changes',
              status = 'M',
              display_status = 'M',
              kind = 'modified',
              is_binary = true,
              x = ' ',
              y = 'M',
              raw_status = ' M',
            }),
          })
        end)
      end,
    },
    {
      name = 'integration discard_file rejects blocked git states without mutating the repo',
      run = function()
        local git = require('glance.git')

        N.with_repo('repo_type_change', function(repo)
          local changed = git.get_changed_files()
          local ok, err = git.discard_file(changed.changes[1])
          local status = repo:git({ 'status', '--porcelain=v1', '--untracked-files=all' })

          A.falsy(ok)
          A.equal(err, git.UNSUPPORTED_DISCARD_MESSAGE)
          A.contains(status, 'T tracked.txt')
        end)

        N.with_repo('repo_binary_staged_add', function(repo)
          local changed = git.get_changed_files()
          local ok, err = git.discard_file(changed.staged[1])
          local status = repo:git({ 'status', '--porcelain=v1', '--untracked-files=all' })

          A.falsy(ok)
          A.equal(err, git.UNSUPPORTED_DISCARD_MESSAGE)
          A.contains(status, 'A  ' .. repo.files.binary)
        end)
      end,
    },
    {
      name = 'integration discard_file restores a path back to HEAD',
      run = function()
        N.with_repo('repo_mixed_mm', function(repo)
          local git = require('glance.git')
          local changed = git.get_changed_files()
          local ok, err = git.discard_file(changed.changes[1])

          A.truthy(ok, err)
          A.same(git.get_changed_files(), files())
          A.equal(repo:read(repo.files.tracked), 'alpha\nbeta\ngamma\n')
        end)
      end,
    },
    {
      name = 'integration discard_all resets tracked staged and untracked changes',
      run = function()
        N.with_repo('repo_modified', function(repo)
          local git = require('glance.git')

          repo.files.staged_add = 'new-file.txt'
          repo.files.untracked = 'scratch.txt'
          repo:write(repo.files.staged_add, 'new staged file\n')
          repo:stage(repo.files.staged_add)
          repo:write(repo.files.untracked, 'scratch\n')

          local ok, err = git.discard_all()
          local status = repo:git({ 'status', '--porcelain=v1', '--untracked-files=all' })

          A.truthy(ok, err)
          A.equal(vim.trim(status), '')
          A.equal(repo:read(repo.files.tracked), 'alpha\nbeta\ngamma\n')
          A.falsy(vim.uv.fs_stat(repo:path(repo.files.staged_add)))
          A.falsy(vim.uv.fs_stat(repo:path(repo.files.untracked)))
        end)
      end,
    },
    {
      name = 'integration discard_all rejects repositories with blocked git states',
      run = function()
        N.with_repo('repo_conflict', function(repo)
          local git = require('glance.git')
          local ok, err = git.discard_all()
          local status = repo:git({ 'status', '--porcelain=v1', '--untracked-files=all' })

          A.falsy(ok)
          A.equal(err, git.UNSUPPORTED_DISCARD_MESSAGE)
          A.contains(status, 'UU ' .. repo.files.tracked)
        end)
      end,
    },
  },
}
