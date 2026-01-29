# ClaudeTasks.spoon

Hammerspoon Spoon for viewing Claude Code tasks in a floating window.

## Demo

![ClaudeTasks spoon](https://github.com/user-attachments/assets/71068e53-ae80-433e-86de-3f158b534c20)

## Features

- Floating task viewer with WebView UI
- Auto-refresh on file changes via pathwatcher
- Session selector with datalist autocomplete
- Quick TaskUpdate via dialog (⌘E)
- Launch Claude session in terminal (▶ button)
- Task status summary hotkey
- **SSH remote server support** - View tasks from remote servers via SSH

## Installation

### Option 1: Clone and Symlink (Recommended for development)

```bash
git clone https://github.com/jongwony/ClaudeTasks.spoon.git
ln -sf $(pwd)/ClaudeTasks.spoon ~/.hammerspoon/Spoons/ClaudeTasks.spoon
```

### Option 2: Direct Download

Download and extract to `~/.hammerspoon/Spoons/ClaudeTasks.spoon/`

## Usage

Add to your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("ClaudeTasks")
spoon.ClaudeTasks:bindHotkeys(spoon.ClaudeTasks.defaultHotkeys)
spoon.ClaudeTasks:start()
```

### Default Hotkeys

| Hotkey | Action |
|--------|--------|
| `opt+.` | Toggle task viewer |
| `cmd+alt+T` | Show task status summary |

### Custom Configuration

```lua
hs.loadSpoon("ClaudeTasks")
spoon.ClaudeTasks:configure({
    width = 500,
    height = 700,
    margin = 30,
    debugMode = true,
    -- Specify paths explicitly if auto-discovery fails
    claudePath = "/usr/local/bin/claude",
    terminalApp = "/Applications/iTerm.app/Contents/MacOS/iTerm2",
    shell = "/bin/bash",
})
spoon.ClaudeTasks:bindHotkeys({
    toggle = {{"cmd", "alt"}, "T"},
    status = {{"cmd", "alt", "shift"}, "T"}
})
spoon.ClaudeTasks:start()
```

## API

### Methods

- `obj:init()` - Initialize the Spoon (called automatically)
- `obj:start()` - Start file watching and load saved state
- `obj:stop()` - Stop file watching and cleanup
- `obj:show()` - Show the task viewer
- `obj:hide()` - Hide the task viewer
- `obj:toggle()` - Toggle visibility
- `obj:refresh()` - Manually refresh the task list
- `obj:setTaskListId(id)` - Set the session ID filter
- `obj:createTask(subject)` - Create a new task via Claude CLI
- `obj:quickTaskUpdate(prompt)` - Run quick TaskUpdate via haiku model
- `obj:launchClaudeWithTaskList()` - Launch Claude in terminal with current session
- `obj:status()` - Get current status info
- `obj:configure(options)` - Update configuration
- `obj:bindHotkeys(mapping)` - Bind hotkeys
- `obj:setActiveServer(serverId)` - Switch to a different server
- `obj:addServer(config)` - Add a new SSH server
- `obj:removeServer(serverId)` - Remove an SSH server
- `obj:testConnection(serverId)` - Test SSH connection to a server

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `width` | 420 | Window width |
| `height` | 580 | Window height |
| `margin` | 20 | Screen edge margin |
| `refreshDebounce` | 0.2 | Debounce delay for file changes (seconds) |
| `debugMode` | false | Enable debug logging |
| `taskListId` | `$CLAUDE_CODE_TASK_LIST_ID` | Session ID filter |
| `claudePath` | nil | Path to claude CLI (auto-discovered if nil) |
| `terminalApp` | nil | Path to terminal app (auto-discovered if nil) |
| `shell` | nil | Shell to use (defaults to `$SHELL` or `/bin/zsh`) |
| `sshPath` | `/usr/bin/ssh` | Path to SSH binary |
| `sshPollingInterval` | 5 | Remote task polling interval (seconds) |
| `sshConnectTimeout` | 10 | SSH connection timeout (seconds) |
| `sshCommandTimeout` | 30 | SSH command timeout (seconds) |
| `enableSSHCompression` | true | Enable SSH compression (-C flag) |

## SSH Remote Servers

You can view tasks from remote servers via SSH. The remote server must have Claude Code tasks in `~/.claude/tasks/`.

### Adding a Remote Server

1. Click the **+** button next to the server dropdown
2. Enter server name, hostname, and SSH username
3. The server will be added to the dropdown

Or use the Lua API:

```lua
spoon.ClaudeTasks:addServer({
    id = "my-server",
    name = "My Dev Server",
    host = "dev.example.com",
    user = "ubuntu",
    port = 22,                    -- optional, default: 22
    identityFile = "~/.ssh/id_rsa", -- optional
    tasksDir = "~/.claude/tasks"  -- optional, default: ~/.claude/tasks
})
```

### Testing Connection

```lua
spoon.ClaudeTasks:testConnection("my-server")
```

### Removing a Server

```lua
spoon.ClaudeTasks:removeServer("my-server")
```

### Notes

- SSH key authentication is required (password prompts are disabled via `BatchMode=yes`)
- Remote servers use polling instead of file watching (default: every 5 seconds)
- Quick TaskUpdate and Launch Claude are disabled for remote servers
- The remote server needs `python3` for best results, falls back to shell commands

## Requirements

- Hammerspoon
- Claude Code CLI (`claude` command)
- A supported terminal app (Ghostty, iTerm2, or Terminal.app)

## License

MIT License - see [LICENSE](LICENSE)
