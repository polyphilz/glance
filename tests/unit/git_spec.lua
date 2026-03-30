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

local function find_file_in(section_files, path)
  for _, entry in ipairs(section_files or {}) do
    if entry.path == path then
      return entry
    end
  end
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
      name = 'entry path and kind helpers preserve rename information',
      run = function()
        local git = require('glance.git')

        A.same(git.entry_paths({
          old_path = 'old/name.txt',
          path = 'new/name.txt',
        }), {
          'old/name.txt',
          'new/name.txt',
        })

        A.same(git.entry_paths({
          path = 'tracked.txt',
        }), {
          'tracked.txt',
        })

        A.same(git.entry_paths({
          old_path = 'same.txt',
          path = 'same.txt',
        }), {
          'same.txt',
        })

        A.equal(git.infer_stage_kind({
          kind = 'renamed',
          status = 'R',
        }), 'renamed')
        A.equal(git.infer_stage_kind({
          path = 'scratch.txt',
          status = '?',
          section = 'untracked',
        }), 'untracked')
        A.equal(git.infer_stage_kind({
          path = 'typed.txt',
          status = 'T',
          section = 'staged',
        }), 'type_changed')
      end,
    },
    {
      name = 'stage and unstage safety distinguish wrong sections from unsupported states',
      run = function()
        local git = require('glance.git')
        local ok, err

        ok, err = git.can_stage_file({
          path = 'tracked.txt',
          kind = 'modified',
          status = 'M',
          section = 'changes',
        })
        A.truthy(ok, err)
        A.equal(err, nil)

        ok, err = git.can_stage_file({
          path = 'scratch.txt',
          kind = 'untracked',
          status = '?',
          section = 'untracked',
        })
        A.truthy(ok, err)
        A.equal(err, nil)

        ok, err = git.can_stage_file({
          path = 'tracked.txt',
          kind = 'modified',
          status = 'M',
          section = 'staged',
        })
        A.falsy(ok)
        A.equal(err, git.INVALID_STAGE_TARGET_MESSAGE)

        ok, err = git.can_stage_file({
          path = 'conflict.txt',
          kind = 'conflicted',
          status = 'U',
          section = 'conflicts',
        })
        A.falsy(ok)
        A.equal(err, git.UNSUPPORTED_STAGE_MESSAGE)

        ok, err = git.can_stage_file({
          path = 'typed.txt',
          kind = 'type_changed',
          status = 'T',
          section = 'changes',
        })
        A.falsy(ok)
        A.equal(err, git.UNSUPPORTED_STAGE_MESSAGE)

        ok, err = git.can_unstage_file({
          path = 'tracked.txt',
          kind = 'modified',
          status = 'M',
          section = 'staged',
        })
        A.truthy(ok, err)
        A.equal(err, nil)

        ok, err = git.can_unstage_file({
          path = 'new-file.txt',
          kind = 'added',
          status = 'A',
          section = 'staged',
        })
        A.truthy(ok, err)
        A.equal(err, nil)

        ok, err = git.can_unstage_file({
          path = 'tracked.txt',
          kind = 'modified',
          status = 'M',
          section = 'changes',
        })
        A.falsy(ok)
        A.equal(err, git.INVALID_UNSTAGE_TARGET_MESSAGE)

        ok, err = git.can_unstage_file({
          path = 'conflict.txt',
          kind = 'conflicted',
          status = 'U',
          section = 'conflicts',
        })
        A.falsy(ok)
        A.equal(err, git.UNSUPPORTED_UNSTAGE_MESSAGE)

        ok, err = git.can_unstage_file({
          path = 'typed.txt',
          kind = 'type_changed',
          status = 'T',
          section = 'staged',
        })
        A.falsy(ok)
        A.equal(err, git.UNSUPPORTED_UNSTAGE_MESSAGE)
      end,
    },
    {
      name = 'repo-wide stage and unstage safety stays conservative around unsupported states',
      run = function()
        local git = require('glance.git')
        local ok, err, blocked

        ok, err, blocked = git.can_stage_all(files({
          conflicts = {
            file({
              path = 'conflict.txt',
              kind = 'conflicted',
              status = 'U',
              section = 'conflicts',
            }),
          },
        }))
        A.falsy(ok)
        A.equal(err, git.UNSUPPORTED_STAGE_MESSAGE)
        A.equal(blocked.path, 'conflict.txt')

        ok, err, blocked = git.can_stage_all(files({
          changes = {
            file({
              path = 'typed.txt',
              kind = 'type_changed',
              status = 'T',
              section = 'changes',
            }),
          },
        }))
        A.falsy(ok)
        A.equal(err, git.UNSUPPORTED_STAGE_MESSAGE)
        A.equal(blocked.path, 'typed.txt')

        ok, err = git.can_unstage_all(files({
          staged = {
            file({
              path = 'tracked.txt',
              kind = 'modified',
              status = 'M',
              section = 'staged',
            }),
          },
          changes = {
            file({
              path = 'typed.txt',
              kind = 'type_changed',
              status = 'T',
              section = 'changes',
            }),
          },
        }))
        A.truthy(ok, err)
        A.equal(err, nil)

        ok, err, blocked = git.can_unstage_all(files({
          staged = {
            file({
              path = 'typed.txt',
              kind = 'type_changed',
              status = 'T',
              section = 'staged',
            }),
          },
        }))
        A.falsy(ok)
        A.equal(err, git.UNSUPPORTED_UNSTAGE_MESSAGE)
        A.equal(blocked.path, 'typed.txt')

        ok, err, blocked = git.can_unstage_all(files({
          conflicts = {
            file({
              path = 'conflict.txt',
              kind = 'conflicted',
              status = 'U',
              section = 'conflicts',
            }),
          },
        }))
        A.falsy(ok)
        A.equal(err, git.UNSUPPORTED_UNSTAGE_MESSAGE)
        A.equal(blocked.path, 'conflict.txt')
      end,
    },
    {
      name = 'commit safety requires staged changes and only blocks unresolved conflicts',
      run = function()
        local git = require('glance.git')
        local ok, err

        ok, err = git.can_commit(files({
          changes = {
            file({
              path = 'tracked.txt',
              kind = 'modified',
              status = 'M',
              section = 'changes',
            }),
          },
        }))
        A.falsy(ok)
        A.equal(err, git.NO_STAGED_COMMIT_MESSAGE)

        ok, err = git.can_commit(files({
          conflicts = {
            file({
              path = 'conflict.txt',
              kind = 'conflicted',
              status = 'U',
              section = 'conflicts',
            }),
          },
          staged = {
            file({
              path = 'copy.txt',
              kind = 'copied',
              status = 'C',
              section = 'staged',
            }),
          },
        }))
        A.falsy(ok)
        A.equal(err, git.CONFLICT_COMMIT_MESSAGE)

        ok, err = git.can_commit(files({
          staged = {
            file({
              path = 'binary.bin',
              kind = 'added',
              status = 'A',
              section = 'staged',
              is_binary = true,
            }),
            file({
              path = 'copy.txt',
              kind = 'copied',
              status = 'C',
              section = 'staged',
            }),
            file({
              path = 'typed.txt',
              kind = 'type_changed',
              status = 'T',
              section = 'staged',
            }),
          },
          changes = {
            file({
              path = 'typed.txt',
              kind = 'type_changed',
              status = 'T',
              section = 'changes',
            }),
          },
          untracked = {
            file({
              path = 'notes.txt',
              kind = 'untracked',
              status = '?',
              section = 'untracked',
            }),
          },
        }))
        A.truthy(ok, err)
        A.equal(err, nil)
      end,
    },
    {
      name = 'commit rejects empty messages before invoking git',
      run = function()
        local git = require('glance.git')

        N.with_repo('repo_staged', function()
          local ok, err = git.commit({
            '',
            '   ',
          }, git.get_changed_files())

          A.falsy(ok)
          A.equal(err, git.EMPTY_COMMIT_MESSAGE)
        end)
      end,
    },
    {
      name = 'integration commit preserves multiline messages and leaves unstaged changes alone',
      run = function()
        local git = require('glance.git')

        N.with_repo('repo_mixed_mm', function(repo)
          local message = {
            'Stage tracked change',
            '',
            'Keep the unstaged tail in the worktree.',
          }

          local ok, err = git.commit(message, git.get_changed_files())
          A.truthy(ok, err)

          A.equal(vim.trim(repo:git({ 'log', '-1', '--pretty=%B' })), table.concat(message, '\n'))
          A.equal(repo:git({ 'show', 'HEAD:' .. repo.files.tracked }), 'alpha\nbeta staged\ngamma\n')
          A.equal(repo:read(repo.files.tracked), 'alpha\nbeta staged\ngamma\nunstaged tail\n')

          local changed = git.get_changed_files()
          A.same(changed.staged, {})
          A.length(changed.changes, 1)
          A.equal(changed.changes[1].path, repo.files.tracked)
        end)
      end,
    },
    {
      name = 'integration commit works in unborn HEAD repositories',
      run = function()
        local git = require('glance.git')

        N.with_repo('repo_unborn_staged_add', function(repo)
          local ok, err = git.commit('Initial commit', git.get_changed_files())
          A.truthy(ok, err)

          A.truthy(vim.trim(repo:git({ 'rev-parse', '--verify', 'HEAD' })) ~= '')
          A.equal(vim.trim(repo:git({ 'log', '-1', '--pretty=%s' })), 'Initial commit')
          A.equal(vim.trim(repo:git({ 'status', '--porcelain=v1', '--untracked-files=all' })), '')
        end)
      end,
    },
    {
      name = 'integration stage and unstage round-trip modified and deleted files',
      run = function()
        local git = require('glance.git')

        N.with_repo('repo_modified', function(repo)
          local changed = git.get_changed_files()
          local ok, err = git.stage_file(changed.changes[1])
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.length(changed.staged, 1)
          A.same(changed.changes, {})
          A.equal(changed.staged[1].path, repo.files.tracked)
          A.equal(changed.staged[1].status, 'M')
          A.equal(changed.staged[1].section, 'staged')

          ok, err = git.unstage_file(changed.staged[1])
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.same(changed.staged, {})
          A.length(changed.changes, 1)
          A.equal(changed.changes[1].path, repo.files.tracked)
          A.equal(changed.changes[1].status, 'M')
          A.equal(changed.changes[1].section, 'changes')
        end)

        N.with_repo('repo_deleted', function(repo)
          local changed = git.get_changed_files()
          local ok, err = git.stage_file(changed.changes[1])
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.length(changed.staged, 1)
          A.same(changed.changes, {})
          A.equal(changed.staged[1].path, repo.files.tracked)
          A.equal(changed.staged[1].status, 'D')
          A.equal(changed.staged[1].section, 'staged')

          ok, err = git.unstage_file(changed.staged[1])
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.same(changed.staged, {})
          A.length(changed.changes, 1)
          A.equal(changed.changes[1].path, repo.files.tracked)
          A.equal(changed.changes[1].status, 'D')
          A.equal(changed.changes[1].section, 'changes')
        end)
      end,
    },
    {
      name = 'integration single-file stage and unstage stay path scoped when multiple files are dirty',
      run = function()
        local git = require('glance.git')

        N.with_repo('repo_no_changes', function(repo)
          repo.files.second = 'second.txt'
          repo:write(repo.files.second, 'second\n')
          repo:stage(repo.files.second)
          repo:commit_all('Add second tracked file')

          repo:write(repo.files.tracked, 'alpha\nbeta changed\ngamma\n')
          repo:write(repo.files.second, 'second changed\n')

          local changed = git.get_changed_files()
          local ok, err = git.stage_file(assert(find_file_in(changed.changes, repo.files.tracked)))
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.truthy(find_file_in(changed.staged, repo.files.tracked))
          A.truthy(find_file_in(changed.changes, repo.files.second))
          A.falsy(find_file_in(changed.staged, repo.files.second))

          ok, err = git.stage_file(assert(find_file_in(changed.changes, repo.files.second)))
          A.truthy(ok, err)

          changed = git.get_changed_files()
          ok, err = git.unstage_file(assert(find_file_in(changed.staged, repo.files.tracked)))
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.truthy(find_file_in(changed.changes, repo.files.tracked))
          A.truthy(find_file_in(changed.staged, repo.files.second))
          A.falsy(find_file_in(changed.staged, repo.files.tracked))
        end)
      end,
    },
    {
      name = 'integration stage and unstage handle adds renames and MM entries',
      run = function()
        local git = require('glance.git')

        N.with_repo('repo_untracked', function(repo)
          local changed = git.get_changed_files()
          local ok, err = git.stage_file(changed.untracked[1])
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.same(changed.untracked, {})
          A.length(changed.staged, 1)
          A.equal(changed.staged[1].path, repo.files.untracked)
          A.equal(changed.staged[1].status, 'A')
        end)

        N.with_repo('repo_staged_add', function(repo)
          local changed = git.get_changed_files()
          local ok, err = git.unstage_file(changed.staged[1])
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.same(changed.staged, {})
          A.length(changed.untracked, 1)
          A.equal(changed.untracked[1].path, repo.files.staged_add)
          A.equal(changed.untracked[1].status, '?')
        end)

        N.with_repo('repo_unstaged_rename', function(repo)
          local changed = git.get_changed_files()
          A.length(changed.changes, 1)
          A.equal(changed.changes[1].status, 'R')
          A.equal(changed.changes[1].old_path, repo.files.renamed_old)
          A.equal(changed.changes[1].path, repo.files.renamed_new)

          local ok, err = git.stage_file(changed.changes[1])
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.same(changed.changes, {})
          A.same(changed.untracked, {})
          A.length(changed.staged, 1)
          A.equal(changed.staged[1].status, 'R')
          A.equal(changed.staged[1].old_path, repo.files.renamed_old)
          A.equal(changed.staged[1].path, repo.files.renamed_new)
        end)

        N.with_repo('repo_rename', function(repo)
          local changed = git.get_changed_files()
          local ok, err = git.unstage_file(changed.staged[1])
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.same(changed.staged, {})
          A.length(changed.changes, 1)
          A.length(changed.untracked, 1)
          A.equal(changed.changes[1].path, repo.files.renamed_old)
          A.equal(changed.changes[1].status, 'D')
          A.equal(changed.untracked[1].path, repo.files.renamed_new)
          A.equal(changed.untracked[1].status, '?')
        end)

        N.with_repo('repo_mixed_mm', function(repo)
          local changed = git.get_changed_files()
          local ok, err = git.stage_file(changed.changes[1])
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.length(changed.staged, 1)
          A.same(changed.changes, {})
          A.equal(changed.staged[1].path, repo.files.tracked)
          A.equal(changed.staged[1].raw_status, 'M ')

          ok, err = git.unstage_file(changed.staged[1])
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.same(changed.staged, {})
          A.length(changed.changes, 1)
          A.equal(changed.changes[1].path, repo.files.tracked)
          A.equal(changed.changes[1].raw_status, ' M')
        end)
      end,
    },
    {
      name = 'integration binary ordinary file stage and unstage remain allowed',
      run = function()
        local git = require('glance.git')

        N.with_repo('repo_binary_modified', function(repo)
          local changed = git.get_changed_files()
          local ok, err = git.stage_file(changed.changes[1])
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.length(changed.staged, 1)
          A.same(changed.changes, {})
          A.equal(changed.staged[1].path, repo.files.binary)
          A.equal(changed.staged[1].status, 'M')
        end)

        N.with_repo('repo_binary_staged_add', function(repo)
          local changed = git.get_changed_files()
          local ok, err = git.unstage_file(changed.staged[1])
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.same(changed.staged, {})
          A.length(changed.untracked, 1)
          A.equal(changed.untracked[1].path, repo.files.binary)
          A.equal(changed.untracked[1].status, '?')
        end)
      end,
    },
    {
      name = 'integration unborn head repos support single-file and repo-wide unstage',
      run = function()
        local git = require('glance.git')

        N.with_repo('repo_unborn_staged_add', function(repo)
          local changed = git.get_changed_files()
          local ok, err = git.unstage_file(changed.staged[1])
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.same(changed.staged, {})
          A.length(changed.untracked, 1)
          A.equal(changed.untracked[1].path, repo.files.staged_add)
          A.equal(changed.untracked[1].status, '?')

          repo:stage(repo.files.staged_add)
          ok, err = git.unstage_all()
          A.truthy(ok, err)

          changed = git.get_changed_files()
          A.same(changed.staged, {})
          A.length(changed.untracked, 1)
          A.equal(changed.untracked[1].path, repo.files.staged_add)
        end)
      end,
    },
    {
      name = 'integration repo-wide stage and unstage handle supported states and block unsupported states',
      run = function()
        local git = require('glance.git')

        N.with_repo('repo_modified', function(repo)
          repo.files.untracked = 'scratch.txt'
          repo:write(repo.files.untracked, 'scratch\n')

          local ok, err = git.stage_all()
          A.truthy(ok, err)

          local changed = git.get_changed_files()
          A.same(changed.changes, {})
          A.same(changed.untracked, {})
          A.length(changed.staged, 2)
          A.truthy(find_file_in(changed.staged, repo.files.tracked))
          A.truthy(find_file_in(changed.staged, repo.files.untracked))
        end)

        N.with_repo('repo_staged', function(repo)
          repo.files.staged_add = 'new-file.txt'
          repo:write(repo.files.staged_add, 'new staged file\n')
          repo:stage(repo.files.staged_add)

          local ok, err = git.unstage_all()
          A.truthy(ok, err)

          local changed = git.get_changed_files()
          A.same(changed.staged, {})
          A.length(changed.changes, 1)
          A.length(changed.untracked, 1)
          A.equal(changed.changes[1].path, repo.files.tracked)
          A.equal(changed.untracked[1].path, repo.files.staged_add)
        end)

        N.with_repo('repo_conflict', function(repo)
          local ok, err = git.stage_all()
          A.falsy(ok)
          A.equal(err, git.UNSUPPORTED_STAGE_MESSAGE)

          ok, err = git.unstage_all()
          A.falsy(ok)
          A.equal(err, git.UNSUPPORTED_UNSTAGE_MESSAGE)
          A.contains(repo:git({ 'status', '--porcelain=v1', '--untracked-files=all' }), 'UU ' .. repo.files.tracked)
        end)

        N.with_repo('repo_type_change', function(repo)
          local ok, err = git.stage_all()
          A.falsy(ok)
          A.equal(err, git.UNSUPPORTED_STAGE_MESSAGE)
          A.contains(repo:git({ 'status', '--porcelain=v1', '--untracked-files=all' }), 'T ' .. repo.files.tracked)
        end)

        N.with_repo('repo_no_changes', function(repo)
          repo:remove(repo.files.tracked)
          repo:symlink('replacement-target', repo.files.tracked)
          repo:stage(repo.files.tracked)

          local ok, err = git.unstage_all()
          A.falsy(ok)
          A.equal(err, git.UNSUPPORTED_UNSTAGE_MESSAGE)
          A.contains(repo:git({ 'status', '--porcelain=v1', '--untracked-files=all' }), 'T  ' .. repo.files.tracked)
        end)
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
      name = 'integration snapshot key changes when HEAD moves without porcelain changing',
      run = function()
        N.with_repo('repo_no_changes', function(repo)
          local git = require('glance.git')

          repo:write(repo.files.tracked, 'alpha\nbeta second\ngamma\n')
          repo:stage(repo.files.tracked)
          repo:commit_all('Second commit')

          repo:write(repo.files.tracked, 'alpha\nbeta third\ngamma\n')
          repo:stage(repo.files.tracked)

          local before = git.get_status_snapshot()
          repo:git({ 'reset', '--soft', 'HEAD^' })
          local after = git.get_status_snapshot()

          A.equal(before.output, after.output)
          A.not_equal(before.head_oid, after.head_oid)
          A.not_equal(before.key, after.key)
        end)
      end,
    },
    {
      name = 'integration snapshot key changes when index content changes without porcelain changing',
      run = function()
        N.with_repo('repo_no_changes', function(repo)
          local git = require('glance.git')

          repo:write(repo.files.tracked, 'alpha\nbeta second\ngamma\n')
          repo:stage(repo.files.tracked)

          local before = git.get_status_snapshot()

          repo:write(repo.files.tracked, 'alpha\nbeta third\ngamma\n')
          repo:stage(repo.files.tracked)

          local after = git.get_status_snapshot()

          A.equal(before.output, after.output)
          A.equal(before.head_oid, after.head_oid)
          A.not_equal(before.index_signature, after.index_signature)
          A.not_equal(before.key, after.key)
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
      name = 'integration handles newline stability and lazily resolves untracked binary state',
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
              x = '?',
              y = '?',
              raw_status = '??',
            }),
          })
          A.truthy(git.ensure_file_binary(changed.untracked[1]))
          A.truthy(changed.untracked[1].is_binary)
          A.falsy(git.entry_is_binary({
            path = repo.files.tracked,
            section = 'changes',
            kind = 'modified',
          }))
        end)
      end,
    },
    {
      name = 'integration lazily resolves binary staged adds and unstaged binary modifications',
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
              x = 'A',
              y = ' ',
              raw_status = 'A ',
            }),
          })
          A.truthy(git.ensure_file_binary(changed.staged[1]))
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
              x = ' ',
              y = 'M',
              raw_status = ' M',
            }),
          })
          A.truthy(git.ensure_file_binary(changed.changes[1]))
        end)
      end,
    },
    {
      name = 'integration get_changed_files avoids eager binary probes',
      run = function()
        N.with_repo('repo_binary_staged_add', function()
          local git = require('glance.git')
          local original = git.entry_is_binary
          local calls = 0

          git.entry_is_binary = function(...)
            calls = calls + 1
            return original(...)
          end

          local ok, err = xpcall(function()
            local changed = git.get_changed_files()
            A.equal(calls, 0)
            A.falsy(changed.staged[1].is_binary)
          end, debug.traceback)

          git.entry_is_binary = original

          if not ok then
            error(err, 0)
          end
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
