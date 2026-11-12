-- =============================================================================
-- CO-OP LOBBY (main menu)
-- "Multiplayer" on the main menu's bottom bar opens this page. It is laid out
-- like the game's own main menu so it feels native:
--   top left        the party: four player cards (avatar, name, showcase, ready)
--   header line     lobby status, where the main menu shows the campaign date
--   right of cards  HOST and JOIN, which become READY once you're in a lobby
--   column 1        CAREER and SQUAD on the co-op profile, where the main menu and the
--                   co-op page have them (owner 2026-11-12: same place on every screen)
--   column 2        the CONNECTION tile (like COMMUNITY): address box + red links
--                   (CLOSE / LEAVE LOBBY is the last one)
--   columns 3-5     CO-OP CAMPAIGN, CO-OP CLASSIC, CO-OP OPTIONS picture tiles
--   bottom bar      Back
-- Buttons are the game's own Button objects (hit zones + tooltips); drawing is ours.
-- qm.toml calls lobby.registerButtons() just before the menu's mouse-over pass and
-- lobby.draw() just before the menu tooltip is drawn, so tooltips stay on top.
-- =============================================================================
local net = require("includes/mods/mnb_coop/coop_net")
local profile = require("includes/mods/mnb_coop/coop_profile")
local campaign = require("includes/mods/mnb_coop/coop_campaign")
local modcheck = require("includes/mods/mnb_coop/coop_mods")

local lobby = {}

-- main menu palette
local RED, LIGHT, WHITE, BLACK, PANEL = { 101, 24, 24 }, { 211, 211, 211 }, { 255, 255, 255 }, { 0, 0, 0 }, { 102, 102, 102 }
local DIM = { 150, 150, 150 }

-- party cards (top left, above the header line)
local BOX, BOX_GAP, BOX_X, BOX_Y = 86, 14, 30, 12
-- connection tile (column 2) and the address box inside its picture frame
local TILE = { x = 275, y = 185, w = 280, h = 465 }
local FRAME = { x = 300, y = 210, w = 230, h = 150 }
local FIELD = { x = 310, y = 248, w = 210, h = 30 }
-- red links in the connection tile, like DISCORD / WIKI / NEWS / VIDEOS
local LINK_Y = { 425, 470, 515, 560, 605 }
-- action buttons (HOST / JOIN, READY) right of the party cards
local ACT_Y, ACT_W, ACT_H, ACT_GAP = BOX_Y, 190, BOX, 15
local function actX(k) return BOX_X + net.MAX_SEATS * (BOX + BOX_GAP) + 20 + (k - 1) * (ACT_W + ACT_GAP) end
-- the main menu's CAREER / SQUAD spot, used on the lobby and on the co-op page alike
local CAREER = { 50, 185, 200, 220 }
local SQUAD = { 50, 430, 200, 220 }
local CAREER_TIP = "Your co-op career: ranks, ribbons and records,\nco-op campaign and co-op Classic together"
local SQUAD_TIP = "Your six soldiers. Right-drag a card onto another to sort:\nthe top row goes on the next mission, the rest stay home."

lobby.page = nil    -- menuPage number of the lobby
lobby.bottomX = nil -- where "Multiplayer" sits on the main menu bar
lobby.fieldFocus = false
lobby.address = nil -- address typed to JOIN
lobby.lanIp = nil
lobby.flash = nil   -- short confirmation shown in the frame ("Copied")
lobby.flashAt = -10

local function fade() return uiFade or 255 end

local function rgba(c, a) return love.math.colorFromBytes(c[1], c[2], c[3], a or fade()) end

-- The main menu's text style: a 1 px black outline on four sides, then the colour.
local function outlined(text, x, y, w, align, font, color)
    font = font or bigFont
    -- one-line labels that don't fit step down a font size instead of wrapping
    if not text:find("\n") and font:getWidth(text) > w then
        if font == bigFont and cardFont and cardFont:getWidth(text) <= w then
            font = cardFont
        elseif nonoFont then
            font = nonoFont
        end
    end
    love.graphics.setFont(font)
    love.graphics.setColor(1, 1, 1, 1) -- coloured text is multiplied by the current colour
    local black = { rgba(BLACK) }
    align = align or "left"
    love.graphics.printf({ black, text }, x - 1, y, w, align)
    love.graphics.printf({ black, text }, x + 1, y, w, align)
    love.graphics.printf({ black, text }, x, y - 1, w, align)
    love.graphics.printf({ black, text }, x, y + 1, w, align)
    love.graphics.printf({ { rgba(color or WHITE) }, text }, x, y, w, align)
end

local function hovered(x, y, w, h)
    local mx, my = love.mouse.getPosition()
    return mx > x and mx < x + w and my > y and my < y + h
end

local function click()
    pcall(function() _G["weaponInspect" .. randNbr(5)]:clone():play() end)
end

local function port()
    local p = net.option("port", net.DEFAULT_PORT)
    return tonumber(p) or net.DEFAULT_PORT
end

local function flash(text)
    lobby.flash, lobby.flashAt = text, love.timer.getTime()
end

-- The address box holds the address to JOIN, or, while hosting, the address to SHARE.
local function fieldText()
    if net.role == "host" then return profile.settings.shareAddress or "" end
    return lobby.address or ""
end

local function setFieldText(text)
    if net.role == "host" then
        profile.settings.shareAddress = text
        profile.saveSettings()
    else
        lobby.address = text
    end
end

-- What a friend should type to reach this host: the pasted playit address, else our LAN address.
local function baseAddress()
    local s = profile.settings.shareAddress or ""
    if s ~= "" then return s end
    return (lobby.lanIp or "127.0.0.1") .. ":" .. port()
end

-- The join code rides along after a "#", so friends paste one thing and are let in.
local function shareAddress()
    return baseAddress() .. (net.joinCode and ("#" .. net.joinCode) or "")
end

local function requireCode()
    return net.isOn("joinCode", true)
end

local function clipboardAddress()
    return (love.system.getClipboardText() or ""):gsub("[^%w%.%-:_#]", ""):sub(1, 64)
end

-- The mod menu: QuarterMaster 1.8's built-in QM.Menu, else the old standalone GMenu (QM 1.4).
-- Both hand out page numbers (allocatePage) and have the Mod Options screen (PAGE_MOD_OPTIONS,
-- modList, activeModIndex). Nil without either.
local function modMenu()
    local qm = rawget(_G, "QM")
    local m = type(qm) == "table" and rawget(qm, "Menu")
    if type(m) == "table" then return m end
    local gm = rawget(_G, "GMenu")
    if type(gm) == "table" then return gm end
end
lobby.modMenu = modMenu

function lobby.getPage()
    if lobby.page then return lobby.page end
    local menu = modMenu()
    if menu and menu.allocatePage then
        lobby.page = menu.allocatePage("mnb_coop", "lobby", nil, nil)
    else
        lobby.page = 140
    end
    return lobby.page
end

-- The co-op page: Multiplayer > CO-OP CAMPAIGN opens it. Campaign, Squad and
-- Career on the co-op save, and Back to the Multiplayer screen. While co-op is
-- open, every screen that would go back to the main menu comes here instead.
lobby.hubPage = nil
function lobby.getHubPage()
    if lobby.hubPage then return lobby.hubPage end
    local menu = modMenu()
    if menu and menu.allocatePage then
        lobby.hubPage = menu.allocatePage("mnb_coop", "hub", nil, nil)
    else
        lobby.hubPage = 141
    end
    return lobby.hubPage
end

-- ---------------------------------------------------------------- state-dependent pieces
-- The action buttons right of the party cards: HOST and JOIN, CANCEL while connecting,
-- READY once in a lobby (next to the cards' own READY lights). Each { label, title, tooltip, sub, lit }.
local function actions()
    if net.role == "offline" then
        return {
            { "coopHost", "HOST", "Open a lobby on UDP port " .. port() .. ". Up to " .. net.MAX_SEATS .. " players.", "open a lobby" },
            { "coopJoin", "JOIN", "Join the host whose address is in the CONNECTION box", "use the address" },
        }
    elseif net.role == "connecting" then
        return { { "coopLeave", "CANCEL", "Stop connecting", "stop connecting" } }
    end
    local ready = net.myReady()
    local tip = ready and "Take back your ready" or "Tell the others you are ready"
    if net.role == "host" then tip = tip .. "\nBattles start once every friend has pressed READY" end
    return { { "coopReady", "READY", tip, ready and "you're ready (click to undo)" or "click when you're set", ready } }
end

-- Connection tile links: { label, text, tooltip }
local function links()
    if net.role == "host" then
        return {
            { "coopCopy", "COPY ADDRESS", "Copy the address above to send it to your friends (Ctrl+C)" },
            (profile.settings.shareAddress or "") == ""
            and { "coopPaste", "PASTE ADDRESS", "Paste your playit.gg address from the clipboard (Ctrl+V)" }
            or { "coopLocal", "USE LOCAL ADDRESS", "Go back to your home-network address " .. (lobby.lanIp or "") },
            net.joinCode and { "coopNewCode", "NEW CODE", "Make a new join code. Players already in stay;\nanyone with the old address can't join any more." }
            or { "coopNothing", "", "" },
            { "coopHelp", "PLAY ONLINE?", "Online play: run playit.gg, make a UDP tunnel to port " .. port() ..
            ",\npaste its address above, then COPY ADDRESS and send it to your friends." },
            { "coopLeave", "CLOSE LOBBY", "Close the lobby; everyone is disconnected" },
        }
    elseif net.role == "client" then
        -- the info text fills the top of the tile; LEAVE sits in the last slot
        local blank = { "coopNothing", "", "" }
        return { blank, blank, blank, blank, { "coopLeave", "LEAVE LOBBY", "Leave this lobby" } }
    elseif net.role == "offline" then
        return {
            { "coopPaste", "PASTE ADDRESS", "Paste the host's address from the clipboard (Ctrl+V)" },
            { "coopClear", "CLEAR",         "Empty the address box" },
            { "coopHelp", "HOW TO JOIN?", "Same house: the host's local address (like 192.168.0.10:47913).\n" ..
            "Online: the host's playit.gg address (like name.playit.gg:12345)." },
        }
    end
    return {}
end

local seatCard, isMe -- defined with the drawing code below

local function seatTip(i)
    local s = seatCard(i)
    if not s then return "Open seat" end
    local lines = { s.name }
    local show = profile.showcaseText(s.show)
    if show ~= "" then lines[#lines + 1] = show end
    if s.ping and not isMe(i) then lines[#lines + 1] = "Ping " .. math.floor(s.ping) .. " ms" end
    if net.role ~= "offline" then lines[#lines + 1] = s.ready and "Ready" or "Not ready" end
    if net.role ~= "offline" and s.where and net.WHERE[s.where] then lines[#lines + 1] = net.WHERE[s.where][2] end
    -- the mod check: the host sees each friend's differences, a friend sees theirs on the host's card
    local diffs = lobby.modDiffsFor(i)
    if diffs then
        lines[#lines + 1] = modcheck.summary(diffs)
        for _, l in ipairs(modcheck.lines(diffs, 6)) do lines[#lines + 1] = "  " .. l end
    end
    if isMe(i) then
        lines[#lines + 1] = "Click to change what your card shows"
    elseif net.role == "host" then
        lines[#lines + 1] = (lobby.kickArm == i) and "Click again to REMOVE from the lobby" or "Click twice to remove from the lobby"
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------- buttons
-- Each label X maps to the global function XButton() (the game's convention).
local function addButton(x, y, w, h, label, tip)
    buttons[#buttons + 1] = Button.new(x, y, w, h, label, "active", true, tip or "")
end

function lobby.registerButtons()
    if menuPage == 1 then
        -- "Multiplayer" goes right of whatever is on the bottom bar (Quit, the mod menu, ...)
        local right = 50
        for _, b in ipairs(buttons) do
            if b.Y and b.Y >= 680 and b.Y <= 690 and b.X + b.width > right then right = b.X + b.width end
        end
        lobby.bottomX = right + 25
        addButton(lobby.bottomX, 686, 150, 30, "coopOpen", "Play together: host or join a co-op lobby")
        return
    end
    if campaign.active and menuPage == lobby.getHubPage() then
        local canStart = net.role == "host" or net.role == "offline"
        addButton(CAREER[1], CAREER[2], CAREER[3], CAREER[4], "coopHubCareer", CAREER_TIP)
        addButton(SQUAD[1], SQUAD[2], SQUAD[3], SQUAD[4], "coopHubSquad", SQUAD_TIP)
        addButton(275, 185, 200, 465, "coopHubCampaign", canStart
            and "Brief and start the next mission, for everyone in the lobby"
            or "The host starts the missions. You'll be pulled in when the battle begins.")
        addButton(32, 686, 80, 30, "coopHubBack", "Back to the Multiplayer screen")
        addButton(1060, 686, 170, 30, "coopHubNewWar", lobby.newWarArmed()
            and "Click again to start a NEW WAR now"
            or "Start the war over at D-Day: day, sector, career and ribbons reset.\nYour six soldiers come along with their levels. The old war is kept as a backup.")
        addButton(860, 686, 170, 30, "coopHubFreshStart", lobby.freshArmed()
            and "Click again to start over with NEW ROOKIES now"
            or "Full reset: like New war, but your six soldiers are replaced by new rookies.\nThe old war is kept as a backup.")
        return
    end
    if menuPage ~= lobby.getPage() then return end
    for i = 1, net.MAX_SEATS do
        addButton(BOX_X + (i - 1) * (BOX + BOX_GAP), BOX_Y, BOX, BOX + 20, "coopSeat" .. i, seatTip(i))
    end
    for k, a in ipairs(actions()) do
        addButton(actX(k), ACT_Y, ACT_W, ACT_H, a[1], a[3])
    end
    addButton(CAREER[1], CAREER[2], CAREER[3], CAREER[4], "coopCareer", CAREER_TIP)
    addButton(SQUAD[1], SQUAD[2], SQUAD[3], SQUAD[4], "coopSquad", SQUAD_TIP)
    local canStart = net.role == "host" or net.role == "offline"
    addButton(580, 185, 200, 465, "coopCampaign", (campaign.hasSave() and "Your co-op war" or "Start your co-op war") ..
        ": the day, the map and the next mission." ..
        (canStart and "\nCampaign starts the next mission for everyone." or "\nThe host starts the missions.") ..
        "\nYour own campaign is not touched.")
    addButton(805, 185, 200, 465, "coopClassic", canStart
        and "Co-op Classic, DEFENSE: your squads start in the middle around a radar,\nthe Germans come from both sides. Ten of them at the radar and it's over.\nPick a Classic mode next (trench and para modes play as usual).\nRank and ribbons go to your co-op career; your real Classic is not touched."
        or "The host starts the battle. You'll be pulled in when it begins.")
    addButton(1030, 185, 200, 465, "coopOptions", "Co-op settings (port, debug log)")
    if net.role == "host" or net.role == "offline" then
        addButton(FIELD.x, FIELD.y, FIELD.w, FIELD.h, "coopField", net.role == "host"
            and "The address friends type. Your local one is shown; paste a playit.gg address here for online play."
            or "The host's address: an IP (192.168.0.10:47913) or a playit.gg address. Ctrl+V pastes, Enter joins.")
    end
    for i, l in ipairs(links()) do
        addButton(TILE.x + 30, LINK_Y[i], TILE.w - 60, 32, l[1], l[3])
    end
    addButton(32, 686, 80, 30, "coopBack", "Back to the main menu")
end

-- ---------------------------------------------------------------- click handlers
-- globals, called by the game's Button.click
function coopOpenButton()
    click()
    profile.loadSettings()
    lobby.address = lobby.address or profile.settings.lastAddress
    lobby.lanIp = lobby.lanIp or net.lanAddress()
    lobby.preview = nil
    menuPage = lobby.getPage()
    mouseOverText = ""
end

function coopBackButton()
    click()
    lobby.fieldFocus = false
    if campaign.active then campaign.exit() end -- leaving the lobby = back to your own save
    campaign.classic.exit() -- same for the co-op Classic profile
    menuPage = 1
    mouseOverText = ""
end

function coopHostButton()
    click()
    lobby.fieldFocus = false
    net.hostGame(port(), requireCode())
end

function coopJoinButton()
    click()
    lobby.fieldFocus = false
    if (lobby.address or "") == "" then
        lobby.fieldFocus = true
        net.status = "Type or paste the host's address first"
        return
    end
    if net.join(lobby.address) then
        profile.settings.lastAddress = lobby.address
        profile.saveSettings()
    end
end

function coopLeaveButton()
    click()
    net.leave()
end

function coopReadyButton()
    click()
    net.setReady(not net.myReady())
end

function coopNothingButton() end

function coopFieldButton()
    lobby.fieldFocus = true
end

function coopCopyButton()
    click()
    love.system.setClipboardText(shareAddress())
    flash("Copied!")
end

function coopPasteButton()
    click()
    local clip = clipboardAddress()
    if clip == "" then
        flash("Clipboard is empty")
        return
    end
    setFieldText(clip)
    flash("Pasted")
end

function coopNewCodeButton()
    click()
    net.newJoinCode()
    flash("New code: " .. net.joinCode)
end

function coopLocalButton()
    click()
    setFieldText("")
    flash("Local address")
end

function coopClearButton()
    click()
    setFieldText("")
end

function coopHelpButton() end

local function seatClick(i)
    if net.role == "host" and not isMe(i) and net.seats[i] then
        -- removing a player takes two clicks within 3 seconds
        if lobby.kickArm == i and love.timer.getTime() - (lobby.kickArmAt or 0) < 3 then
            click()
            lobby.kickArm = nil
            net.kick(i)
        else
            lobby.kickArm, lobby.kickArmAt = i, love.timer.getTime()
        end
        return
    end
    if isMe(i) then
        click()
        profile.loadSettings()
        profile.nextShowcase()
        lobby.preview = nil
        net.refreshCard()
    end
end
for i = 1, 4 do _G["coopSeat" .. i .. "Button"] = function() seatClick(i) end end

-- Where the game's "back to the main menu" goes while co-op is open (coop_campaign.lua):
-- the page Career or Squad was opened from, the lobby or the co-op page.
lobby.returnPage = nil
function lobby.backPage()
    return lobby.returnPage or lobby.getHubPage()
end

function coopCampaignButton()
    -- anyone opens their own co-op save; only the host (or offline) starts missions there
    click()
    lobby.fieldFocus = false
    local ok, why = campaign.enter()
    if not ok then
        net.status = "Co-op campaign: " .. tostring(why)
        return
    end
    mouseOverText = ""
    lobby.returnPage = lobby.getHubPage()
    menuPage = lobby.getHubPage() -- the co-op page
end

-- Career and Squad: the game's own screens on the co-op profile, from the lobby or the co-op page
local function openOnCoop(screen, from)
    click()
    lobby.fieldFocus = false
    local ok, why = campaign.enter() -- (already open from the co-op page)
    if not ok then
        net.status = "Co-op career: " .. tostring(why)
        return
    end
    mouseOverText = ""
    lobby.returnPage = from
    screen()
end

function coopCareerButton() openOnCoop(menu_careerButton, lobby.getPage()) end
function coopSquadButton() openOnCoop(menu_squadButton, lobby.getPage()) end
function coopHubCareerButton() openOnCoop(menu_careerButton, lobby.getHubPage()) end
function coopHubSquadButton() openOnCoop(menu_squadButton, lobby.getHubPage()) end

function coopHubCampaignButton()
    if not (net.role == "host" or net.role == "offline") then
        if mnbCoop and mnbCoop.notice then mnbCoop.notice("Only the host starts missions") end
        return
    end
    click()
    mouseOverText = ""
    menu_campaignButton()
end

function coopHubBackButton()
    click()
    mouseOverText = ""
    menuPage = lobby.getPage() -- the Multiplayer screen; Back there leaves co-op
end

-- New war needs two clicks within 3 seconds
lobby.newWarAt = nil
function lobby.newWarArmed()
    return lobby.newWarAt ~= nil and love.timer.getTime() - lobby.newWarAt < 3
end

function coopHubNewWarButton()
    click()
    if not lobby.newWarArmed() then
        lobby.newWarAt = love.timer.getTime()
        return
    end
    lobby.newWarAt = nil
    local ok, why = campaign.newWar()
    if ok then
        menuPage = lobby.getHubPage()
        if mnbCoop and mnbCoop.notice then mnbCoop.notice("New war: day 1, your soldiers came along") end
    elseif mnbCoop and mnbCoop.notice then
        mnbCoop.notice("New war: " .. tostring(why))
    end
    mouseOverText = ""
end

-- Fresh start (full reset: new rookies too), also two clicks within 3 seconds
lobby.freshAt = nil
function lobby.freshArmed()
    return lobby.freshAt ~= nil and love.timer.getTime() - lobby.freshAt < 3
end

function coopHubFreshStartButton()
    click()
    if not lobby.freshArmed() then
        lobby.freshAt = love.timer.getTime()
        lobby.newWarAt = nil
        return
    end
    lobby.freshAt = nil
    local ok, why = campaign.newWar(true)
    if ok then
        menuPage = lobby.getHubPage()
        if mnbCoop and mnbCoop.notice then mnbCoop.notice("Fresh start: day 1 with six new rookies") end
    elseif mnbCoop and mnbCoop.notice then
        mnbCoop.notice("Fresh start: " .. tostring(why))
    end
    mouseOverText = ""
end

-- Co-op Classic (coop_defense.lua): the game's Classic, with the defense layout
function coopClassicButton()
    if not (net.role == "host" or net.role == "offline") then
        if mnbCoop and mnbCoop.notice then mnbCoop.notice("Only the host starts battles") end
        return
    end
    if not net.readyToStart() then return end -- every friend's READY first (it names who's missing)
    if campaign.active then pcall(campaign.exit) end -- Classic has its own save
    -- co-op Classic runs on its own Classic profile (coop/classic), never the real one
    local ok, why = campaign.classic.enter()
    if not ok then
        if mnbCoop and mnbCoop.notice then mnbCoop.notice("Co-op Classic: " .. tostring(why)) end
        return
    end
    click()
    mouseOverText = ""
    lobby.fieldFocus = false
    if mnbCoop and mnbCoop.defense then mnbCoop.defense.armed = true end
    menu_classicButton()
end

function coopOptionsButton()
    click()
    local menu = modMenu()
    if menu and menu.modList and menu.PAGE_MOD_OPTIONS then
        local found = false
        for i, id in ipairs(menu.modList) do
            if id == "mnb_coop" then menu.activeModIndex = i found = true end
        end
        if not found then
            -- the menu is there but didn't take our config.lua: say so (the log has QM's reason)
            print("[mnb_coop] options: the mod menu has no mnb_coop entry (config.lua not loaded)")
            net.status = "The mod menu didn't load the co-op options (see QuarterMaster's log)"
            return
        end
        menuPage = menu.PAGE_MOD_OPTIONS
        mouseOverText = ""
    else
        net.status = "Update QuarterMaster (1.8 or newer) to change co-op options"
    end
end

-- ---------------------------------------------------------------- keyboard
function lobby.wantsKeyboard()
    return lobby.fieldFocus and menuPage == lobby.page
end

function lobby.textinput(t)
    local text = fieldText()
    if #text < 64 and t:match("^[%w%.%-:_#]+$") then setFieldText(text .. t) end
end

function lobby.keypressed(key)
    local text = fieldText()
    local ctrl = love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")
    if key == "backspace" then
        setFieldText(text:sub(1, -2))
    elseif key == "c" and ctrl and net.role == "host" then
        coopCopyButton()
    elseif key == "v" and ctrl then
        setFieldText((text .. clipboardAddress()):sub(1, 64))
    elseif key == "return" or key == "kpenter" then
        lobby.fieldFocus = false
        if net.role == "offline" then coopJoinButton() end
    elseif key == "escape" or key == "tab" then
        lobby.fieldFocus = false
    end
end

function lobby.mousereleased(x, y)
    if lobby.fieldFocus and not (x > FIELD.x and x < FIELD.x + FIELD.w and y > FIELD.y and y < FIELD.y + FIELD.h) then
        lobby.fieldFocus = false
    end
end

-- ---------------------------------------------------------------- mod check
-- Which differences a card shows: the host sees each friend's; a friend sees theirs on the
-- host's card (they never see other friends' mod lists). nil = nothing to show.
function lobby.modDiffsFor(i)
    if net.role == "host" and i ~= 1 then return net.modDiffs[i] end
    if net.role == "client" and i == 1 then return net.modDiffs[1] end
    return nil
end

-- ---------------------------------------------------------------- where everyone is
-- Each player's place goes on their card for the others (net.WHERE): a friend reading the
-- battle report or sorting their squad isn't just "missing". Sent when it changes, and
-- again every few seconds (a lost or early one fixes itself).
function lobby.whereAmI()
    local battle = mnbCoop and mnbCoop.battle
    if battle and battle.viewing then return battle.inDebrief() and "report" or "battle" end
    if battle and battle.hostActive then
        return (type(player) == "table" and player.gameState ~= 0) and "report" or "battle"
    end
    if menuPage == lobby.page then return "lobby" end
    if campaign.active then return "campaign" end
    if type(player) == "table" and player.gameType == 1 then return "classic" end
    return "menu"
end

lobby.whereSent, lobby.whereSentAt = nil, 0
function lobby.updatePresence()
    if net.role ~= "host" and net.role ~= "client" then
        lobby.whereSent = nil
        return
    end
    local w = lobby.whereAmI()
    local now = love.timer.getTime()
    if w ~= lobby.whereSent or now - lobby.whereSentAt > 4 then
        lobby.whereSent, lobby.whereSentAt = w, now
        net.setWhere(w)
    end
end

-- ---------------------------------------------------------------- drawing
-- The card shown in seat i: the lobby's, or our own preview while offline.
function seatCard(i)
    if net.role == "offline" then
        if i ~= 1 then return nil end
        if not lobby.preview then
            local bytes = profile.avatarBytes()
            lobby.preview = {
                name = profile.name(),
                show = profile.showcase(),
                face = profile.face(),
                avatar = profile.imageFromBytes(bytes, "me")
            }
        end
        return lobby.preview
    end
    return net.seats[i]
end

function isMe(i)
    return i == net.mySeat or (net.role == "offline" and i == 1)
end

local function drawSeat(i)
    local x, y = BOX_X + (i - 1) * (BOX + BOX_GAP), BOX_Y
    local s = seatCard(i)
    -- grey card like the menu tiles, picture inside a black frame
    love.graphics.setColor(rgba(PANEL, s and fade() or 140))
    love.graphics.rectangle("fill", x, y, BOX, BOX)
    if s then
        love.graphics.setColor(rgba(WHITE))
        if s.avatar then
            love.graphics.draw(s.avatar, x + 4, y + 4, 0, (BOX - 8) / s.avatar:getWidth(), (BOX - 8) / s.avatar:getHeight())
        else
            profile.drawFace(s.face, x + 4, y + 4, BOX - 8)
        end
        local img = profile.showcaseImage(s.show)
        if img then
            local scale = math.min(30 / img:getWidth(), 30 / img:getHeight())
            love.graphics.setColor(rgba(BLACK, 170))
            love.graphics.rectangle("fill", x + BOX - 38, y + BOX - 38, 34, 34)
            love.graphics.setColor(rgba(WHITE))
            love.graphics.draw(img, x + BOX - 21, y + BOX - 21, 0, scale, scale, img:getWidth() / 2, img:getHeight() / 2)
        end
        if s.ready then
            love.graphics.setColor(rgba(RED, 230))
            love.graphics.rectangle("fill", x + 4, y + 4, BOX - 8, 18)
            outlined("READY", x, y + 4, BOX, "center", nonoFont, WHITE)
        end
        -- mods to look at (coop_mods.lua): a "!" in the corner, orange to check, red serious
        local worst = modcheck.worst(lobby.modDiffsFor(i))
        if worst >= 2 then
            love.graphics.setColor(rgba(worst >= 3 and { 200, 30, 30 } or { 220, 140, 20 }, 235))
            love.graphics.rectangle("fill", x + BOX - 24, y + 24, 20, 20)
            outlined("!", x + BOX - 24, y + 26, 20, "center", nonoFont, WHITE)
        end
        -- where they are (lobby, campaign, battle report...), along the card's bottom
        local where = net.role ~= "offline" and s.where and net.WHERE[s.where]
        if where then
            love.graphics.setColor(rgba(BLACK, 190))
            love.graphics.rectangle("fill", x + 4, y + BOX - 24, BOX - 8, 18)
            outlined(where[1], x, y + BOX - 24, BOX, "center", nonoFont, s.where == "lobby" and LIGHT or WHITE)
        end
        if lobby.kickArm == i and love.timer.getTime() - (lobby.kickArmAt or 0) < 3 then
            love.graphics.setColor(rgba(RED, 200))
            love.graphics.rectangle("fill", x + 4, y + 4, BOX - 8, BOX - 8)
            outlined("REMOVE?", x, y + BOX / 2 - 9, BOX, "center", nonoFont, WHITE)
        end
        local nameColor = isMe(i) and LIGHT or WHITE
        outlined(s.name, x - 10, y + BOX + 3, BOX + 20, "center", nonoFont, nameColor)
    else
        outlined("OPEN", x, y + BOX / 2 - 9, BOX, "center", nonoFont, DIM)
    end
    love.graphics.setColor(rgba(BLACK))
    love.graphics.rectangle("line", x + 4, y + 4, BOX - 8, BOX - 8)
    -- seat colour stripe along the bottom of a taken seat
    if s then
        love.graphics.setColor(rgba(net.SEAT_COLORS[i]))
        love.graphics.rectangle("fill", x, y + BOX - 4, BOX, 4)
    end
    if hovered(x, y, BOX, BOX + 20) and s then
        love.graphics.setColor(rgba(RED))
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", x, y, BOX, BOX)
        love.graphics.setLineWidth(1)
    end
end

-- A picture tile like the main menu's: grey panel, red-tinted picture in a black frame,
-- outlined title near the bottom. `frame` = { x, y, w, h } of the picture.
local function drawTile(x, y, w, h, frame, icon, title, titleY, enabled, sub)
    local hot = enabled and hovered(x, y, w, h)
    love.graphics.setColor(rgba(PANEL))
    love.graphics.rectangle("fill", x, y, w, h)
    if icon then
        love.graphics.setColor(rgba(RED, enabled and fade() or 110))
        love.graphics.draw(icon, frame[1], frame[2], 0, frame[3] / icon:getWidth(), frame[4] / icon:getHeight())
    end
    love.graphics.setColor(rgba(BLACK))
    love.graphics.rectangle("line", frame[1], frame[2], frame[3], frame[4])
    outlined(title, x, titleY, w, "center", bigFont, hot and RED or (enabled and WHITE or DIM))
    if sub then outlined(sub, x, titleY + 32, w, "center", nonoFont, DIM) end
end

-- CAREER and SQUAD, same tiles in the same place on the lobby and the co-op page
-- (and where the game's main menu has them)
local function drawCareerSquad()
    drawTile(CAREER[1], CAREER[2], CAREER[3], CAREER[4], { 75, 210, 150, 115 }, profileIcon1, "CAREER", 355, true, "campaign + classic")
    drawTile(SQUAD[1], SQUAD[2], SQUAD[3], SQUAD[4], { 75, 455, 150, 115 }, squadIcon1, "SQUAD", 600, true, "sort who goes")
end

-- HOST / JOIN or READY, right of the party cards
local function drawActions()
    for k, a in ipairs(actions()) do
        local x = actX(k)
        local hot = hovered(x, ACT_Y, ACT_W, ACT_H)
        love.graphics.setColor(rgba(PANEL))
        love.graphics.rectangle("fill", x, ACT_Y, ACT_W, ACT_H)
        -- the frame inside: dark, or red when lit (you are ready)
        love.graphics.setColor(rgba(a[5] and RED or { 20, 20, 20 }, a[5] and 235 or 200))
        love.graphics.rectangle("fill", x + 6, ACT_Y + 6, ACT_W - 12, ACT_H - 12)
        love.graphics.setColor(rgba(BLACK))
        love.graphics.rectangle("line", x + 6, ACT_Y + 6, ACT_W - 12, ACT_H - 12)
        outlined(a[2], x, ACT_Y + 18, ACT_W, "center", bigFont, (hot and not a[5]) and RED or WHITE)
        outlined(a[4], x + 8, ACT_Y + 54, ACT_W - 16, "center", nonoFont, a[5] and WHITE or LIGHT)
        if hot then
            love.graphics.setColor(rgba(RED))
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", x, ACT_Y, ACT_W, ACT_H)
            love.graphics.setLineWidth(1)
        end
    end
end

local function drawConnection()
    local hosting = net.role == "host"
    love.graphics.setColor(rgba(PANEL))
    love.graphics.rectangle("fill", TILE.x, TILE.y, TILE.w, TILE.h)
    -- the "picture" of this tile is a dark panel with the address box and the status
    love.graphics.setColor(rgba({ 20, 20, 20 }, 235))
    love.graphics.rectangle("fill", FRAME.x, FRAME.y, FRAME.w, FRAME.h)
    love.graphics.setColor(rgba(BLACK))
    love.graphics.rectangle("line", FRAME.x, FRAME.y, FRAME.w, FRAME.h)

    local label = hosting and "YOUR ADDRESS" or (net.role == "offline" and "HOST ADDRESS" or "CONNECTED TO")
    outlined(label, FRAME.x + 10, FRAME.y + 10, FRAME.w - 20, "left", nonoFont, LIGHT)

    local editable = hosting or net.role == "offline"
    love.graphics.setColor(rgba(editable and { 45, 45, 45 } or { 30, 30, 30 }))
    love.graphics.rectangle("fill", FIELD.x, FIELD.y, FIELD.w, FIELD.h)
    love.graphics.setColor(rgba((lobby.fieldFocus or (editable and hovered(FIELD.x, FIELD.y, FIELD.w, FIELD.h))) and RED or BLACK))
    love.graphics.rectangle("line", FIELD.x, FIELD.y, FIELD.w, FIELD.h)
    local text = fieldText()
    if net.role == "client" or net.role == "connecting" then text = lobby.address or "" end
    local caret = (lobby.fieldFocus and math.floor(love.timer.getTime() * 2) % 2 == 0) and "|" or ""
    -- long addresses (playit ones) show their end, which is the part you're typing
    local function fitted(s)
        local font, w = cardFont, FIELD.w - 16
        if font:getWidth(s) > w then font = nonoFont end
        local cut = false
        while #s > 1 and font:getWidth((cut and "..." or "") .. s) > w do s, cut = s:sub(2), true end
        return (cut and "..." or "") .. s, font
    end
    if text == "" and not lobby.fieldFocus then
        if hosting then
            local s, font = fitted(baseAddress()) -- the join code is shown below and added by COPY
            outlined(s, FIELD.x + 8, FIELD.y + (font == cardFont and 5 or 7), FIELD.w - 16, "left", font, WHITE)
        else
            outlined("click, type or paste", FIELD.x + 8, FIELD.y + 7, FIELD.w - 16, "left", nonoFont, DIM)
        end
    else
        local s, font = fitted(text .. caret)
        outlined(s, FIELD.x + 8, FIELD.y + (font == cardFont and 5 or 7), FIELD.w - 16, "left", font, WHITE)
    end

    local status = net.status
    if lobby.flash and love.timer.getTime() - lobby.flashAt < 1.5 then status = lobby.flash end
    outlined(status, FRAME.x + 10, FIELD.y + FIELD.h + 10, FRAME.w - 20, "left", nonoFont, LIGHT)
    if hosting then
        local guardText = net.joinCode and ("Join code " .. net.joinCode .. " (in the copied address)") or "Open lobby: no join code"
        if net.blocked > 0 then guardText = guardText .. "\nTurned away: " .. net.blocked end
        outlined(guardText, FRAME.x + 10, FIELD.y + FIELD.h + 32, FRAME.w - 20, "left", nonoFont, DIM)
    end

    -- title + info + links, like COMMUNITY / DISCORD / WIKI...
    local title = hosting and "HOSTING" or (net.role == "client" and "IN LOBBY" or "CONNECTION")
    outlined(title, TILE.x, 385, TILE.w, "center", bigFont, WHITE)
    local list = links()
    if net.role == "client" or net.role == "connecting" then
        local info = net.role == "client" and ("Players " .. net.playerCount() .. "/" .. net.MAX_SEATS ..
            "\n\nClick your card to change\nwhat it shows.\n\nWaiting for the host.") or "Connecting..."
        outlined(info, TILE.x + 20, 430, TILE.w - 40, "center", nonoFont, WHITE)
    end
    for i, l in ipairs(list) do
        local hot = hovered(TILE.x + 30, LINK_Y[i], TILE.w - 60, 32)
        outlined(l[2], TILE.x, LINK_Y[i], TILE.w, "center", bigFont, hot and WHITE or RED)
    end
end

local function headerText()
    local p = port()
    if net.role == "host" then
        return "CO-OP LOBBY, hosting on port " .. p .. ", " .. net.playerCount() .. "/" .. net.MAX_SEATS .. " players"
    elseif net.role == "client" then
        return "CO-OP LOBBY, " .. net.playerCount() .. "/" .. net.MAX_SEATS .. " players"
    elseif net.role == "connecting" then
        return "CO-OP, connecting..."
    end
    return "CO-OP, host a lobby or join one"
end

-- The co-op page: Career and Squad stacked in column 1 (where the main menu has
-- them), the Campaign tile in column 2, and a briefing panel with your six soldiers.
local function drawHub()
    local p = campaign.profile or player
    love.graphics.setFont(bigFont)
    love.graphics.setColor(rgba({ 120, 120, 120 }))
    love.graphics.print("CO-OP CAMPAIGN, day " .. tostring(p.dayz or 1), 30, 130)

    local canStart = net.role == "host" or net.role == "offline"
    drawCareerSquad()
    drawTile(275, 185, 200, 465, { 300, 210, 150, 360 }, campaingIcon1, "CAMPAIGN", 590, canStart,
        canStart and "next mission" or "host starts it")

    -- briefing panel: who goes on the next mission
    local x, y, w, h = 500, 185, 730, 465
    love.graphics.setColor(rgba(PANEL))
    love.graphics.rectangle("fill", x, y, w, h)
    love.graphics.setColor(rgba({ 20, 20, 20 }, 235))
    love.graphics.rectangle("fill", x + 25, y + 25, w - 50, h - 50)
    love.graphics.setColor(rgba(BLACK))
    love.graphics.rectangle("line", x + 25, y + 25, w - 50, h - 50)
    local players = campaign.playersNow()
    local share = campaign.share(players)
    outlined("YOUR SQUAD", x + 45, y + 40, 300, "left", bigFont, WHITE)
    local cap = campaign.levelCap(p.gainz)
    outlined(players .. (players == 1 and " player" or " players") .. ", you bring " .. share ..
        "   |   " .. (cap < 11 and ("this day: soldiers can reach level " .. cap) or "no level cap from here on"),
        x + 45, y + 72, w - 90, "left", nonoFont, LIGHT)
    local troops = type(p.deployedTroops) == "table" and p.deployedTroops or {}
    for k, pos in ipairs(campaign.PRIORITY) do
        local s = troops[pos]
        local col, row = (k - 1) % 2, math.floor((k - 1) / 2)
        local rx, ry = x + 45 + col * 330, y + 110 + row * 100
        if type(s) == "table" then
            local going = k <= share
            love.graphics.setColor(rgba(going and { 45, 45, 45 } or { 32, 32, 32 }))
            love.graphics.rectangle("fill", rx, ry, 310, 84)
            love.graphics.setColor(1, 1, 1, going and 1 or 0.55)
            profile.drawFace({ eyes = s.eyes, nose = s.nose, mouth = s.mouth, hair = s.hair }, rx + 8, ry + 8, 68)
            outlined(tostring(s.name or "?"), rx + 86, ry + 8, 220, "left", cardFont or nonoFont, going and WHITE or DIM)
            outlined("level " .. tostring(s.level or 1) .. "   " .. tostring(math.floor(tonumber(s.xp) or 0)) .. " XP",
                rx + 86, ry + 36, 220, "left", nonoFont, LIGHT)
            outlined(going and "GOING" or "HOME", rx + 86, ry + 58, 220, "left", nonoFont,
                going and { 115, 205, 90 } or DIM)
        end
    end
    outlined("Back", 50, 685, 100, "left", bigFont, hovered(32, 686, 80, 30) and RED or LIGHT)
    local armed = lobby.newWarArmed()
    outlined(armed and "Sure? Click again" or "New war", 1060, 685, 170, "right", bigFont,
        (armed or hovered(1060, 686, 170, 30)) and RED or DIM)
    local freshArmed = lobby.freshArmed()
    outlined(freshArmed and "Sure? Click again" or "Fresh start", 860, 685, 170, "right", bigFont,
        (freshArmed or hovered(860, 686, 170, 30)) and RED or DIM)
    love.graphics.setColor(1, 1, 1, 1)
end

function lobby.draw()
    if campaign.active and menuPage == lobby.hubPage then
        local ok, err = pcall(drawHub)
        if not ok then print("[mnb_coop] co-op page: " .. tostring(err)) end
    end
    if campaign.active and menuPage ~= lobby.page and menuPage ~= lobby.hubPage then
        -- a reminder on every campaign screen that this is the co-op profile
        -- one line: "CO-OP CAMPAIGN  |  6 soldiers, 3 each  |  own save, ..." (plain ASCII: game fonts)
        local n = coopSquadMax()
        local players = #campaign.owners()
        local title = "CO-OP CAMPAIGN"
        local rest = "  |  " .. n .. " soldiers" .. (players > 1 and (", " .. math.floor(n / players) .. " each") or "") ..
            "  |  own save, your campaign is untouched  |  Back: " ..
            (lobby.backPage() == lobby.page and "lobby" or "co-op page")
        if mnbCoop and mnbCoop.noticeText and love.timer.getTime() - (mnbCoop.noticeAt or 0) < 3 then
            rest = "  |  " .. mnbCoop.noticeText
        end
        local font = nonoFont or love.graphics.getFont()
        outlined(title, 30, 16, 400, "left", font, RED)
        outlined(rest, 30 + font:getWidth(title), 16, 600, "left", font, LIGHT)
        local pageLabel = campaign.squadPageLabel()
        if pageLabel then
            outlined(pageLabel, 150, 685, 230, "left", bigFont, hovered(150, 686, 230, 30) and RED or LIGHT)
        end
    end
    if menuPage == 1 and lobby.bottomX then
        local label = "Multiplayer"
        if net.role ~= "offline" then label = label .. " (" .. net.playerCount() .. "/" .. net.MAX_SEATS .. ")" end
        outlined(label, lobby.bottomX, 685, 300, "left", bigFont, hovered(lobby.bottomX, 686, 150, 30) and RED or LIGHT)
        return
    end
    if menuPage ~= lobby.page or not lobby.page then return end

    for i = 1, net.MAX_SEATS do drawSeat(i) end
    -- header line text, same place and style as the main menu's campaign date
    love.graphics.setFont(bigFont)
    love.graphics.setColor(rgba({ 120, 120, 120 }))
    love.graphics.print(headerText(), 30, 130)

    drawActions()
    drawCareerSquad()
    drawTile(580, 185, 200, 465, { 605, 210, 150, 360 }, campaingIcon1, "CO-OP CAMPAIGN", 590, true,
        campaign.hasSave() and "your war" or "new war")
    -- a friend doesn't do anything in Classic on their own (the host starts it): shown closed
    local canClassic = net.role == "host" or net.role == "offline"
    drawTile(805, 185, 200, 465, { 830, 210, 150, 360 }, classicIcon1, "CO-OP CLASSIC", 590, canClassic,
        canClassic and "defense" or "the host starts it")
    drawTile(1030, 185, 200, 465, { 1055, 210, 150, 360 }, optionsIcon1, "CO-OP OPTIONS", 600, true)
    drawConnection()

    outlined("Back", 50, 685, 100, "left", bigFont, hovered(32, 686, 80, 30) and RED or LIGHT)
    love.graphics.setColor(1, 1, 1, 1)
end

return lobby
