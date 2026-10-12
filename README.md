# Perch

A small native macOS menu bar utility (Swift + SwiftUI, no dependencies) for personal use.

| Feature | Where |
|---|---|
| Keep awake (∞ / 15m / 1h / 2h / 4h / 8h), optional display-on | Menu → Uyanık kal |
| Keep running with the lid closed (`pmset disablesleep`, auto-restored on quit) | Menu → Kapak kapalıyken çalış |
| Claude Code + Codex rate-limit windows | Menu → Limitler |
| Screenshots: auto-copy + stack bottom-left (copy / save / save as / drag / double-click to open) | ⇧⌘4 area (Space = window), ⇧⌘3 full screen (turn off the macOS ones in Keyboard Shortcuts) |
| Safe cleanup: caches, logs, Xcode, dev package caches, installers, Trash | Window → Temizlik |
| Big files & folder sizes (drill-down, trash) | Window → Büyük Dosyalar |
| App uninstaller with leftover finder (pick what to delete) | Window → Uygulama Kaldır |

## Build

```bash
./scripts/build.sh            # → build/Perch.app
./scripts/build.sh --install  # → /Applications/Perch.app and launch
```

`swift scripts/make-icon.swift` regenerates `Resources/AppIcon.icns`.

`open -a Perch --args --tab disk` opens a window directly (`cleanup`, `disk`, `apps`, `settings`).

## Permissions

- **Screen Recording** – for screenshots (asked on first capture).
- **Full Disk Access** – optional; without it the scanners skip protected folders (Photos library, Mail, other apps' containers) instead of triggering a prompt for each.
- **Lid mode** – needs root. Either the admin password each toggle, or Settings → "Şifresiz kullanımı kur" which adds `/etc/sudoers.d/perch` allowing only `pmset -a disablesleep 0|1`.

## Resource use

- Idle: one status item, no timers, no polling (usage is fetched when the menu opens; a 5-min timer only if the menu-bar percentage is enabled).
- Menu and window SwiftUI trees are created on open and released on close, including scan results.
- File scanning uses `fts(3)` at utility priority; the disk tree is materialised only 4 levels deep and expanded on demand.
- Screenshot thumbnails are downsampled; temp files live in `~/Library/Caches/Perch/Shots` and are cleared on launch.

## Usage data sources

- Claude: OAuth token from the `Claude Code-credentials` Keychain item (read via `/usr/bin/security`) → `GET https://api.anthropic.com/api/oauth/usage`.
- Codex: `~/.codex/auth.json` → `GET https://chatgpt.com/backend-api/wham/usage`.

Both are undocumented endpoints and may change. Tokens are never refreshed or written; if one expires, run `claude` / `codex` once.
