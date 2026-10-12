# FlickTab

A searchable window switcher for macOS, built with [Hammerspoon](https://www.hammerspoon.org). Enables Windows-like switching instead of Mac application-level switching.

Hold **Command**, press **Tab** to cycle, and release at the desired window. Windows appear in most-recently-used order.

Typical usage pattern looks like either:

- Switching back and forth between 2 windows
- Search for a window you know is open, but don't know where in the order. i.e. type "obs" for obsidian or "gh" for ghostty.

![FlickTab showing two separate Google Chrome windows](assets/switcher.png)

## Comparison

Many similar tools exist. What makes FlickTab the best:

- **Fast:** Never feel lag
- **Fuzzy search:** Super resillient to typos
- **Uses Hammerspoon:** No separate app. Company managed Macs just need to allow Hammerspoon
- **Simple:** in both design and features
- **Free**

## Install

Clone repo, then run:

```sh
./setup
```

Setup installs Hammerspoon with homebrew if not already installed, copies the Spoon, and adds its startup line.

Allow Hammerspoon in **System Settings → Privacy & Security → Accessibility**, then click **Reload Config** from its menu.

## Controls

| Key                        | Action             |
| -------------------------- | ------------------ |
| Command + Tab              | Open / next window |
| Command + Shift + Tab      | Previous window    |
| Type while holding Command | Search             |
| Release Command / Enter    | Switch             |
| Escape                     | Cancel             |

To uninstall, remove `hs.loadSpoon("FlickTab"):start()` from `~/.hammerspoon/init.lua`, delete `~/.hammerspoon/Spoons/FlickTab.spoon`, then click **Reload Config** in the Hammerspoon menu.
