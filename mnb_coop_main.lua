-- ============================================
-- MUD AND BLOOD CO-OP
-- ============================================
-- Co-op multiplayer via filesystem-based networking.
-- Uses an external Python helper for TCP transport.
-- ============================================

local mod = {}
mod._name = "mnb_coop"
mod._version = "0.1.0"

-- JSON module (embedded)
local json = {}

function json.encode(value)
    local t = type(value)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return value and "true" or "false"
    elseif t == "number" then
        if value ~= value then return "null" end
        return string.format("%.17g", value)
    elseif t == "string" then
        return string.format("%q", value)
    elseif t == "table" then
        local parts = {}
        local is_array = true
        local max_index = 0
        local count = 0
        for k, v in pairs(value) do
            count = count + 1
            if type(k) ~= "number" or k < 1 or math.floor(k) ~= k or k > 100000 then
                is_array = false
                break
            end
            if k > max_index then max_index = k end
        end
        if is_array and max_index == count then
            for i = 1, max_index do
                parts[i] = json.encode(value[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local kv_parts = {}
            local first = true
            for k, v in pairs(value) do
                if not first then table.insert(kv_parts, ",") end
                first = false
                table.insert(kv_parts, json.encode(k) .. ":" .. json.encode(v))
            end
            return "{" .. table.concat(kv_parts, ",") .. "}"
        end
    end
    error("Cannot encode value of type " .. t)
end

function json.decode(str)
    if type(str) ~= "string" then return nil end
    str = str:gsub("null", "nil")
    local fn, err = load("return " .. str)
    if not fn then return nil, err end
    return fn()
end

-- State
local isHost = false
local isClient = false
local coopActive = false
local lobbyOpen = false
local statusText = "Co-op: Offline"
local connectInput = ""
local uiState = "menu"
local remotePlayers = {}
local lastSyncTime = 0
local lastReadTime = 0

-- File paths
local COOP_DIR = nil
local CMD_FILE = nil
local DATA_FILE = nil

function mod.getCoopDir()
    if COOP_DIR then return COOP_DIR end

    local saveDir = love.filesystem.getSaveDirectory()
    COOP_DIR = saveDir .. "/coop"
    CMD_FILE = COOP_DIR .. "/cmd.json"
    DATA_FILE = COOP_DIR .. "/data.json"

    -- Try to create directory
    local ok, err = pcall(function()
        love.filesystem.createDirectory("coop")
    end)

    if not ok then
        -- Fallback to temp directory
        local temp = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
        COOP_DIR = temp .. "/mnb_coop"
        CMD_FILE = COOP_DIR .. "/cmd.json"
        DATA_FILE = COOP_DIR .. "/data.json"
    end

    return COOP_DIR
end

-- ============================================
-- FILE I/O
-- ============================================

function mod.writeFile(path, data)
    local ok, result = pcall(function()
        local file = io.open(path, "w")
        if not file then return false end
        file:write(data)
        file:close()
        return true
    end)
    return ok and result == true
end

function mod.readFile(path)
    local ok, result = pcall(function()
        local file = io.open(path, "r")
        if not file then return nil end
        local content = file:read("*a")
        file:close()
        return content
    end)
    return ok and result or nil
end

function mod.writeJSON(path, data)
    local encoded = json.encode(data)
    mod.writeFile(path, encoded)
end

function mod.readJSON(path)
    local content = mod.readFile(path)
    if not content or content == "" then return nil end
    local ok, result = pcall(function()
        return json.decode(content)
    end)
    return ok and result or nil
end

-- ============================================
-- HELPER PROCESS
-- ============================================

function mod.startHelper(mode, address)
    local helperPath = love.filesystem.getSource() .. "/coop_helper.py"

    if not love.filesystem.getInfo("coop_helper.py") then
        statusText = "ERROR: coop_helper.py not found in game directory"
        modLib.mobLog("COOP", "Helper script not found: " .. helperPath)
        return false
    end

    mod.getCoopDir()

    -- Clear old files
    if CMD_FILE then os.remove(CMD_FILE) end
    if DATA_FILE then os.remove(DATA_FILE) end

    -- Write initial command
    local cmd = {
        action = mode,
        host = address or "localhost",
        port = 12345
    }
    mod.writeJSON(CMD_FILE, cmd)

    -- Start helper
    local python = "python"
    if love.system.getOS() == "Windows" then
        python = "python.exe"
    end

    local cmdStr = string.format('start /B "" "%s" "%s"', python, helperPath)

    local ok, err = pcall(function()
        os.execute(cmdStr)
    end)

    if not ok then
        statusText = "Failed to start helper: " .. tostring(err)
        return false
    end

    statusText = mode == "host" and "Starting host..." or "Connecting..."
    modLib.mobLog("COOP", "Started helper: " .. mode)
    return true
end

function mod.stopHelper()
    if COOP_DIR then
        mod.writeJSON(CMD_FILE, { action = "quit" })
    end
end

-- ============================================
-- STATE SERIALIZATION
-- ============================================

function mod.serializeState()
    local state = {
        type = "state",
        time = love.timer.getTime(),
        player = {
            posX = player.posX,
            posY = player.posY,
            screenx = player.screenx,
            screeny = player.screeny,
            gameState = player.gameState
        },
        soldiers = {}
    }

    for i, troop in ipairs(player.deployedTroops) do
        state.soldiers[i] = {
            id = i,
            name = troop.name or "Unknown",
            x = troop.x,
            y = troop.y,
            health = troop.health or 0,
            morale = troop.morale or 0,
            state = troop.state or "idle",
            selected = troop.selected or false
        }
    end

    return state
end

function mod.deserializeState(data)
    if type(data) ~= "table" or data.type ~= "state" then return end

    remotePlayers = {}
    if data.soldiers then
        for _, s in ipairs(data.soldiers) do
            table.insert(remotePlayers, s)
        end
    end

    if data.status == "connected" then
        statusText = "Connected - Syncing..."
    elseif data.status == "disconnected" then
        statusText = "Disconnected"
        mod.closeLobby()
    elseif data.status == "error" then
        statusText = "Error: " .. (data.message or "Unknown")
    end
end

-- ============================================
-- NETWORK LOOPS
-- ============================================

function mod.hostUpdate(dt)
    if not coopActive then return end

    -- Send state every 50ms
    local now = love.timer.getTime()
    if now - lastSyncTime > 0.05 then
        local state = mod.serializeState()
        mod.writeJSON(DATA_FILE, state)
        lastSyncTime = now
    end

    -- Check for incoming client data
    if now - lastReadTime > 0.1 then
        local data = mod.readJSON(CMD_FILE)
        if data and data.type == "state" and data.time > (lastReadTime or 0) then
            -- Client sent their state
        end
        lastReadTime = now
    end
end

function mod.clientUpdate(dt)
    if not coopActive then return end

    -- Read incoming state from host
    local now = love.timer.getTime()
    if now - lastReadTime > 0.05 then
        local data = mod.readJSON(DATA_FILE)
        if data then
            mod.deserializeState(data)
        end
        lastReadTime = now
    end

    -- Send our state to host
    if now - lastSyncTime > 0.1 then
        local state = mod.serializeState()
        mod.writeJSON(CMD_FILE, state)
        lastSyncTime = now
    end
end

-- ============================================
-- HOOKS INTO GAME LOOPS
-- ============================================

modLib.after("love.update", function(dt)
    if not coopActive then return end

    if isHost then
        mod.hostUpdate(dt)
    elseif isClient then
        mod.clientUpdate(dt)
    end
end)

modLib.after("love.draw", function()
    if not coopActive then return end
    mod.drawOverlay()
end)

modLib.after("love.mousereleased", function(x, y, button)
    if not coopActive or not lobbyOpen then return end
    mod.handleMenuClick(x, y, button)
end)

modLib.after("love.textinput", function(t)
    if not coopActive or not lobbyOpen or uiState ~= "join" then return end
    connectInput = connectInput .. t
end)

modLib.after("love.keypressed", function(key)
    if key == "f2" then
        mod.toggle()
        return
    end

    if not coopActive or not lobbyOpen then return end

    if key == "backspace" and uiState == "join" then
        connectInput = connectInput:sub(1, -2)
    end

    if key == "return" and uiState == "join" then
        mod.joinServer(connectInput)
    end

    if key == "escape" then
        mod.closeLobby()
    end
end)

modLib.after("love.quit", function()
    mod.stopHelper()
end)

-- ============================================
-- REMOTE PLAYER RENDERING
-- ============================================

modLib.after("castSprites", function()
    if not coopActive or #remotePlayers == 0 then return end

    for _, rp in ipairs(remotePlayers) do
        if rp.x and rp.y then
            local sx = rp.x
            local sy = rp.y

            -- Draw remote soldier indicator
            love.graphics.setColor(0, 0.8, 1, 0.9)
            love.graphics.circle("fill", sx, sy, 12)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.circle("line", sx, sy, 12)

            -- Selection indicator
            if rp.selected then
                love.graphics.setColor(1, 1, 0, 0.8)
                love.graphics.circle("line", sx, sy, 18)
                love.graphics.setColor(1, 1, 1, 1)
            end

            -- Health bar
            if rp.health then
                local hp = math.max(0, rp.health / 100)
                love.graphics.setColor(0.8, 0.2, 0.2, 1)
                love.graphics.rectangle("fill", sx - 15, sy - 25, 30, 4)
                love.graphics.setColor(0.2, 0.8, 0.2, 1)
                love.graphics.rectangle("fill", sx - 15, sy - 25, 30 * hp, 4)
                love.graphics.setColor(1, 1, 1, 1)
            end

            -- Name tag
            if rp.name then
                love.graphics.print("[COOP] " .. rp.name, sx - 30, sy - 40)
            end
        end
    end
end)

-- ============================================
-- UI DRAWING
-- ============================================

function mod.drawOverlay()
    if not lobbyOpen and uiState ~= "connected" then return end

    love.graphics.origin()

    local w, h = love.graphics.getDimensions()

    -- Background
    love.graphics.setColor(0, 0, 0, 0.75)
    love.graphics.rectangle("fill", 0, 0, w, h)
    love.graphics.setColor(1, 1, 1, 1)

    -- Title
    love.graphics.setFont(bigFont)
    love.graphics.setColor(1, 0.8, 0.2, 1)
    love.graphics.printf("MUD AND BLOOD CO-OP", w / 2 - 350, 80, 700, "center")
    love.graphics.setColor(1, 1, 1, 1)

    -- Status
    love.graphics.setFont(daFont)
    love.graphics.printf(statusText, w / 2 - 300, 160, 600, "center")

    if uiState == "host" then
        love.graphics.printf("Waiting for players to connect...", w / 2 - 300, 210, 600, "center")
        love.graphics.printf("Port: 12345", w / 2 - 300, 250, 600, "center")
        love.graphics.printf("Share your IP address with other players", w / 2 - 300, 290, 600, "center")
    end

    if uiState == "join" then
        love.graphics.printf("Enter host IP address:", w / 2 - 300, 210, 600, "center")
        love.graphics.setColor(0.2, 0.2, 0.2, 1)
        love.graphics.rectangle("fill", w / 2 - 150, 250, 300, 30)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.printf(connectInput, w / 2 - 140, 255, 280, "left")
        love.graphics.printf("Press ENTER to connect, ESC to cancel", w / 2 - 300, 300, 600, "center")
    end

    if uiState == "connected" then
        love.graphics.printf("Connected to session!", w / 2 - 300, 210, 600, "center")
        love.graphics.printf("Press ESC to disconnect", w / 2 - 300, 250, 600, "center")
        love.graphics.printf("Remote soldiers: " .. #remotePlayers, w / 2 - 300, 290, 600, "center")
    end

    if uiState == "menu" then
        mod.drawMenuButtons(w, h)
    end
end

function mod.drawMenuButtons(w, h)
    local cx = w / 2
    local bw, bh = 220, 45
    local spacing = 55
    local startY = 360

    local buttons = {
        { label = "HOST GAME", y = startY,               action = "host",  color = { 0.2, 0.5, 0.2 } },
        { label = "JOIN GAME", y = startY + spacing,     action = "join",  color = { 0.2, 0.3, 0.6 } },
        { label = "CLOSE",     y = startY + spacing * 2, action = "close", color = { 0.5, 0.2, 0.2 } }
    }

    for _, btn in ipairs(buttons) do
        love.graphics.setColor(btn.color[1], btn.color[2], btn.color[3], 1)
        love.graphics.rectangle("fill", cx - bw / 2, btn.y, bw, bh)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.printf(btn.label, cx - bw / 2, btn.y + 12, bw, "center")
    end
end

function mod.handleMenuClick(x, y, button)
    if button ~= 1 then return end

    local w, h = love.graphics.getDimensions()
    local cx = w / 2
    local bw, bh = 220, 45
    local spacing = 55
    local startY = 360

    local buttons = {
        { label = "HOST GAME", y = startY,               action = "host" },
        { label = "JOIN GAME", y = startY + spacing,     action = "join" },
        { label = "CLOSE",     y = startY + spacing * 2, action = "close" }
    }

    for _, btn in ipairs(buttons) do
        if x > cx - bw / 2 and x < cx + bw / 2 and
            y > btn.y and y < btn.y + bh then
            if btn.action == "host" then
                mod.hostGame()
            elseif btn.action == "join" then
                uiState = "join"
                connectInput = ""
            elseif btn.action == "close" then
                mod.closeLobby()
            end
            return
        end
    end
end

-- ============================================
-- GAME ACTIONS
-- ============================================

function mod.hostGame()
    isHost = true
    isClient = false
    coopActive = true
    lobbyOpen = true
    uiState = "host"
    statusText = "Hosting on port 12345..."
    remotePlayers = {}
    lastSyncTime = 0
    lastReadTime = 0

    if mod.startHelper("host") then
        modLib.mobLog("COOP", "Hosting game")
    end
end

function mod.joinServer(address)
    if address == "" then
        statusText = "Please enter an IP address"
        return
    end

    isClient = true
    isHost = false
    coopActive = true
    lobbyOpen = false
    uiState = "connected"
    statusText = "Connecting to " .. address "..."
    remotePlayers = {}
    lastSyncTime = 0
    lastReadTime = 0

    if mod.startHelper("client", address) then
        modLib.mobLog("COOP", "Joining server: " .. address)
    end
end

function mod.closeLobby()
    mod.stopHelper()
    isHost = false
    isClient = false
    coopActive = false
    lobbyOpen = false
    uiState = "menu"
    statusText = "Co-op: Offline"
    remotePlayers = {}
    connectInput = ""

    modLib.mobLog("COOP", "Lobby closed")
end

-- ============================================
-- PUBLIC API
-- ============================================

function mod.toggle()
    if coopActive then
        mod.closeLobby()
    else
        mod.openLobby()
    end
end

function mod.openLobby()
    coopActive = true
    lobbyOpen = true
    uiState = "menu"
    statusText = "Co-op: Ready"
    connectInput = ""
    remotePlayers = {}
    lastSyncTime = 0
    lastReadTime = 0

    mod.getCoopDir()
    modLib.mobLog("COOP", "Lobby opened")
end

function mod.isActive()
    return coopActive
end

function mod.getStatus()
    return statusText
end

function mod.getRemotePlayers()
    return remotePlayers
end

-- ============================================
-- AUTO-INIT ON LOAD
-- ============================================

modLib.after("love.load", function()
    mod.getCoopDir()
    print("[COOP] " .. mod._name .. " v" .. mod._version .. " loaded")
end)

return mod
