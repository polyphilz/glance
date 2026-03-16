<div align="center">

<img src="assets/readme/dist/glance-hero-stars.gif" width="820" alt="Animated glance hero">
<h1>glance</h1>

Glance is a standalone app built on Neovim for reviewing git changes. It owns the Neovim session it starts.

<a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>

</div>

## Dependencies

Required to run Glance:

- macOS or Linux. The launcher and installer currently assume a Unix-like shell environment.
- Neovim on your `PATH` as `nvim`. `0.11+` is the safe target for the current codebase.
- Git on your `PATH` as `git`.
- Bash plus standard Unix utilities used by the launcher/install flow: `readlink`, `ln`, and `mkdir`.

Install notes:

- `./install.sh` creates a symlink at `~/.local/bin/glance`.
- `~/.local/bin` needs to be on your `PATH`.
- The install is symlink-based, so the cloned repo needs to stay in a stable location after installation.

Optional:

- `nvim-treesitter` in Neovim's standard data/runtime path if you want richer syntax highlighting while Glance runs in `--clean` mode.

## Config

Glance loads an optional Lua config file automatically on startup. Search order:

1. `$GLANCE_CONFIG`
2. `$XDG_CONFIG_HOME/glance/config.lua`
3. `~/.config/glance/config.lua`

The config file must `return` a Lua table.

Example:

```lua
return {
  app = {
    hide_statusline = true,
  },
  theme = {
    preset = 'one_light',
  },
  windows = {
    filetree = {
      width = 36,
    },
    diff = {
      relativenumber = false,
    },
  },
  hunk_navigation = {
    next = 'n',
    prev = 'N',
  },
  minimap = {
    width = 2,
  },
}
```

Top-level flat keys like `hide_statusline = true` are not supported. Use the nested schema.

Available config domains:

- `app`
- `theme`
- `windows`
- `keymaps`
- `hunk_navigation`
- `signs`
- `welcome`
- `minimap`
- `watch`

Built-in theme presets:

- `seti_black`
- `one_light`

`theme.preset` selects a built-in palette, and `theme.palette` can override individual colors on top of that preset.

The welcome screen is always part of startup. `welcome` only controls its animation timing, not whether it appears.

In the file tree, `d` discards the selected file and `D` discards all repo changes. Both actions prompt for confirmation before making changes.

## Roadmap

- [x] Add tests
- [x] Hide statusline config option
- [x] Yellow glance logo
- [x] Add a white theme preset
- [x] Get "Discard all changes" and single "Discard changes" functionality working
- [ ] Verify all the code

## License

MIT
