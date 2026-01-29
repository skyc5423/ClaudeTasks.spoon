-- ClaudeTasks.spoon
-- Hammerspoon Spoon for Claude Code Task viewer
-- opt+. 핫키로 플로팅 윈도우에 태스크 목록 표시

local obj = {}

-- Spoon Metadata
obj.name = "ClaudeTasks"
obj.version = "1.0"
obj.author = "jongwony <lastone9182@gmail.com>"
obj.license = "MIT - https://opensource.org/licenses/MIT"
obj.homepage = "https://github.com/jongwony/ClaudeTasks.spoon"
obj.spoonPath = hs.spoons.scriptPath()

-- ============================================================================
-- 설정
-- ============================================================================

obj.config = {
    -- UI
    width = 420,
    height = 580,
    margin = 20,
    refreshDebounce = 0.2,
    debugMode = false,

    -- Session
    taskListId = os.getenv("CLAUDE_CODE_TASK_LIST_ID"),

    -- External Tools (nil = auto-discover)
    claudePath = nil,
    terminalApp = nil,
    shell = nil,

    -- SSH/Remote settings
    sshPath = "/usr/bin/ssh",
    sshPollingInterval = 5,      -- seconds
    sshConnectTimeout = 10,      -- seconds
    sshCommandTimeout = 30,      -- seconds
    enableSSHCompression = true, -- use -C flag
}

-- ============================================================================
-- Helper Functions for Discovery
-- ============================================================================

local function discoverClaudePath()
    if obj.config.claudePath then return obj.config.claudePath end
    local handle = io.popen("which claude 2>/dev/null")
    if handle then
        local path = handle:read("*l")
        handle:close()
        if path and path ~= "" then return path end
    end
    return nil
end

local function discoverTerminalApp()
    if obj.config.terminalApp then return obj.config.terminalApp end
    local candidates = {
        "/Applications/Ghostty.app/Contents/MacOS/ghostty",
        "/Applications/iTerm.app/Contents/MacOS/iTerm2",
        "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
    }
    for _, path in ipairs(candidates) do
        if hs.fs.attributes(path) then return path end
    end
    return nil
end

local function getShell()
    return obj.config.shell or os.getenv("SHELL") or "/bin/zsh"
end

-- ============================================================================
-- 영속 상태 관리
-- ============================================================================

obj.state = {
    currentTaskListId = nil,
    activeServerId = "local",
    configPath = nil,   -- Set in init()
    serversPath = nil   -- Set in init()
}

-- ============================================================================
-- 내부 상태
-- ============================================================================

local webview = nil
local pathWatcher = nil
local refreshTimer = nil
local isVisible = false
local usercontent = nil  -- JS-Lua 브릿지

-- SSH/Remote state
local pollingTimer = nil
local sshTask = nil
local sshTimeoutTimer = nil
local lastSSHError = nil
local cachedRemoteTasks = {}
local cachedRemoteSessions = {}

-- Forward declarations
local refreshWebView

-- ============================================================================
-- 유틸리티 함수
-- ============================================================================

local function log(message)
    if obj.config.debugMode then
        print("[ClaudeTasks] " .. message)
    end
end

local function getTasksDir()
    return os.getenv("HOME") .. "/.claude/tasks"
end

-- JSON 파싱 (간단한 구현 - 태스크 파일용)
local function parseJSON(str)
    -- hs.json 사용
    local success, result = pcall(hs.json.decode, str)
    if success then
        return result
    end
    return nil
end

-- 디렉토리 내 모든 항목 나열
local function listDir(path)
    local items = {}
    local handle = io.popen('ls -1 "' .. path .. '" 2>/dev/null')
    if handle then
        for line in handle:lines() do
            table.insert(items, line)
        end
        handle:close()
    end
    return items
end

-- 파일이 존재하는지 확인
local function fileExists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

-- 파일 내용 읽기
local function readFile(path)
    local f = io.open(path, "r")
    if f then
        local content = f:read("*all")
        f:close()
        return content
    end
    return nil
end

-- ============================================================================
-- 서버 설정 관리
-- ============================================================================

local function getDefaultServers()
    return {
        servers = {{
            id = "local",
            name = "Local",
            type = "local",
            tasksDir = "~/.claude/tasks"
        }},
        activeServerId = "local"
    }
end

local function loadServers()
    if not obj.state.serversPath then
        return getDefaultServers()
    end
    local f = io.open(obj.state.serversPath, "r")
    if not f then
        return getDefaultServers()
    end
    local content = f:read("*all")
    f:close()
    local data = parseJSON(content)
    if not data or not data.servers then
        return getDefaultServers()
    end
    return data
end

local function saveServers(data)
    if not obj.state.serversPath then return end
    local f = io.open(obj.state.serversPath, "w")
    if f then
        f:write(hs.json.encode(data, true))
        f:close()
        log("Servers saved")
    end
end

local function getServerById(serverId)
    local data = loadServers()
    for _, server in ipairs(data.servers) do
        if server.id == serverId then
            return server
        end
    end
    return nil
end

local function getActiveServer()
    local data = loadServers()
    local serverId = obj.state.activeServerId or data.activeServerId or "local"
    return getServerById(serverId)
end

local function listServers()
    local data = loadServers()
    return data.servers
end

-- ============================================================================
-- 상태 관리 함수
-- ============================================================================

local function loadState()
    local f = io.open(obj.state.configPath, "r")
    if f then
        local content = f:read("*all")
        f:close()
        local data = parseJSON(content)
        if data then
            obj.state.currentTaskListId = data.currentTaskListId
            obj.state.activeServerId = data.activeServerId or "local"
            obj.config.taskListId = data.currentTaskListId
            log("State loaded: taskListId=" .. (data.currentTaskListId or "nil")
                .. ", server=" .. (data.activeServerId or "local"))
        end
    end
end

local function saveState()
    local data = hs.json.encode({
        currentTaskListId = obj.state.currentTaskListId,
        activeServerId = obj.state.activeServerId
    })
    local f = io.open(obj.state.configPath, "w")
    if f then
        f:write(data)
        f:close()
        log("State saved: taskListId=" .. (obj.state.currentTaskListId or "nil")
            .. ", server=" .. (obj.state.activeServerId or "local"))
    end
end

local function listSessionDirs()
    local server = getActiveServer()

    -- SSH 서버인 경우 캐시된 세션 목록 반환
    if server and server.type == "ssh" then
        return cachedRemoteSessions
    end

    -- 로컬 서버
    local tasksDir = getTasksDir()
    if not fileExists(tasksDir) then
        return {}
    end

    local allDirs = listDir(tasksDir)
    local nonEmptySessions = {}

    for _, sessionId in ipairs(allDirs) do
        local sessionDir = tasksDir .. "/" .. sessionId
        local files = listDir(sessionDir)
        -- .json 파일이 하나라도 있으면 포함
        for _, filename in ipairs(files) do
            if filename:match("%.json$") then
                table.insert(nonEmptySessions, sessionId)
                break
            end
        end
    end

    return nonEmptySessions
end

-- ============================================================================
-- 태스크 로딩
-- ============================================================================

local function loadAllTasks()
    local server = getActiveServer()

    -- SSH 서버인 경우 캐시된 태스크 반환
    if server and server.type == "ssh" then
        log("Returning " .. #cachedRemoteTasks .. " cached remote tasks")
        return cachedRemoteTasks
    end

    -- 로컬 서버
    local tasks = {}
    local tasksDir = getTasksDir()

    if not fileExists(tasksDir) then
        log("Tasks directory does not exist: " .. tasksDir)
        return tasks
    end

    -- 특정 세션 ID가 설정되어 있으면 해당 세션만 로드
    local sessions = {}
    if obj.config.taskListId then
        sessions = {obj.config.taskListId}
    else
        sessions = listDir(tasksDir)
    end

    for _, sessionId in ipairs(sessions) do
        local sessionDir = tasksDir .. "/" .. sessionId
        local files = listDir(sessionDir)

        for _, filename in ipairs(files) do
            if filename:match("%.json$") then
                local filepath = sessionDir .. "/" .. filename
                local content = readFile(filepath)

                if content then
                    local task = parseJSON(content)
                    if task then
                        task._sessionId = sessionId
                        task._filepath = filepath
                        table.insert(tasks, task)
                    end
                end
            end
        end
    end

    -- ID로 정렬 (숫자 우선, 문자열 후순)
    table.sort(tasks, function(a, b)
        local aNum = tonumber(a.id)
        local bNum = tonumber(b.id)
        if aNum and bNum then
            return aNum < bNum
        end
        return tostring(a.id) < tostring(b.id)
    end)

    log("Loaded " .. #tasks .. " tasks")
    return tasks
end

-- ============================================================================
-- HTML 렌더링
-- ============================================================================

local function escapeHtml(str)
    if not str then return "" end
    return str:gsub("&", "&amp;")
              :gsub("<", "&lt;")
              :gsub(">", "&gt;")
              :gsub('"', "&quot;")
              :gsub("'", "&#39;")
end

local function getStatusColor(status)
    if status == "completed" then
        return "#22c55e"  -- green
    elseif status == "in_progress" then
        return "#f59e0b"  -- amber
    else
        return "#6b7280"  -- gray (pending)
    end
end

local function getStatusIcon(status)
    if status == "completed" then
        return "✓"
    elseif status == "in_progress" then
        return "◐"
    else
        return "○"
    end
end

local function generateHTML(tasks)
    local pendingTasks = {}
    local inProgressTasks = {}
    local completedTasks = {}

    for _, task in ipairs(tasks) do
        if task.status == "completed" then
            table.insert(completedTasks, task)
        elseif task.status == "in_progress" then
            table.insert(inProgressTasks, task)
        else
            table.insert(pendingTasks, task)
        end
    end

    -- 세션 datalist 옵션 생성
    local sessions = listSessionDirs()
    local sessionOptions = ''
    for _, sessionId in ipairs(sessions) do
        sessionOptions = sessionOptions .. string.format(
            '                    <option value="%s"></option>\n',
            escapeHtml(sessionId)
        )
    end
    local currentSessionValue = obj.state.currentTaskListId or ''

    -- 서버 옵션 생성
    local servers = listServers()
    local activeServer = getActiveServer()
    local serverOptions = ''
    for _, server in ipairs(servers) do
        local selected = (activeServer and server.id == activeServer.id) and ' selected' or ''
        local indicator = server.type == "ssh" and "🌐 " or "💻 "
        serverOptions = serverOptions .. string.format(
            '<option value="%s"%s>%s%s</option>',
            escapeHtml(server.id),
            selected,
            indicator,
            escapeHtml(server.name)
        )
    end
    local isRemoteServer = activeServer and activeServer.type == "ssh"
    local remoteDisabled = isRemoteServer and ' disabled title="Not available for remote servers"' or ''

    local html = [[
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
            font-size: 13px;
            line-height: 1.4;
            background: rgba(30, 30, 30, 0.95);
            color: #e5e5e5;
            padding: 16px;
            overflow-y: auto;
            -webkit-font-smoothing: antialiased;
        }
        .header {
            margin-bottom: 12px;
            padding-bottom: 12px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.1);
        }
        .header-row {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 10px;
        }
        .title {
            font-size: 15px;
            font-weight: 600;
            color: #fff;
        }
        .header-actions {
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .launch-btn {
            background: #22c55e;
            color: #fff;
            border: none;
            padding: 4px 10px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 12px;
            font-weight: 500;
        }
        .launch-btn:hover {
            background: #16a34a;
        }
        .launch-btn:disabled {
            background: #4b5563;
            cursor: not-allowed;
        }
        .quick-update-btn {
            background: #f59e0b;
        }
        .quick-update-btn:hover:not(:disabled) {
            background: #d97706;
        }
        .count {
            font-size: 12px;
            color: #888;
        }
        .session-input {
            background: rgba(255, 255, 255, 0.1);
            border: 1px solid rgba(255, 255, 255, 0.2);
            color: #e5e5e5;
            padding: 6px 10px;
            border-radius: 4px;
            font-size: 12px;
            width: 100%;
        }
        .session-input:focus {
            outline: none;
            border-color: #3b82f6;
        }
        .session-input::placeholder {
            color: #666;
        }
        /* TaskCreate 폼 */
        .create-form {
            background: rgba(255, 255, 255, 0.05);
            border-radius: 8px;
            padding: 12px;
            margin-bottom: 16px;
        }
        .create-form.collapsed .form-fields {
            display: none;
        }
        .form-toggle {
            display: flex;
            justify-content: space-between;
            align-items: center;
            cursor: pointer;
            user-select: none;
        }
        .form-toggle-label {
            font-size: 12px;
            font-weight: 500;
            color: #888;
        }
        .form-toggle-icon {
            color: #888;
            transition: transform 0.2s;
        }
        .create-form:not(.collapsed) .form-toggle-icon {
            transform: rotate(180deg);
        }
        .form-fields {
            margin-top: 10px;
        }
        .form-group {
            margin-bottom: 10px;
        }
        .form-label {
            display: block;
            font-size: 11px;
            color: #888;
            margin-bottom: 4px;
        }
        .form-input {
            width: 100%;
            background: rgba(0, 0, 0, 0.3);
            border: 1px solid rgba(255, 255, 255, 0.1);
            color: #e5e5e5;
            padding: 8px 10px;
            border-radius: 4px;
            font-size: 13px;
        }
        .form-input:focus {
            outline: none;
            border-color: #3b82f6;
        }
        .form-textarea {
            min-height: 60px;
            resize: vertical;
        }
        .form-actions {
            display: flex;
            justify-content: flex-end;
            gap: 8px;
        }
        .btn {
            padding: 6px 14px;
            border-radius: 4px;
            font-size: 12px;
            font-weight: 500;
            cursor: pointer;
            border: none;
        }
        .btn-primary {
            background: #3b82f6;
            color: #fff;
        }
        .btn-primary:hover {
            background: #2563eb;
        }
        .btn-primary:disabled {
            background: #4b5563;
            cursor: not-allowed;
        }
        .spinner {
            display: inline-block;
            width: 12px;
            height: 12px;
            border: 2px solid rgba(255, 255, 255, 0.3);
            border-top-color: #fff;
            border-radius: 50%;
            animation: spin 0.8s linear infinite;
            margin-right: 6px;
        }
        @keyframes spin {
            to { transform: rotate(360deg); }
        }
        .section {
            margin-bottom: 16px;
        }
        .section-header {
            font-size: 11px;
            font-weight: 600;
            color: #888;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 8px;
        }
        .task {
            background: rgba(255, 255, 255, 0.05);
            border-radius: 8px;
            padding: 10px 12px;
            margin-bottom: 6px;
            display: flex;
            align-items: flex-start;
            gap: 10px;
        }
        .task:hover {
            background: rgba(255, 255, 255, 0.08);
        }
        .task-icon {
            font-size: 14px;
            margin-top: 1px;
            flex-shrink: 0;
        }
        .task-content {
            flex: 1;
            min-width: 0;
        }
        .task-subject {
            font-weight: 500;
            color: #fff;
            word-wrap: break-word;
        }
        .task-meta {
            font-size: 11px;
            color: #666;
            margin-top: 4px;
        }
        .task-blocked {
            font-size: 11px;
            color: #ef4444;
            margin-top: 4px;
        }
        .empty {
            color: #555;
            font-style: italic;
            padding: 20px;
            text-align: center;
        }
        .status-pending { color: #6b7280; }
        .status-in_progress { color: #f59e0b; }
        .status-completed { color: #22c55e; }
        .session-badge {
            font-size: 10px;
            background: rgba(255, 255, 255, 0.1);
            padding: 2px 6px;
            border-radius: 4px;
            color: #888;
        }
        /* Server selector */
        .server-row {
            display: flex;
            gap: 6px;
            margin-bottom: 10px;
        }
        .server-select {
            flex: 1;
            background: rgba(255, 255, 255, 0.1);
            border: 1px solid rgba(255, 255, 255, 0.2);
            color: #e5e5e5;
            padding: 6px 10px;
            border-radius: 4px;
            font-size: 12px;
            cursor: pointer;
        }
        .server-select:focus {
            outline: none;
            border-color: #3b82f6;
        }
        .server-select option {
            background: #1e1e1e;
            color: #e5e5e5;
        }
        .icon-btn {
            background: rgba(255, 255, 255, 0.1);
            border: 1px solid rgba(255, 255, 255, 0.2);
            color: #888;
            padding: 4px 10px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 14px;
        }
        .icon-btn:hover {
            background: rgba(255, 255, 255, 0.15);
            color: #fff;
        }
        .connection-error {
            background: rgba(239, 68, 68, 0.2);
            border: 1px solid rgba(239, 68, 68, 0.5);
            color: #fca5a5;
            padding: 8px 12px;
            border-radius: 6px;
            font-size: 12px;
            margin-bottom: 12px;
            display: none;
        }
        .connection-error.visible {
            display: block;
        }
    </style>
    <script>
        let isCreating = false;
        let formCollapsed = true;

        function toggleForm() {
            formCollapsed = !formCollapsed;
            const form = document.querySelector('.create-form');
            form.classList.toggle('collapsed', formCollapsed);
            if (!formCollapsed) {
                document.getElementById('taskSubject').focus();
            }
        }

        function setSession(value) {
            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'setSession',
                value: value.trim()
            });
        }

        function onSessionInputChange(input) {
            // Enter 키 또는 blur 시 세션 변경
            setSession(input.value);
        }

        function createTask() {
            if (isCreating) return;

            const subject = document.getElementById('taskSubject').value.trim();

            if (!subject) {
                document.getElementById('taskSubject').focus();
                return;
            }

            isCreating = true;
            const btn = document.getElementById('createBtn');
            btn.disabled = true;
            btn.innerHTML = '<span class="spinner"></span>Creating...';

            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'createTask',
                subject: subject
            });
        }

        function resetForm() {
            isCreating = false;
            const btn = document.getElementById('createBtn');
            btn.disabled = false;
            btn.innerHTML = 'Create';
            document.getElementById('taskSubject').value = '';
        }

        function launchClaude() {
            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'launchClaude'
            });
        }

        function showQuickUpdateDialog() {
            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'showQuickUpdateDialog'
            });
        }

        // Server management
        function onServerChange(serverId) {
            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'setServer',
                serverId: serverId
            });
        }

        function showAddServerDialog() {
            window.webkit.messageHandlers.taskBridge.postMessage({
                action: 'showAddServerDialog'
            });
        }

        function removeCurrentServer() {
            var select = document.getElementById('serverSelect');
            var serverId = select.value;
            if (serverId === 'local') {
                alert('Cannot remove local server');
                return;
            }
            if (confirm('Remove server "' + select.options[select.selectedIndex].text + '"?')) {
                window.webkit.messageHandlers.taskBridge.postMessage({
                    action: 'removeServer',
                    serverId: serverId
                });
            }
        }

        function showConnectionError(message) {
            var errorDiv = document.getElementById('connectionError');
            if (errorDiv) {
                errorDiv.textContent = '⚠ ' + message;
                errorDiv.classList.add('visible');
            }
        }

        function hideConnectionError() {
            var errorDiv = document.getElementById('connectionError');
            if (errorDiv) {
                errorDiv.classList.remove('visible');
            }
        }

        // 키보드 단축키
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
                createTask();
            }
            if (e.key === 'e' && e.metaKey) {
                e.preventDefault();
                var btn = document.getElementById('quickUpdateBtn');
                if (btn && !btn.disabled) {
                    showQuickUpdateDialog();
                } else {
                    document.getElementById('sessionInput').focus();
                }
            }
            if (e.key === 'Escape') {
                if (!formCollapsed) toggleForm();
            }
        });
    </script>
</head>
<body>
    <div class="header">
        <div class="header-row">
            <span class="title">Claude Tasks</span>
            <div class="header-actions">
                <button id="quickUpdateBtn" class="launch-btn quick-update-btn" onclick="showQuickUpdateDialog()" title="Quick Task ⌘E"]] .. ((currentSessionValue == '' or isRemoteServer) and ' disabled' or '') .. [[>⚡</button>
                <button id="launchBtn" class="launch-btn" onclick="launchClaude()" title="Launch Claude session"]] .. ((currentSessionValue == '' or isRemoteServer) and ' disabled' or '') .. [[>▶</button>
                <span class="count">]] .. #tasks .. [[ tasks</span>
            </div>
        </div>
        <div class="server-row">
            <select class="server-select" id="serverSelect" onchange="onServerChange(this.value)">
                ]] .. serverOptions .. [[
            </select>
            <button class="icon-btn" onclick="showAddServerDialog()" title="Add SSH Server">+</button>
            <button class="icon-btn" onclick="removeCurrentServer()" title="Remove Current Server">−</button>
        </div>
        <div id="connectionError" class="connection-error"></div>
        <input type="text" class="session-input" id="sessionInput" list="sessionList"
               value="]] .. escapeHtml(currentSessionValue) .. [["
               placeholder="Enter or select session..."
               onchange="onSessionInputChange(this)"
               onkeydown="if(event.key==='Enter'){onSessionInputChange(this);event.preventDefault();}">
        <datalist id="sessionList">
            ]] .. sessionOptions .. [[
        </datalist>
    </div>
]]

    -- In Progress 섹션
    if #inProgressTasks > 0 then
        html = html .. [[
    <div class="section">
        <div class="section-header">In Progress (]] .. #inProgressTasks .. [[)</div>
]]
        for _, task in ipairs(inProgressTasks) do
            local blocked = ""
            if task.blockedBy and #task.blockedBy > 0 then
                blocked = '<div class="task-blocked">Blocked by: ' .. table.concat(task.blockedBy, ", ") .. '</div>'
            end
            html = html .. [[
        <div class="task">
            <span class="task-icon status-in_progress">]] .. getStatusIcon("in_progress") .. [[</span>
            <div class="task-content">
                <div class="task-subject">]] .. escapeHtml(task.subject) .. [[</div>
                <div class="task-meta">
                    <span class="session-badge">]] .. escapeHtml(task._sessionId:sub(1, 7)) .. [[</span>
                    #]] .. escapeHtml(tostring(task.id)) .. [[
                </div>
                ]] .. blocked .. [[
            </div>
        </div>
]]
        end
        html = html .. "    </div>\n"
    end

    -- Pending 섹션
    if #pendingTasks > 0 then
        html = html .. [[
    <div class="section">
        <div class="section-header">Pending (]] .. #pendingTasks .. [[)</div>
]]
        for _, task in ipairs(pendingTasks) do
            local blocked = ""
            if task.blockedBy and #task.blockedBy > 0 then
                blocked = '<div class="task-blocked">Blocked by: ' .. table.concat(task.blockedBy, ", ") .. '</div>'
            end
            html = html .. [[
        <div class="task">
            <span class="task-icon status-pending">]] .. getStatusIcon("pending") .. [[</span>
            <div class="task-content">
                <div class="task-subject">]] .. escapeHtml(task.subject) .. [[</div>
                <div class="task-meta">
                    <span class="session-badge">]] .. escapeHtml(task._sessionId:sub(1, 7)) .. [[</span>
                    #]] .. escapeHtml(tostring(task.id)) .. [[
                </div>
                ]] .. blocked .. [[
            </div>
        </div>
]]
        end
        html = html .. "    </div>\n"
    end

    -- Completed 섹션 (최대 5개만 표시)
    if #completedTasks > 0 then
        local displayCount = math.min(5, #completedTasks)
        html = html .. [[
    <div class="section">
        <div class="section-header">Completed (]] .. #completedTasks .. [[)</div>
]]
        for i = 1, displayCount do
            local task = completedTasks[i]
            html = html .. [[
        <div class="task" style="opacity: 0.6;">
            <span class="task-icon status-completed">]] .. getStatusIcon("completed") .. [[</span>
            <div class="task-content">
                <div class="task-subject">]] .. escapeHtml(task.subject) .. [[</div>
                <div class="task-meta">
                    <span class="session-badge">]] .. escapeHtml(task._sessionId:sub(1, 7)) .. [[</span>
                    #]] .. escapeHtml(tostring(task.id)) .. [[
                </div>
            </div>
        </div>
]]
        end
        if #completedTasks > displayCount then
            html = html .. [[
        <div class="task-meta" style="text-align: center; padding: 8px; color: #555;">
            + ]] .. (#completedTasks - displayCount) .. [[ more completed
        </div>
]]
        end
        html = html .. "    </div>\n"
    end

    -- 태스크가 없는 경우
    if #tasks == 0 then
        html = html .. [[
    <div class="empty">
        No tasks found.<br>
        Use TaskCreate in Claude Code to add tasks.
    </div>
]]
    end

    html = html .. [[
</body>
</html>
]]
    return html
end

-- ============================================================================
-- SSH 원격 태스크 로딩
-- ============================================================================

local function buildSSHArgs(server, remoteCommand)
    local args = {}

    -- Connection options
    table.insert(args, "-o")
    table.insert(args, "ConnectTimeout=" .. (server.connectTimeout or obj.config.sshConnectTimeout))
    table.insert(args, "-o")
    table.insert(args, "BatchMode=yes")
    table.insert(args, "-o")
    table.insert(args, "StrictHostKeyChecking=accept-new")

    -- Compression
    if obj.config.enableSSHCompression then
        table.insert(args, "-C")
    end

    -- Port
    if server.port and server.port ~= 22 then
        table.insert(args, "-p")
        table.insert(args, tostring(server.port))
    end

    -- Identity file
    if server.identityFile then
        table.insert(args, "-i")
        table.insert(args, server.identityFile:gsub("^~", os.getenv("HOME")))
    end

    -- Host
    local hostSpec = server.host
    if server.user then
        hostSpec = server.user .. "@" .. server.host
    end
    table.insert(args, hostSpec)

    -- Remote command
    table.insert(args, remoteCommand)

    return args
end

local function buildRemoteFetchCommand(server, sessionId)
    local tasksDir = (server.tasksDir or "~/.claude/tasks"):gsub("^~", "$HOME")
    local sessionFilter = sessionId or ""

    -- Shell script using awk instead of sed to avoid delimiter issues
    local script = string.format([[
TASKS_DIR=$(eval echo %s)
SESSION_FILTER="%s"
if [ ! -d "$TASKS_DIR" ]; then
  echo '{"sessions":[],"tasks":[]}'
  exit 0
fi
cd "$TASKS_DIR" || exit 1
sessions=$(find . -maxdepth 2 -name "*.json" -type f 2>/dev/null | cut -d/ -f2 | sort -u)
echo -n '{"sessions":['
first=1
for s in $sessions; do
  [ $first -eq 0 ] && echo -n ','
  echo -n "\"$s\""
  first=0
done
echo -n '],"tasks":['
first=1
for s in $sessions; do
  [ -n "$SESSION_FILTER" ] && [ "$s" != "$SESSION_FILTER" ] && continue
  for f in "$s"/*.json; do
    [ -f "$f" ] || continue
    [ $first -eq 0 ] && echo -n ','
    awk -v sid="$s" -v fpath="$f" 'BEGIN{ORS=""} {print} END{print ""}' "$f" | awk -v sid="$s" -v fpath="$f" '{sub(/}$/,",\"_sessionId\":\""sid"\",\"_filepath\":\""fpath"\"}"); print}'
    first=0
  done
done
echo ']}'
]], tasksDir, sessionFilter)

    return script
end

local function loadRemoteTasks(callback)
    local server = getActiveServer()
    if not server or server.type ~= "ssh" then
        callback(nil, "Not an SSH server")
        return
    end

    -- Cancel existing SSH task
    if sshTask and sshTask:isRunning() then
        sshTask:terminate()
    end

    local remoteCmd = buildRemoteFetchCommand(server, obj.config.taskListId)
    local args = buildSSHArgs(server, remoteCmd)

    log("SSH fetch from " .. server.name .. ": " .. server.host)

    sshTask = hs.task.new(obj.config.sshPath, function(exitCode, stdout, stderr)
        sshTask = nil

        -- Cancel timeout timer
        if sshTimeoutTimer then
            sshTimeoutTimer:stop()
            sshTimeoutTimer = nil
        end

        -- Always log SSH results for debugging
        print("[ClaudeTasks] SSH exitCode: " .. tostring(exitCode))
        if stderr and stderr ~= "" then
            print("[ClaudeTasks] SSH stderr: " .. stderr:sub(1, 500))
        end
        if stdout then
            print("[ClaudeTasks] SSH stdout length: " .. #stdout)
            if #stdout < 1000 then
                print("[ClaudeTasks] SSH stdout: " .. stdout)
            else
                print("[ClaudeTasks] SSH stdout (truncated): " .. stdout:sub(1, 500) .. "...")
            end
        end

        -- exitCode 15 = SIGTERM (normal termination by polling timer)
        if exitCode ~= 0 and exitCode ~= 15 then
            lastSSHError = stderr or "SSH connection failed (exit " .. exitCode .. ")"
            print("[ClaudeTasks] SSH error: " .. lastSSHError)
            callback(nil, lastSSHError)
            return
        end

        -- SIGTERM - ignore, just return without updating
        if exitCode == 15 then
            print("[ClaudeTasks] SSH terminated by polling timer (normal)")
            return
        end

        lastSSHError = nil
        local data = parseJSON(stdout)
        if not data then
            lastSSHError = "Failed to parse remote response"
            print("[ClaudeTasks] Parse error, raw stdout: " .. (stdout or "empty"):sub(1, 500))
            callback(nil, lastSSHError)
            return
        end

        -- Sort tasks
        if data.tasks then
            table.sort(data.tasks, function(a, b)
                local aNum = tonumber(a.id)
                local bNum = tonumber(b.id)
                if aNum and bNum then return aNum < bNum end
                return tostring(a.id) < tostring(b.id)
            end)
        end

        -- Cache results
        cachedRemoteTasks = data.tasks or {}
        cachedRemoteSessions = data.sessions or {}

        print("[ClaudeTasks] SSH loaded " .. #cachedRemoteTasks .. " tasks, " .. #cachedRemoteSessions .. " sessions")
        callback(data, nil)
    end, args)

    -- Timeout handler
    if sshTimeoutTimer then
        sshTimeoutTimer:stop()
    end
    sshTimeoutTimer = hs.timer.doAfter(obj.config.sshCommandTimeout, function()
        if sshTask and sshTask:isRunning() then
            sshTask:terminate()
            sshTask = nil
            lastSSHError = "SSH command timed out"
            callback(nil, lastSSHError)
        end
        sshTimeoutTimer = nil
    end)

    sshTask:start()
end

local function stopPolling()
    if pollingTimer then
        pollingTimer:stop()
        pollingTimer = nil
        log("Polling stopped")
    end
    if sshTimeoutTimer then
        sshTimeoutTimer:stop()
        sshTimeoutTimer = nil
    end
    if sshTask and sshTask:isRunning() then
        sshTask:terminate()
        sshTask = nil
    end
end

local function startPolling()
    local server = getActiveServer()
    if not server or server.type ~= "ssh" then
        return
    end

    stopPolling()

    local function pollFunc()
        loadRemoteTasks(function(data, err)
            if data then
                if isVisible and webview then
                    refreshWebView()
                end
            elseif err and isVisible and webview then
                local safeErr = (err or "Unknown error"):gsub("['\"\\]", ""):gsub("\n", " "):gsub("\r", ""):sub(1, 200)
                webview:evaluateJavaScript(
                    "if(typeof showConnectionError==='function')showConnectionError('" .. safeErr .. "')"
                )
            end
        end)
    end

    -- Initial fetch
    pollFunc()

    -- Recurring polls
    pollingTimer = hs.timer.doEvery(obj.config.sshPollingInterval, pollFunc)
    log("Polling started (interval: " .. obj.config.sshPollingInterval .. "s)")
end

-- ============================================================================
-- WebView 관리
-- ============================================================================

local function createUserContent()
    if usercontent then
        return usercontent
    end

    usercontent = hs.webview.usercontent.new("taskBridge")
    usercontent:setCallback(function(msg)
        log("Bridge message: " .. hs.json.encode(msg.body))

        if msg.body.action == "setSession" then
            obj:setTaskListId(msg.body.value)
        elseif msg.body.action == "createTask" then
            obj:createTask(msg.body.subject)
        elseif msg.body.action == "launchClaude" then
            obj:launchClaudeWithTaskList()
        elseif msg.body.action == "showQuickUpdateDialog" then
            local button, text = hs.dialog.textPrompt("Quick Task", "Enter prompt (e.g., 'TaskCreate: Fix bug' or 'TaskUpdate: #3 done'):", "", "OK", "Cancel")
            if button == "OK" and text and text ~= "" then
                obj:quickTaskUpdate(text)
            end
        elseif msg.body.action == "setServer" then
            obj:setActiveServer(msg.body.serverId)
        elseif msg.body.action == "showAddServerDialog" then
            -- Multi-step dialog for adding SSH server
            local button, name = hs.dialog.textPrompt("Add SSH Server", "Enter server name (display name):", "", "Next", "Cancel")
            if button ~= "Next" or not name or name == "" then return end

            local button2, host = hs.dialog.textPrompt("Add SSH Server", "Enter hostname (e.g., dev.example.com):", "", "Next", "Cancel")
            if button2 ~= "Next" or not host or host == "" then return end

            local button3, port = hs.dialog.textPrompt("Add SSH Server", "Enter SSH port:", "22", "Next", "Cancel")
            if button3 ~= "Next" then return end

            local button4, user = hs.dialog.textPrompt("Add SSH Server", "Enter SSH username:", os.getenv("USER") or "", "Add", "Cancel")
            if button4 ~= "Add" then return end

            obj:addServer({
                id = name:lower():gsub("%s+", "-"):gsub("[^%w%-]", ""),
                name = name,
                host = host,
                port = tonumber(port) or 22,
                user = (user ~= "") and user or nil,
                type = "ssh"
            })
        elseif msg.body.action == "removeServer" then
            obj:removeServer(msg.body.serverId)
        end
    end)

    log("UserContent bridge created")
    return usercontent
end

local function createWebView()
    if webview then
        return webview
    end

    -- JS-Lua 브릿지 생성
    createUserContent()

    -- 화면 크기 가져오기
    local screen = hs.screen.mainScreen()
    local frame = screen:frame()

    -- 오른쪽 하단에 위치
    local rect = hs.geometry.rect(
        frame.x + frame.w - obj.config.width - obj.config.margin,
        frame.y + frame.h - obj.config.height - obj.config.margin,
        obj.config.width,
        obj.config.height
    )

    webview = hs.webview.new(rect, {}, usercontent)
    webview:windowStyle({"titled", "closable", "utility", "HUD"})
    webview:level(hs.drawing.windowLevels.floating)
    webview:allowTextEntry(true)  -- 폼 입력 허용
    webview:allowGestures(false)
    webview:shadow(true)
    webview:alpha(0.98)
    webview:windowTitle("Claude Tasks")

    -- 창 닫힐 때 상태 업데이트
    webview:deleteOnClose(false)

    log("WebView created with usercontent bridge")
    return webview
end

refreshWebView = function()
    if not webview then return end

    local tasks = loadAllTasks()
    local html = generateHTML(tasks)
    webview:html(html)

    -- SSH 에러 표시/숨김
    local server = getActiveServer()
    if server and server.type == "ssh" then
        if lastSSHError then
            local safeErr = (lastSSHError or "Unknown error"):gsub("['\"\\]", ""):gsub("\n", " "):gsub("\r", ""):sub(1, 200)
            webview:evaluateJavaScript(
                "if(typeof showConnectionError==='function')showConnectionError('" .. safeErr .. "')"
            )
        else
            webview:evaluateJavaScript(
                "if(typeof hideConnectionError==='function')hideConnectionError()"
            )
        end
    end

    log("WebView refreshed with " .. #tasks .. " tasks")
end

-- ============================================================================
-- 파일 감시
-- ============================================================================

local function startPathWatcher()
    if pathWatcher then return end

    local tasksDir = getTasksDir()

    -- 디렉토리가 없으면 생성 대기
    if not fileExists(tasksDir) then
        log("Tasks directory does not exist, will watch parent")
        -- .claude 디렉토리 감시
        local parentDir = os.getenv("HOME") .. "/.claude"
        pathWatcher = hs.pathwatcher.new(parentDir, function(paths)
            -- tasks 디렉토리가 생성되면 재시작
            if fileExists(tasksDir) then
                obj:stop()
                obj:start()
            end
        end)
        pathWatcher:start()
        return
    end

    -- 모든 세션 디렉토리 감시
    local sessions = listDir(tasksDir)
    local watchPaths = {tasksDir}

    for _, sessionId in ipairs(sessions) do
        table.insert(watchPaths, tasksDir .. "/" .. sessionId)
    end

    pathWatcher = hs.pathwatcher.new(tasksDir, function(paths)
        log("File change detected: " .. table.concat(paths, ", "))

        -- 디바운스: 빠른 연속 변경 시 마지막 것만 처리
        if refreshTimer then
            refreshTimer:stop()
        end

        refreshTimer = hs.timer.doAfter(obj.config.refreshDebounce, function()
            refreshWebView()
            refreshTimer = nil
        end)
    end)

    pathWatcher:start()
    log("PathWatcher started on: " .. tasksDir)
end

local function stopPathWatcher()
    if pathWatcher then
        pathWatcher:stop()
        pathWatcher = nil
        log("PathWatcher stopped")
    end
    if refreshTimer then
        refreshTimer:stop()
        refreshTimer = nil
    end
end

-- ============================================================================
-- 공개 API
-- ============================================================================

--- Initialize the Spoon
function obj:init()
    obj.state.configPath = obj.spoonPath .. "/state.json"
    obj.state.serversPath = obj.spoonPath .. "/servers.json"
    log("ClaudeTasks Spoon initialized")
    return self
end

--- 태스크 뷰어 표시
function obj:show()
    if not webview then
        createWebView()
    end
    refreshWebView()
    webview:show()
    isVisible = true

    -- 서버 타입에 따라 감시 방식 선택
    local server = getActiveServer()
    if server and server.type == "ssh" then
        startPolling()
    else
        startPathWatcher()
    end

    log("Task viewer shown")
    return self
end

--- 태스크 뷰어 숨기기
function obj:hide()
    if webview then
        webview:hide()
        isVisible = false
        log("Task viewer hidden")
    end
    return self
end

--- 표시/숨기기 토글
function obj:toggle()
    if isVisible then
        obj:hide()
    else
        obj:show()
    end
    return self
end

--- 수동 새로고침
function obj:refresh()
    refreshWebView()
    return self
end

--- 세션 ID 설정
function obj:setTaskListId(id)
    local sessionId = (id ~= "" and id) or nil
    obj.state.currentTaskListId = sessionId
    obj.config.taskListId = sessionId
    saveState()
    log("Session changed to: " .. (sessionId or "none"))

    -- 서버 타입에 따라 감시 재시작
    local server = getActiveServer()
    if server and server.type == "ssh" then
        stopPolling()
        startPolling()
    else
        stopPathWatcher()
        startPathWatcher()
    end

    -- UI 새로고침
    obj:refresh()
    return self
end

--- 활성 서버 설정
function obj:setActiveServer(serverId)
    local server = getServerById(serverId)
    if not server then
        hs.alert.show("Server not found: " .. serverId, 2)
        return self
    end

    -- 상태 업데이트
    local data = loadServers()
    data.activeServerId = serverId
    saveServers(data)
    obj.state.activeServerId = serverId

    -- 감시 방식 전환
    stopPathWatcher()
    stopPolling()

    -- 세션 필터 초기화 (서버 변경 시)
    obj.state.currentTaskListId = nil
    obj.config.taskListId = nil
    cachedRemoteTasks = {}
    cachedRemoteSessions = {}
    lastSSHError = nil

    if server.type == "ssh" then
        startPolling()
    else
        startPathWatcher()
    end

    saveState()
    obj:refresh()
    log("Switched to server: " .. serverId .. " (" .. server.name .. ")")
    return self
end

--- SSH 서버 추가
function obj:addServer(serverConfig)
    local data = loadServers()

    -- 필수 필드 검증
    if not serverConfig.id or not serverConfig.host then
        hs.alert.show("Server requires id and host", 2)
        return self
    end

    -- 중복 ID 체크
    for _, s in ipairs(data.servers) do
        if s.id == serverConfig.id then
            hs.alert.show("Server ID already exists: " .. serverConfig.id, 2)
            return self
        end
    end

    -- 기본값 설정
    serverConfig.type = serverConfig.type or "ssh"
    serverConfig.name = serverConfig.name or serverConfig.host
    serverConfig.port = serverConfig.port or 22
    serverConfig.tasksDir = serverConfig.tasksDir or "~/.claude/tasks"
    serverConfig.connectTimeout = serverConfig.connectTimeout or obj.config.sshConnectTimeout

    table.insert(data.servers, serverConfig)
    saveServers(data)

    hs.alert.show("Server added: " .. serverConfig.name, 2)
    log("Server added: " .. serverConfig.id .. " (" .. serverConfig.host .. ")")
    obj:refresh()
    return self
end

--- SSH 서버 제거
function obj:removeServer(serverId)
    if serverId == "local" then
        hs.alert.show("Cannot remove local server", 2)
        return self
    end

    local data = loadServers()
    for i, s in ipairs(data.servers) do
        if s.id == serverId then
            local serverName = s.name
            table.remove(data.servers, i)

            -- 활성 서버가 제거되면 로컬로 전환
            if data.activeServerId == serverId then
                data.activeServerId = "local"
                obj:setActiveServer("local")
            end

            saveServers(data)
            hs.alert.show("Server removed: " .. serverName, 2)
            log("Server removed: " .. serverId)
            obj:refresh()
            return self
        end
    end

    hs.alert.show("Server not found: " .. serverId, 2)
    return self
end

--- SSH 연결 테스트
function obj:testConnection(serverId)
    local server = getServerById(serverId)
    if not server then
        hs.alert.show("Server not found: " .. serverId, 2)
        return self
    end

    if server.type ~= "ssh" then
        hs.alert.show("Not an SSH server", 2)
        return self
    end

    hs.alert.show("Testing connection to " .. server.name .. "...", 1)

    local args = buildSSHArgs(server, "echo 'Connection successful'")

    hs.task.new(obj.config.sshPath, function(exitCode, stdout, stderr)
        if exitCode == 0 then
            hs.alert.show("✓ Connected to " .. server.name, 2)
            log("Connection test passed: " .. server.host)
        else
            local errMsg = (stderr or "Unknown error"):gsub("\n", " ")
            hs.alert.show("✗ Connection failed: " .. errMsg:sub(1, 50), 3)
            log("Connection test failed: " .. errMsg)
        end
    end, args):start()

    return self
end

--- 태스크 생성 (Claude CLI 사용)
function obj:createTask(subject)
    local claudePath = discoverClaudePath()
    if not claudePath then
        hs.alert.show("Claude CLI not found", 2)
        return nil
    end

    local prompt = string.format("TaskCreate(%s)", subject)

    log("Creating task: " .. prompt)

    local env = {}
    if obj.state.currentTaskListId and obj.state.currentTaskListId ~= "" then
        env.CLAUDE_CODE_TASK_LIST_ID = obj.state.currentTaskListId
    end

    local task = hs.task.new(claudePath, function(exitCode, stdout, stderr)
        if exitCode == 0 then
            hs.alert.show("Task created", 1)
            log("Task created successfully. stdout: " .. (stdout or ""))
        else
            hs.alert.show("Task creation failed", 2)
            log("Task creation failed. exitCode: " .. exitCode .. ", stderr: " .. (stderr or ""))
        end

        -- UI 폼 리셋 (JS 호출)
        if webview then
            webview:evaluateJavaScript("resetForm()")
        end

        -- 새로고침
        obj:refresh()
    end, {
        "-p",
        "--model", "haiku",
        prompt
    })

    if next(env) then
        task:setEnvironment(env)
    end

    -- ~/.claude에서 실행
    task:setWorkingDirectory(os.getenv("HOME") .. "/.claude")
    task:start()
    return task
end

--- Quick TaskUpdate (haiku 모델로 빠른 태스크 업데이트)
function obj:quickTaskUpdate(prompt)
    -- 원격 서버에서는 사용 불가
    local server = getActiveServer()
    if server and server.type == "ssh" then
        hs.alert.show("Quick Update not available for remote servers", 2)
        return
    end

    local taskListId = obj.state.currentTaskListId
    if not taskListId or taskListId == "" then
        hs.alert.show("Select a session first", 2)
        return
    end

    local claudePath = discoverClaudePath()
    if not claudePath then
        hs.alert.show("Claude CLI not found", 2)
        return
    end

    -- 필수 환경변수 설정
    local env = {
        PATH = os.getenv("PATH") or "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        HOME = os.getenv("HOME"),
        USER = os.getenv("USER"),
        SHELL = getShell(),
        TERM = "xterm-256color",
        CLAUDE_CODE_ENABLE_TASKS = "true",
        CLAUDE_CODE_TASK_LIST_ID = taskListId
    }

    log("QuickTaskUpdate: " .. prompt .. " (taskListId: " .. taskListId .. ")")

    local task = hs.task.new(claudePath, function(exitCode, stdout, stderr)
        if exitCode == 0 then
            local result = (stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if result == "" then result = "Done" end
            -- 긴 결과는 잘라서 표시
            if #result > 200 then
                result = result:sub(1, 200) .. "..."
            end
            hs.alert.show(result, 3)
            log("QuickTaskUpdate completed. stdout: " .. (stdout or ""))
        else
            local errMsg = (stderr or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if errMsg == "" then errMsg = "TaskUpdate failed" end
            hs.alert.show("❌ " .. errMsg:sub(1, 100), 3)
            log("QuickTaskUpdate failed. exitCode: " .. exitCode .. ", stderr: " .. (stderr or ""))
        end
        obj:refresh()
    end, {
        "--model", "haiku",
        "-p",
        "--no-session-persistence",
        "--disable-slash-commands",
        "--strict-mcp-config",
        "--dangerously-skip-permissions",
        "--setting-sources", "",
        "--verbose",
        "--",
        prompt
    })

    task:setEnvironment(env)
    task:setWorkingDirectory(os.getenv("HOME") .. "/.claude")
    task:start()
    hs.alert.show("Running TaskUpdate...", 1)
end

--- Claude Code 세션 실행
function obj:launchClaudeWithTaskList()
    -- 원격 서버에서는 사용 불가
    local server = getActiveServer()
    if server and server.type == "ssh" then
        hs.alert.show("Launch not available for remote servers", 2)
        return
    end

    local taskListId = obj.state.currentTaskListId
    if not taskListId or taskListId == "" then
        hs.alert.show("Select a session first", 2)
        return
    end

    local terminalPath = discoverTerminalApp()
    if not terminalPath then
        hs.alert.show("No terminal app found", 2)
        return
    end

    local claudeDir = os.getenv("HOME") .. "/.claude"
    local shell = getShell()
    local shellCmd = string.format("cd %s && CLAUDE_CODE_TASK_LIST_ID=%s claude", claudeDir, taskListId)

    log("Launching Claude: " .. shellCmd)

    local task = hs.task.new(terminalPath, function(exitCode, stdout, stderr)
        if exitCode ~= 0 then
            log("Terminal launch error: " .. (stderr or "unknown"))
        end
    end, {
        "-e", shell, "-c", shellCmd
    })

    task:start()
    hs.alert.show("Launching Claude...", 1)
end

--- 모듈 시작 (파일 감시 시작)
function obj:start()
    loadState()  -- 저장된 상태 로드

    -- 서버 타입에 따라 감시 방식 선택
    local server = getActiveServer()
    if server and server.type == "ssh" then
        startPolling()
    else
        startPathWatcher()
    end

    log("Claude Tasks module started (server: " .. (server and server.name or "local") .. ")")
    return self
end

--- 모듈 중지
function obj:stop()
    stopPathWatcher()
    stopPolling()
    if webview then
        webview:delete()
        webview = nil
    end
    if usercontent then
        usercontent = nil
    end
    isVisible = false
    log("Claude Tasks module stopped")
    return self
end

--- 설정 업데이트
function obj:configure(options)
    if options then
        for k, v in pairs(options) do
            obj.config[k] = v
        end
    end
    return self
end

--- 현재 상태 반환
function obj:status()
    local tasks = loadAllTasks()
    local pending = 0
    local inProgress = 0
    local completed = 0

    for _, task in ipairs(tasks) do
        if task.status == "completed" then
            completed = completed + 1
        elseif task.status == "in_progress" then
            inProgress = inProgress + 1
        else
            pending = pending + 1
        end
    end

    local server = getActiveServer()

    return {
        visible = isVisible,
        taskCount = #tasks,
        pending = pending,
        inProgress = inProgress,
        completed = completed,
        taskListId = obj.config.taskListId,
        currentTaskListId = obj.state.currentTaskListId,
        watcherActive = pathWatcher ~= nil,
        pollingActive = pollingTimer ~= nil,
        activeServer = server and server.name or "Local",
        activeServerId = obj.state.activeServerId,
        serverType = server and server.type or "local",
        lastSSHError = lastSSHError,
    }
end

-- ============================================================================
-- Hotkey Binding
-- ============================================================================

obj.defaultHotkeys = {
    toggle = {{"alt"}, "."},
    status = {{"cmd", "alt"}, "T"}
}

function obj:bindHotkeys(mapping)
    local def = {
        toggle = function() obj:toggle() end,
        status = function()
            local status = obj:status()
            local msg = string.format(
                "Tasks: %d total\n⏳ %d pending\n🔄 %d in progress\n✓ %d completed",
                status.taskCount, status.pending, status.inProgress, status.completed
            )
            hs.alert.show(msg, 3)
        end
    }
    hs.spoons.bindHotkeysToSpec(def, mapping)
    return self
end

return obj
