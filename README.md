# Glance

Glance is a standalone app built on Neovim for reviewing git changes. It owns the Neovim session it starts.

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

## Roadmap

- [x] Add tests
- [x] Hide statusline config option
- [x] Yellow glance logo
- [x] Add a white theme preset
- [ ] Get "Discard all changes" and single "Discard changes" functionality working
- [ ] Verify all the code

