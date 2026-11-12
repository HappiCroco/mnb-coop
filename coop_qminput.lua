-- =============================================================================
-- CO-OP: GETTING ALONG WITH QUARTERMASTER'S OWN INPUT HANDLERS
-- QuarterMaster 1.8 (keybind menu) puts its own handlers in love.keypressed,
-- keyreleased, mousepressed and mousereleased (QM.Input.handle*), and installs
-- them a second time later, keeping whatever love.* holds at that moment as "the
-- function to call next" (QM.Input.orig*). If we replaced love.mousepressed in
-- between, its handler calls ours and ours calls its handler: an endless loop and
-- a stack overflow on the first click.
-- So while QM's handler is in front, we go in behind it (as the function it calls
-- next) and leave love.* pointing at QM; its second install then changes nothing.
-- Without QM 1.8 (QM 1.4, or tests) this is a plain wrap of love.*.
-- =============================================================================
local qmInput = {}

local NAMES = {
    keypressed = { "handleKeyPressed", "origKeyPressed" },
    keyreleased = { "handleKeyReleased", "origKeyReleased" },
    mousepressed = { "handleMousePressed", "origMousePressed" },
    mousereleased = { "handleMouseReleased", "origMouseReleased" },
}

local function qmTable()
    local qm = rawget(_G, "QM")
    local input = type(qm) == "table" and rawget(qm, "Input")
    if type(input) == "table" then return input end
end

-- Wraps love[name]: make(nextHandler) returns our handler, which passes on to nextHandler
-- (the game's, or whatever QM would have called). Returns nextHandler.
function qmInput.wrap(name, make)
    local input, names = qmTable(), NAMES[name]
    if input and names and input[names[1]] ~= nil and love[name] == input[names[1]] then
        local nextHandler = input[names[2]]
        input[names[2]] = make(nextHandler)
        return nextHandler
    end
    local nextHandler = love[name]
    love[name] = make(nextHandler)
    return nextHandler
end

return qmInput
