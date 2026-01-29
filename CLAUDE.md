# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ClaudeTasks.spoon is a Hammerspoon Spoon that provides a floating WebView-based task viewer for Claude Code tasks stored in `~/.claude/tasks/`.

## Architecture

Single-file Spoon architecture in `init.lua` (~1800 lines) with these key sections:

1. **Configuration** (lines 19-40): UI dimensions, debounce timing, external tool paths, SSH settings
2. **Discovery** (lines 46-72): Auto-discovers `claude` CLI, terminal app, shell
3. **Server Management**: Manages local and SSH remote servers via `servers.json`
4. **State Management**: Persists session ID and active server to `state.json`
5. **Task Loading**: Reads JSON task files from local or remote (via SSH) directories
6. **SSH Remote Support**: SSH task fetching with polling (pathwatcher doesn't work remotely)
7. **HTML Rendering**: Dark-themed HTML/CSS/JS for WebView with server selector
8. **WebView**: Floating HUD window management
9. **File Watching**: Debounced `hs.pathwatcher` for local, polling for SSH
10. **Public API**: Spoon methods including server management (`addServer`, `removeServer`, etc.)

### JS-Lua Bridge

WebView communicates with Lua via `hs.webview.usercontent`. JavaScript calls `webkit.messageHandlers.hammerspoon.postMessage()` which triggers the `userContentController` callback in Lua.

### Task File Structure

Tasks are stored in `~/.claude/tasks/{sessionId}/*.json`. Each session directory contains individual task JSON files.

## Development Commands

No build/test/lint commands. This is a pure Lua Spoon.

**Testing**: Reload in Hammerspoon console with:
```lua
hs.loadSpoon("ClaudeTasks")
spoon.ClaudeTasks:start()
```

**Debug mode**: Enable logging via `spoon.ClaudeTasks:configure({debugMode = true})`

## Key Conventions

- **State persistence**: Only `currentTaskListId` is persisted (to `state.json`)
- **External tools**: Always auto-discovered, never hardcoded paths
- **Task sorting**: Numeric IDs first, then string IDs alphabetically
- **Debounce pattern**: Timer-based debounce for file watcher events (0.2s default)

## Dependencies

- Hammerspoon (macOS)
- Claude Code CLI (`claude` command)
- Terminal: Ghostty, iTerm2, or Terminal.app
