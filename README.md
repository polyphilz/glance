<div align="center">

<img src="assets/readme/dist/glance-hero-stars.gif" width="640" alt="Animated glance hero">

Glance is a standalone app built on Neovim for reviewing git changes.

<a href="https://www.apple.com/macos/" target="_blank"><img src="https://img.shields.io/badge/macOS-000000?style=flat&logo=apple&logoColor=white" alt="macOS"></a>
<a href="https://www.kernel.org/" target="_blank"><img src="https://img.shields.io/badge/Linux-FCC624?style=flat&logo=linux&logoColor=black" alt="Linux"></a>
<a href="https://neovim.io/" target="_blank"><img src="https://img.shields.io/badge/Neovim-0.11%2B-57A143?style=flat&logo=neovim&logoColor=white" alt="Neovim 0.11+"></a>
<a href="https://www.lua.org/" target="_blank"><img src="https://img.shields.io/badge/Lua-2C2D72?style=flat&logo=lua&logoColor=white" alt="Lua"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>

<br>

<img src="assets/readme/dist/glance-demo.gif" width="720" alt="Animated demo of Glance reviewing git changes">

</div>

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/polyphilz/glance/main/install.sh | bash
```

The bootstrap installer resolves the latest GitHub release by default.

- Pin a release: `curl -fsSL https://raw.githubusercontent.com/polyphilz/glance/main/install.sh | GLANCE_REF=v0.1.0 bash`
- Install unreleased `main`: `curl -fsSL https://raw.githubusercontent.com/polyphilz/glance/main/install.sh | GLANCE_REF=main bash`
- Install from a local checkout: `./install.sh`
- Verify the installed version: `glance --version`

## Dependencies

Required to run Glance:

- macOS or Linux. The launcher and installer currently assume a Unix-like shell environment.
- Neovim on your `PATH` as `nvim`. `0.11+` is the safe target for the current codebase.
- Git on your `PATH` as `git`.
- Bash plus standard Unix utilities used by the launcher/install flow: `readlink`, `ln`, and `mkdir`.
- `curl`, `tar`, and `mktemp` if you use the bootstrap installer.

Install notes:

- The bootstrap installer downloads Glance into `~/.local/share/glance/<ref>` and creates a symlink at `~/.local/bin/glance`.
- `./install.sh` from a local checkout creates a symlink at `~/.local/bin/glance` that points back to that checkout.
- `~/.local/bin` needs to be on your `PATH`.
- Local checkout installs are symlink-based, so the cloned repo needs to stay in a stable location after installation.

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

## Releasing

See [RELEASING.md](RELEASING.md) for the version bump and GitHub release flow.

## License

MIT
