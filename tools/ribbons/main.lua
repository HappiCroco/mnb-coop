-- Co-op ribbon art generator. Renders each ribbon recipe to sprites/coop_rib<id>.png.
--   D:/Programming/LOVE/lovec.exe tools/ribbons [output dir]
-- (output dir defaults to the repo's sprites/ folder). Our own designs, in the game's ribbon
-- style (measured: 75x28, bands across, a sheen that is dark at the left/right ends and
-- brightest in the middle, 1 px dark dividers).
-- Drawn at S times the size (fine detail, a woven texture, a little noise), then every SxS
-- block is averaged down to one pixel, like a sprite drawn big and scaled down (owner's rule:
-- that's where the game's soft, slightly varied pixels come from).
-- The random seed is fixed, so the same recipes always give the same files.
local W, H, S = 75, 28, 4
local BW, BH = W * S, H * S

local OUT = arg and arg[2]
if not OUT or OUT == "" then OUT = love.filesystem.getSource() .. "/../../sprites" end
OUT = OUT:gsub("\\", "/"):gsub("/+$", "") .. "/"

local function rgb(h) return tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255 end

-- bands: { size in final pixels (fractions allowed), colour } top to bottom, adding up to H.
-- marks(u, v): u, v in final-pixel units (floats), returns a colour or nil, drawn over the bands.
local function ribbon(id, name, bands, marks)
  love.math.setRandomSeed(7 + id) -- same grain every run, and each ribbon its own
  local big = {}
  -- band per big row
  local rowColour = {}
  local y = 0
  for _, b in ipairs(bands) do
    local r, g, bl = rgb(b[2])
    local rows = math.floor(b[1] * S + 0.5)
    for _ = 1, rows do
      rowColour[y] = { r, g, bl }
      y = y + 1
    end
  end
  for yy = y, BH - 1 do rowColour[yy] = rowColour[y - 1] end
  for by = 0, BH - 1 do
    big[by] = {}
    for bx = 0, BW - 1 do
      local c = rowColour[by]
      local r, g, b = c[1], c[2], c[3]
      local u, v = (bx + 0.5) / S, (by + 0.5) / S
      if marks then
        local m = marks(u, v)
        if m then r, g, b = rgb(m) end
      end
      -- sheen across the width: 0.45 at the ends, 1.0 in the middle
      local t = math.abs(u / W - 0.5) * 2
      local s = 0.45 + 0.55 * (math.cos(t * math.pi / 2) ^ 0.8)
      -- woven fabric: fine diagonal threads, and a little grain
      local weave = 1 + 0.06 * math.sin((bx + by) * 1.9) + 0.04 * math.sin((bx - by) * 2.7)
      local grain = 1 + (love.math.random() - 0.5) * 0.10
      local k = s * weave * grain
      big[by][bx] = { r * k, g * k, b * k }
    end
  end
  -- average each SxS block into one pixel
  local d = love.image.newImageData(W, H)
  for y2 = 0, H - 1 do
    for x2 = 0, W - 1 do
      local r, g, b = 0, 0, 0
      for sy = 0, S - 1 do
        for sx = 0, S - 1 do
          local p = big[y2 * S + sy][x2 * S + sx]
          r, g, b = r + p[1], g + p[2], b + p[3]
        end
      end
      local n = S * S
      d:setPixel(x2, y2, math.min(1, r / n), math.min(1, g / n), math.min(1, b / n), 1)
    end
  end
  local file = "coop_rib" .. id .. ".png"
  local f = assert(io.open(OUT .. file, "wb"))
  f:write(d:encode("png"):getString())
  f:close()
  print("wrote " .. OUT .. file .. " (" .. name .. ")")
end

-- a five-pointed star centred at (cx, cy) with outer radius R (final-pixel units)
local function inStar(u, v, cx, cy, R)
  local dx, dy = u - cx, v - cy
  local a = math.atan2(dy, dx) + math.pi / 2
  local d = math.sqrt(dx * dx + dy * dy)
  local k = (a % (2 * math.pi / 5)) / (2 * math.pi / 5)
  local r = R * (0.45 + 0.55 * math.abs(k * 2 - 1))
  return d <= r
end

os.execute('mkdir "' .. OUT:gsub("/", "\\") .. '" 2>nul')

-- 203 Brothers in Arms: the three seat colours side by side in the middle, olive edges
ribbon(203, "Brothers in Arms", {
  { 4, "5a6b2e" }, { 1, "1e1e1e" }, { 6, "c23a3a" }, { 1, "1e1e1e" }, { 4, "3a6fc2" },
  { 1, "1e1e1e" }, { 6, "4f9e3a" }, { 1, "1e1e1e" }, { 4, "5a6b2e" } })

-- 201 Two-Front War: red top half, blue bottom half, a cream line between, and two small stars (two fronts)
ribbon(201, "Two-Front War", { { 3, "2b2b2b" }, { 9, "b83434" }, { 4, "f0e6c0" }, { 9, "3463b8" }, { 3, "2b2b2b" } },
  function(u, v)
    if inStar(u, v, 22, 14, 4.2) or inStar(u, v, 53, 14, 4.2) then return "f2d24a" end
  end)

-- 202 Hold the Line: dark green with a gold centre band and a radar dish in the middle
ribbon(202, "Hold the Line", { { 9, "2f4f2f" }, { 1, "111111" }, { 8, "d8b23a" }, { 1, "111111" }, { 9, "2f4f2f" } },
  function(u, v)
    local dx, dy = u - 37.5, v - 14
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= 6.6 then
      if d >= 5.5 then return "f8f0d0" end            -- the dish's rim
      if math.abs(d - 3.0) < 0.35 then return "6f8f5f" end -- a faint inner ring
      if math.abs(dx - dy * 0.7) < 0.5 and dx > 0 then return "f8f0d0" end -- the sweep line
      if d < 0.8 then return "f8f0d0" end              -- the centre
      return "1d2a1d"
    end
  end)

love.event.quit()
