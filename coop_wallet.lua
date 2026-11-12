-- =============================================================================
-- CO-OP CLASSIC WALLETS: every player has their own Tactical Points (TP)
-- Classic spends one pool, player.tp (cap 20 + ribbons, giveTp at mnb2.lua:894). With three
-- players that pool starves everyone, so in a co-op Classic battle with friends connected:
--   * the host's wallet IS player.tp, so all of the game's own code keeps working for him;
--   * a friend's wallet lives here, on the host, one number per seat;
--   * every income event (giveTp) adds the full amount to EVERY wallet, each with the game's
--     cap, and is not doubled (solo keeps the old doubled single pool, mnb_coop_main.lua);
--   * when the host replays a friend's order (coop_squad.lua), wallet.with swaps player.tp
--     to that friend's wallet for the call and stores the result back, whatever happens;
--   * the friend's window shows their own number: the host sends it ("wallet" message) and the
--     friend's mirror of `player` has its tp overwritten with it before every frame;
--   * G gives 5 TP to the next player (host decides; the friend only asks).
-- Direct income that does not go through giveTp (sitrep +5, directive TP Surge, a withdrawal
-- refund) is added by the game's own code: it goes to the wallet in player.tp at that moment,
-- which is the HOST's unless a friend's order is being replayed right then.
-- Wallets exist only for one battle (new battle = new troop list); nothing is saved.
-- =============================================================================
local net = require("includes/mods/mnb_coop/coop_net")

local wallet = {}

wallet.GIVE_AMOUNT = 5      -- TP moved by one press of G
wallet.GIVE_KEY = "g"       -- unused by the game (it uses 1-7, H, R, Tab, Space, F1-F9) and by the co-op
local GIVE_GAP = 0.5        -- seconds between two gives from one player
local DEFAULT_CAP = 20      -- the game's base cap, until giveTp has told us the real one

local wallets = {}          -- friends' wallets: seat -> TP (the host's is player.tp)
local lastSent = {}         -- seat -> the value that friend was last told
local lastGive = {}         -- seat -> time of their last give
local token = nil           -- identity of the battle (its troop list) the wallets belong to
local startTp = 0           -- what everyone began the battle with (the host's TP at the start)
local cap = DEFAULT_CAP     -- the game's tpMax, as the last giveTp left it
local swapped = nil         -- { seat, hostTp } while a friend's order runs

wallet.mine = nil           -- friend: my own TP as the host told me

local function inClassic()
    return type(player) == "table" and player.gameType == 1 and player.gameState == 0
end

-- true when wallets rule: hosting friends in a Classic battle
function wallet.active()
    return net.role == "host" and net.playerCount() > 1 and inClassic()
end

local function now()
    return love and love.timer and love.timer.getTime() or os.clock()
end

local function notify(seat, text)
    if seat == 1 then
        if mnbCoop and mnbCoop.notice then pcall(mnbCoop.notice, text) end
    else
        pcall(net.sendTo, seat, { t = "wallet", note = text })
    end
end

-- A new battle starts the wallets over; seats that came or went are handled here too.
-- Never call it while swapped (player.tp would be a friend's).
local function ensure()
    if swapped then return end
    local troops = player.deployedTroops
    if troops ~= token then
        token = troops
        wallets, lastSent, lastGive = {}, {}, {}
        startTp = tonumber(player.tp) or 0
        cap = DEFAULT_CAP
    end
    for s = 2, net.MAX_SEATS or 3 do
        if net.seats[s] then
            if wallets[s] == nil then wallets[s] = startTp end
        else
            wallets[s], lastSent[s], lastGive[s] = nil, nil, nil
        end
    end
end

-- TP of a seat right now
function wallet.get(seat)
    if not wallet.active() then return seat == 1 and (tonumber(player.tp) or 0) or nil end
    if swapped then
        if seat == swapped.seat then return tonumber(player.tp) or 0 end
        if seat == 1 then return swapped.hostTp end
    elseif seat == 1 then
        return tonumber(player.tp) or 0
    end
    return wallets[seat]
end

local function set(seat, v)
    if swapped then
        if seat == swapped.seat then player.tp = v return end
        if seat == 1 then swapped.hostTp = v return end
    elseif seat == 1 then
        player.tp = v
        return
    end
    wallets[seat] = v
end

-- Runs fn(...) as `seat`'s wallet: player.tp holds theirs for the call, and the host's own is
-- put back afterwards even if fn fails. Returns pcall's results. For the host, or when
-- wallets aren't active, it is just a protected call.
function wallet.with(seat, fn, ...)
    if not seat or seat == 1 or swapped or not wallet.active() then return pcall(fn, ...) end
    ensure()
    local p = player
    local hostTp = p.tp
    swapped = { seat = seat, hostTp = hostTp }
    p.tp = wallets[seat] or 0
    local ok, err = pcall(fn, ...)
    local mineNow = tonumber(p.tp)
    -- the friend's wallet keeps what is left; the host's comes back as the swap says
    -- (a giveTp inside the call may have raised it)
    if mineNow then wallets[seat] = mineNow end
    p.tp = swapped.hostTp
    swapped = nil
    return ok, err
end

-- The game's giveTp, wrapped (mnb_coop_main.lua): `orig` credits whatever wallet sits in
-- player.tp (its own cap and bookkeeping, once per event); everybody else's gets the same.
function wallet.giveTp(orig, nbr, ...)
    ensure()
    local result = orig(nbr, ...)
    if player.mnb2SubGame == 6 then return result end -- the game gives no TP there at all
    local limit = tonumber(rawget(_G, "tpMax")) -- (the game sets it inside giveTp)
    if limit then cap = limit end
    local inPocket = swapped and swapped.seat or 1
    local capped = player.mnb2SubGame ~= 8 -- trench mode has no cap
    local function add(seat)
        if seat == inPocket then return end
        local v = (wallet.get(seat) or 0) + nbr
        if capped and v > cap then v = cap end
        if v < 0 then v = 0 end
        set(seat, v)
    end
    add(1)
    for s = 2, net.MAX_SEATS or 3 do
        if net.seats[s] then add(s) end
    end
    return result
end

-- Host, every frame: tell each friend their TP when it changed.
function wallet.hostUpdate()
    if not wallet.active() then return end
    ensure()
    for s = 2, net.MAX_SEATS or 3 do
        local v = wallets[s]
        if net.seats[s] and v ~= nil and lastSent[s] ~= v then
            lastSent[s] = v
            pcall(net.sendTo, s, { t = "wallet", v = v })
        end
    end
end

function wallet.forgetSeat(seat)
    if seat then
        wallets[seat], lastSent[seat], lastGive[seat] = nil, nil, nil
    else
        wallets, lastSent, lastGive, token = {}, {}, {}, nil
    end
end

-- The next seat after `from` that has a player (round the table), or nil if alone.
local function nextSeat(from)
    local n = net.MAX_SEATS or 3
    for step = 1, n - 1 do
        local s = (from - 1 + step) % n + 1
        if net.seats[s] then return s end
    end
    return nil
end

-- Moves GIVE_AMOUNT TP (less if the giver has less, or the receiver's wallet is nearly
-- full) from `from` to the next player. Host only. Returns true if any TP moved.
function wallet.give(from)
    if not wallet.active() or swapped or not net.seats[from] then return false end
    ensure()
    local t = now()
    if lastGive[from] and t - lastGive[from] < GIVE_GAP then return false end
    lastGive[from] = t
    local to = nextSeat(from)
    if not to then return false end
    local have = math.floor(wallet.get(from) or 0)
    local theirs = wallet.get(to) or 0
    local room = math.floor(math.max(0, cap - theirs))
    local n = math.min(wallet.GIVE_AMOUNT, have, room)
    local giver, taker = net.seats[from].name or "A player", net.seats[to].name or "A player"
    if n <= 0 then
        notify(from, have <= 0 and "You have no TP to give" or (taker .. "'s TP is full"))
        return false
    end
    set(from, (wallet.get(from) or 0) - n)
    set(to, theirs + n)
    notify(from, string.format("You gave %d TP to %s", n, taker))
    notify(to, string.format("%s gave you %d TP", giver, n))
    return true
end

-- Host: a friend's message. Only "givetp" (no fields are read: the amount and the
-- receiver are the host's rules). Returns true if it is ours.
function wallet.onClientMessage(seat, msg)
    if msg.t ~= "givetp" then return false end
    pcall(wallet.give, seat)
    return true
end

-- Key G, in a Classic battle with wallets. Returns true if the key was used.
function wallet.keypressed(key)
    if key ~= wallet.GIVE_KEY or type(player) ~= "table" then return false end
    if net.role == "client" and mnbCoop and mnbCoop.battle and mnbCoop.battle.viewing and inClassic() then
        net.sendToHost({ t = "givetp" })
        return true
    end
    if wallet.active() then
        wallet.give(1)
        return true
    end
    return false
end

-- ---------------------------------------------------------------- friend side
-- Host → me: my wallet (and maybe a line to show).
function wallet.onHostMessage(msg)
    local v = tonumber(msg.v)
    if v and v == v and v > -1e6 and v < 1e6 then wallet.mine = v end
    if type(msg.note) == "string" and mnbCoop and mnbCoop.notice then
        pcall(mnbCoop.notice, (msg.note:gsub("[%c]", " "):sub(1, 80)))
    end
end

-- Friend, every frame while watching: my own TP replaces the host's in the mirror.
function wallet.clientApply()
    if wallet.mine ~= nil and type(player) == "table" and mnbCoop and mnbCoop.battle and mnbCoop.battle.viewing then
        player.tp = wallet.mine
    end
end

function wallet.clientReset()
    wallet.mine = nil
end

-- test helpers
function wallet.cap() return cap end

return wallet
