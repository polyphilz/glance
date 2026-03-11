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

The welcome screen is always part of startup. `welcome` only controls its animation timing, not whether it appears.

## Roadmap

- [x] Add tests
- [x] Hide statusline config option
- [x] Yellow glance logo
- [ ] Add a white theme preset
- [ ] When free scrolling on left-hand side pane, right-hand side pane doesn't move, but reverse isn't true
- [ ] Make minimap clickable
- [ ] Verify all the code
