-- =====================================================================
-- FLTHUD  ·  Analog telemetry HUD WIDGET for RadioMaster TX16S (EdgeTX)
-- ---------------------------------------------------------------------
-- Color-radio widget. Draws a 480x272 instrument panel scaled to fit
-- whatever zone it is placed in (full-screen layout recommended).
--   BATTERY gauge (right) · analog TIMER clock (left) · SIGNAL dial ·
--   trims · tiles · RQly link-quality alarm (vibrate + beep)
-- Install:  SD:/WIDGETS/FLTHD2/main.lua   (V2 "pit-wall" F1 render)
-- =====================================================================

local DEMO = false  -- true = animated preview, false = real telemetry (flip for flight)
local DEBUG_CELLS = false  -- true = show raw Cel1..n readings under the battery

-- low-battery alarm thresholds (volts per WEAKEST cell). Tune to taste.
local BATT_WARN = 3.65    -- "head back" alarm: two firm beeps + buzz, repeating
local BATT_CRIT = 3.50    -- "LAND NOW" alarm: urgent warbling screech + double buzz

-- RPM shift-light full-scale (redline). Set to your motor's FULL-THROTTLE reading
-- off the RPM readout. ESCs usually report ELECTRICAL rpm (Erpm = mechanical x
-- pole-pairs), so this is typically tens of thousands, not ~13500.
local RPM_DIV = 10      -- divide raw sensor rpm by this (pole-pairs/ratio) to show REAL rpm
local RPM_MAX = 8800    -- shift-strip redline = full-throttle rpm (displayed, after /RPM_DIV)

-- ---------- palette ----------
local BG    = lcd.RGB( 18,  20,  28)
local PANEL = lcd.RGB( 32,  36,  50)
local EDGE  = lcd.RGB( 60,  66,  84)
local TRK   = lcd.RGB( 24,  26,  34)
local FG    = lcd.RGB(235, 238, 245)
local MUT   = lcd.RGB(140, 150, 168)
local GOOD  = lcd.RGB( 64, 200, 120)
local WARN  = lcd.RGB(240, 185,  50)
local CRIT  = lcd.RGB(235,  72,  72)
local ACC   = lcd.RGB( 70, 150, 240)
local MAG   = lcd.RGB(210,  90, 220)
local CYAN   = lcd.RGB(  0, 225, 240)   -- V2 HUD accent
local VIOLET = lcd.RGB(176,  97, 255)   -- past-redline shift light

-- ---------- sensor name candidates ----------
local NAMES = {
  volt  = {"RxBt","RxV","VFAS","Cels","A1","Volt","Batt","Vbat"},
  pack  = {"Cels","VFAS","Volt"},
  rssi  = {"RQly","RQLY","1RSS","TQly","RxQ","RSSI","RSNR","SNR"},
  fadeA = {"FdeA","A"},   fadeB = {"FdeB","B"},
  fadeL = {"FdeL","L"},   fadeR = {"FdeR","R"},
  hold  = {"Hold","H"},
  loss  = {"Frame","FLss","F","Loss"},
  spd   = {"GSpd","ASpd","Spd"},
  alt   = {"Alt","GAlt","GPSAlt","GhAl"},
  dist  = {"Dist"},
  sats  = {"Sats"},
  curr  = {"Curr","Current","ECUR","BCur"},
  mah   = {"mAh","Fuel","Capa"},
  rpm   = {"RPM","Erpm"},
  temp  = {"TFET","BTmp","Tmp1","Temp","Tmp2"},
}

-- ---------- state ----------
local found, minV, maxHold, maxFade, hadTele = {}, nil, 0, 0, false
local lastTV, dirDown, lastLinkAlert = nil, false, 0
local lastHoldCount = 0
local teleWasLive = false   -- edge-detect a battery swap (telemetry reset -> fresh pack)
local lossRate, lossF, lossFT = 0, nil, nil   -- smoothed frame-loss rate (per sec)
-- derived pack-health metrics (computed from V + I; all optional/graceful)
local restV, peakW, irOhm, irCell, peakA = nil, 0, nil, nil, 0
local mahUsed, mahLastT = 0, nil          -- consumed capacity, integrated from current
local packMah, startMah = 0, nil          -- pack size (widget option) + mAh available at plug-in
local LINKQ = { RQly = true, RQLY = true, TQly = true, RxQ = true }

-- ---------- data helpers ----------
local function resolve(key)
  if found[key] then return found[key] end
  for _, n in ipairs(NAMES[key]) do
    if getFieldInfo(n) then found[key] = n; return n end
  end
  return nil
end

local function rawVal(key)
  local n = resolve(key); if not n then return nil end
  local v = getValue(n)
  if type(v) == "number" then return v end
  if type(v) == "table" and (key == "volt" or key == "pack") then
    local s = 0
    for _, cv in pairs(v) do if type(cv) == "number" then s = s + cv end end
    if s > 0 then return s end
  end
  return nil
end

local function demoVal(key)
  local t = getTime() / 100
  local c = t % 40
  if     key == "volt"  then return 16.8 - (c / 40) * 3.2
  elseif key == "rssi"  then return math.floor(88 + 9 * math.sin(t / 1.7))
  elseif key == "fadeA" then return math.floor(c / 6)
  elseif key == "fadeB" then return math.floor(c / 9)
  elseif key == "fadeL" then return math.floor(c / 7)
  elseif key == "fadeR" then return math.floor(c / 12)
  elseif key == "hold"  then return (c > 36) and 1 or 0
  elseif key == "loss"  then return math.floor(c / 15)
  elseif key == "spd"   then return 45 + 28 * math.sin(t / 3)
  elseif key == "alt"   then return 120 + 55 * math.sin(t / 5)
  elseif key == "curr"  then return 22 + 14 * math.sin(t)
  elseif key == "rpm"   then return math.floor(9000 + 4500 * math.sin(t))
  elseif key == "temp"  then return 38 + 18 * (c / 40)
  elseif key == "mah"   then return math.floor((c / 40) * 1400)
  elseif key == "sats"  then return 12
  end
  return nil
end

local function isDemo() return DEMO and not hadTele end
local function val(key) if isDemo() then return demoVal(key) end return rawVal(key) end
local function clampn(v, a, b) if v < a then return a elseif v > b then return b end return v end

local function cellCount(v)
  local best, bestd = 3, 99
  for _, c in ipairs({2, 3, 4, 6}) do
    local pc = v / c
    local d  = math.abs(pc - 3.85)
    if pc <= 4.25 and d < bestd then bestd = d; best = c end
  end
  return best
end

local function fmt1(v) return string.format("%.1f", v) end
local function fmt2(v) return string.format("%.2f", v) end

-- realistic LiPo state-of-charge from cell voltage. The real curve collapses
-- below ~3.8V, so a straight (v-3.3)/0.9 reads far too optimistic down low
-- (e.g. 3.73V -> 48% linear vs ~30% real). Piecewise curve, interpolated.
local SOC_V = {3.30, 3.50, 3.60, 3.70, 3.75, 3.80, 3.85, 3.90, 3.95, 4.00, 4.10, 4.20}
local SOC_P = {   0,    5,   12,   25,   33,   43,   55,   64,   72,   80,   92,  100}
local function lipoSoC(v)
  if v <= SOC_V[1] then return 0 end
  if v >= SOC_V[#SOC_V] then return 1 end
  for i = 2, #SOC_V do
    if v <= SOC_V[i] then
      local t = (v - SOC_V[i-1]) / (SOC_V[i] - SOC_V[i-1])
      return (SOC_P[i-1] + t * (SOC_P[i] - SOC_P[i-1])) / 100
    end
  end
  return 1
end

-- read individual cell sensors (SMART ESC/battery): pack V, cell count, lowest cell
local function readCells()
  local sum, mn, n = 0, 9, 0
  for i = 1, 6 do
    if getFieldInfo("Cel" .. i) then
      local cv = getValue("Cel" .. i)
      if type(cv) == "number" and cv > 2.0 then  -- real LiPo cell; ignore empty/phantom
        sum = sum + cv; n = n + 1
        if cv < mn then mn = cv end
      end
    end
  end
  if n > 0 then return sum, n, mn end
  return nil
end

-- per-cell voltages (SMART ESC Cel1..n), or a synthesized set in DEMO. nil = none.
local function cellArray()
  if isDemo() then
    local dv = demoVal("volt") / 4
    return { dv + 0.015, dv - 0.005, dv + 0.012, dv - 0.045 }
  end
  local t = {}
  for i = 1, 6 do
    if getFieldInfo("Cel" .. i) then
      local cv = getValue("Cel" .. i)
      if type(cv) == "number" and cv > 2.0 then t[#t + 1] = cv end
    end
  end
  if #t > 0 then return t end
  return nil
end

-- pick a signal sensor that actually has data (RQly is often stale-0 on Spektrum)
local SIGNAL_SENSORS = {
  { n = "RQly", pct = true },  { n = "RQLY", pct = true },
  { n = "TQly", pct = true },  { n = "RxQ",  pct = true },
  { n = "RSSI", pct = false }, { n = "TRSS", pct = false },
  { n = "RSNR", pct = false }, { n = "1RSS", pct = false },
}
local function readSignal()
  if isDemo() then return "RQly", demoVal("rssi"), true end
  local first
  for _, s in ipairs(SIGNAL_SENSORS) do
    if getFieldInfo(s.n) then
      local v = getValue(s.n)
      if type(v) == "number" then
        if not first then first = s end
        if v ~= 0 then return s.n, v, s.pct end   -- first one with live data
      end
    end
  end
  if first then return first.n, getValue(first.n), first.pct end
  return nil
end

-- Spektrum has no usable RSSI; derive live link health from the flight log.
-- Fresh each flight (RX counters reset on power-up). 100% = clean.
local LOSS_MAX = 6   -- frame-losses/second that pulls the needle to 0%
local function linkQuality()
  if not resolve("loss") then return nil end   -- matches Frame/FLss/F/Loss, not just "FLss"
  return 1 - clampn(lossRate / LOSS_MAX, 0, 1)
end

-- is telemetry actually flowing right now? (RX powered)
local function teleLive()
  local v = rawVal("volt")
  return v ~= nil and v > 0.5
end

-- ---------- zone transform: draw a 480x272 canvas scaled into any zone ----------
local Z = { ox = 0, oy = 0, s = 1 }
local function setZone(zx, zy, zw, zh)
  local s = math.min(zw / 480, zh / 272)
  Z.s  = s
  Z.ox = zx + (zw - 480 * s) / 2
  Z.oy = zy + (zh - 272 * s) / 2
end
local function TX(x) return math.floor(Z.ox + x * Z.s + 0.5) end
local function TY(y) return math.floor(Z.oy + y * Z.s + 0.5) end
local function TZ(v) return math.floor(v * Z.s + 0.5) end
local D = {}
function D.rect(x, y, w, h, c)      lcd.drawFilledRectangle(TX(x), TY(y), TZ(w), TZ(h), c) end
function D.frame(x, y, w, h, c)     lcd.drawRectangle(TX(x), TY(y), TZ(w), TZ(h), c) end
function D.text(x, y, t, f)         lcd.drawText(TX(x), TY(y), t, f) end
function D.line(x1, y1, x2, y2, c)  lcd.drawLine(TX(x1), TY(y1), TX(x2), TY(y2), SOLID, c) end

-- ---------- drawing primitives (all in 480x272 virtual space) ----------
local function panel(x, y, w, h, title)
  D.rect(x, y, w, h, PANEL)
  D.frame(x, y, w, h, EDGE)
  if title then D.text(x + 8, y + 5, title, SMLSIZE + MUT) end
end

local function spoke(cx, cy, ri, ro, ang, col)
  local r = math.rad(ang)
  local s, k = math.sin(r), math.cos(r)
  D.line(cx + ri * s, cy - ri * k, cx + ro * s, cy - ro * k, col)
end

local function needle(cx, cy, r0, r1, ang, col)
  spoke(cx, cy, r0, r1,     ang,       col)
  spoke(cx, cy, r0, r1 - 2, ang - 1.5, col)
  spoke(cx, cy, r0, r1 - 2, ang + 1.5, col)
  spoke(cx, cy, r0, r1 - 4, ang - 3.0, col)
  spoke(cx, cy, r0, r1 - 4, ang + 3.0, col)
end

local function hub(cx, cy, col) D.rect(cx - 3, cy - 3, 6, 6, col) end

local function ticks(cx, cy, ro, a0, span, n, me, col, mcol)
  for i = 0, n do
    local a = a0 + span * i / n
    if i % me == 0 then spoke(cx, cy, ro - 8, ro, a, mcol)
    else               spoke(cx, cy, ro - 4, ro, a, col) end
  end
end

local function zones(cx, cy, ro, a0, span)
  local a = a0
  while a <= a0 + span do
    local f = (a - a0) / span
    local c = (f < 0.30) and CRIT or (f < 0.55) and WARN or GOOD
    spoke(cx, cy, ro - 5, ro, a, c)
    a = a + 3
  end
end

-- ---------- trims ----------
local function getTrim(src)
  if isDemo() then
    local t = getTime() / 100
    if     src == "trim-ail" then return 0.5  * math.sin(t / 3)
    elseif src == "trim-ele" then return 0.35 * math.sin(t / 4 + 1)
    elseif src == "trim-rud" then return 0.25 * math.sin(t / 6 + 2)
    elseif src == "trim-thr" then return 0.15 * math.sin(t / 5)
    end
    return 0
  end
  local v = getValue(src)
  if type(v) ~= "number" then v = 0 end
  return clampn(v / 1024, -1, 1)   -- EdgeTX trim source swings ~+/-1024, not 125
end

-- graduation ticks as a fraction of full deflection (100% = the track ends),
-- mirrored on each side of center. CTRK = tight pair bracketing neutral so a
-- tiny trim off center is readable ("where the tab really is").
local TRIM_TICKS = {0.25, 0.50, 0.75, 1.00}
local CTRK = 6            -- px offset of the fine above/below-center bracket

local function trimV(x, y0, y1, v)
  local h, cym = y1 - y0, (y0 + y1) / 2
  local ht = h / 2 - 5                          -- half-travel px (= 100% deflection)
  D.rect(x, y0, 3, h, TRK)
  for _, f in ipairs(TRIM_TICKS) do             -- 25/50/75/100% graduations, both sides
    D.rect(x - 2, cym - f * ht, 7, 1, EDGE)
    D.rect(x - 2, cym + f * ht, 7, 1, EDGE)
  end
  D.rect(x - 1, cym - CTRK, 5, 1, MUT)          -- fine bracket just above center
  D.rect(x - 1, cym + CTRK, 5, 1, MUT)          -- ...and just below
  D.rect(x - 1, cym, 5, 1, EDGE)               -- neutral (0)
  D.rect(x - 2, cym - v * ht - 3, 7, 6, ACC)   -- moving marker
end

local function trimH(x0, x1, y, v)
  local w, cxm = x1 - x0, (x0 + x1) / 2
  local ht = w / 2 - 5                          -- half-travel px (= 100% deflection)
  D.rect(x0, y, w, 3, TRK)
  for _, f in ipairs(TRIM_TICKS) do             -- 25/50/75/100% graduations, both sides
    D.rect(cxm - f * ht, y - 2, 1, 7, EDGE)
    D.rect(cxm + f * ht, y - 2, 1, 7, EDGE)
  end
  D.rect(cxm - CTRK, y - 1, 1, 5, MUT)          -- fine bracket just left of center
  D.rect(cxm + CTRK, y - 1, 1, 5, MUT)          -- ...and just right
  D.rect(cxm, y - 1, 1, 5, EDGE)               -- neutral (0)
  D.rect(cxm + v * ht - 3, y - 2, 6, 7, ACC)   -- moving marker
end

local function drawTrims()
  trimV(1,   24, 244, getTrim("trim-thr"))
  trimV(476, 24, 244, getTrim("trim-ele"))
  trimH(40,  232, 250, getTrim("trim-rud"))
  trimH(248, 440, 250, getTrim("trim-ail"))
end

-- ---------- alarm + stats ----------
local LINK_WARN, LINK_CRIT = 50, 30
local function checkLinkAlarm()
  -- Spektrum: buzz whenever a NEW hold occurs (real link drop)
  local hd = val("hold")
  if hd then
    if hd > lastHoldCount then
      lastHoldCount = hd
      playHaptic(200, 0); playTone(250, 400, 0)
      return
    end
    lastHoldCount = hd
  end
  -- FlySky / working RQly: alarm on low link-quality %
  local sn, sv, spct = readSignal()
  if not sn or not spct then return end
  if not sv or sv <= 1 then return end
  local sev = (sv < LINK_CRIT) and 2 or (sv < LINK_WARN) and 1 or 0
  if sev == 0 then return end
  local now = getTime()
  if (now - lastLinkAlert) < 400 then return end
  lastLinkAlert = now
  playHaptic(sev == 2 and 200 or 90, 0)
  playTone(sev == 2 and 250 or 450, 300, 0)
end

-- escalating low-battery alarm off the weakest cell. Debounced so a throttle
-- punch (voltage sag) won't false-trigger.
local battAlarmT, battLowStart = 0, nil
local function checkBatteryAlarm()
  if not teleLive() then battLowStart = nil; return end
  local cell
  local _, _, minCell = readCells()
  if minCell then cell = minCell
  else
    local v = rawVal("volt")
    if v and v > 8.6 then cell = v / cellCount(v) end
  end
  if not cell then battLowStart = nil; return end
  if cell >= BATT_WARN then battLowStart = nil; return end
  local now = getTime()
  if battLowStart == nil then battLowStart = now; return end   -- must persist...
  if (now - battLowStart) < 150 then return end                -- ...~1.5s
  local crit = cell < BATT_CRIT
  if (now - battAlarmT) < (crit and 200 or 600) then return end
  battAlarmT = now
  if crit then                       -- urgent warbling screech + double buzz
    playHaptic(200, 0); playHaptic(200, 150)
    playTone(2700, 120, 40); playTone(1600, 120, 40)
    playTone(2700, 120, 40); playTone(1600, 220, 0)
  else                               -- warning: two firm beeps + buzz
    playHaptic(110, 0)
    playTone(2300, 110, 70); playTone(2300, 170, 0)
  end
end

-- power + pack internal-resistance, from SMART ESC voltage & current.
-- restV = highest pack voltage seen = open-circuit estimate; sag under load
-- gives IR = sag / current. Needs a current sensor; silently no-ops without one.
local function updatePower()
  local packV, ncell = readCells()
  if not packV then
    local v = val("volt")
    if v and v > 8.6 then packV = v; ncell = cellCount(v) end
  end
  if not packV or packV <= 0.5 then return end
  if not restV or packV > restV then restV = packV end
  local i = val("curr")
  if i and i > 0 then
    local w = packV * i
    if w > peakW then peakW = w end
    if i > peakA then peakA = i end
    if i > 4 then                                   -- enough load to read sag cleanly
      local sag = restV - packV; if sag < 0 then sag = 0 end
      local inst = sag / i                          -- ohms, whole pack
      irOhm = irOhm and (irOhm + (inst - irOhm) * 0.2) or inst   -- smoothed
      if ncell and ncell > 0 then irCell = irOhm / ncell end
    end
  end
end

-- clear all per-flight accumulators (fuel, peak power/current, IR, min-cell).
-- called on widget re-enter AND on a fresh-pack detection (battery swap).
local function resetFlightStats()
  minV, maxHold, maxFade, lossRate, lossF = nil, 0, 0, 0, nil
  restV, peakW, irOhm, irCell, peakA = nil, 0, nil, nil, 0
  mahUsed, mahLastT = 0, nil
  startMah = nil
  lastHoldCount = 0
end

local function updateStats()
  -- battery-swap auto-rebase: if telemetry dropped to nothing (e.g. the
  -- Reset-Telemetry switch wiped the stale sensors) and a fresh pack then comes
  -- online, clear carried-over fuel/peak/IR so the new pack starts clean and
  -- startMah re-captures with the CURRENT PackX100 setting. hadTele gate skips
  -- the very first power-up (nothing to rebase yet).
  local liveNow = teleLive()
  if liveNow and not teleWasLive and hadTele then resetFlightStats() end
  teleWasLive = liveNow
  updatePower()
  -- integrate current -> consumed mAh (for ESCs that report A but not capacity)
  local ci = val("curr")
  if ci and mahLastT then
    local dt = (getTime() - mahLastT) / 100          -- seconds
    if dt > 0 and dt < 5 then mahUsed = mahUsed + ci * dt / 3.6 end
  end
  mahLastT = ci and getTime() or nil
  -- capture starting capacity once: state-of-charge at plug-in x pack size
  if packMah > 0 and startMah == nil then
    local pvc, ncc = readCells()
    if not pvc then local vv = val("volt"); if vv and vv > 8.6 then pvc = vv; ncc = cellCount(vv) end end
    if pvc and ncc and ncc > 0 then startMah = lipoSoC(pvc / ncc) * packMah end
  end
  local rv = rawVal("volt")
  if rv and rv > 0.5 then hadTele = true end
  -- also wake on a live RF link (RSSI / link quality). Many planes report
  -- telemetry (and always RSSI) but have NO voltage sensor; without this the
  -- whole HUD stays blank on them, e.g. a bare FrSky RX with no FAS/FLVSS.
  local rq = rawVal("rssi")
  if rq and rq > 0 then hadTele = true end
  local v = val("volt")
  if v and v > 0.5 then if not minV or v < minV then minV = v end end
  local h = val("hold"); if h and h > maxHold then maxHold = h end
  local mf = math.max(val("fadeA") or 0, val("fadeB") or 0,
                      val("fadeL") or 0, val("fadeR") or 0)
  if mf > maxFade then maxFade = mf end

  -- live signal quality = smoothed FRAME-LOSS RATE (losses/sec). Near 0 when the
  -- link is good; climbs with range/obstruction; falls back when it recovers.
  local fnow = val("loss") or 0
  local tnow = getTime()
  if lossF == nil then lossF = fnow; lossFT = tnow end
  local dts = (tnow - lossFT) / 100
  if dts >= 0.3 then
    local dF = fnow - lossF
    if dF < 0 then dF = 0 end               -- counter reset on new flight
    lossRate = lossRate + (dF / dts - lossRate) * 0.5   -- smoothed
    lossF = fnow; lossFT = tnow
  end
  checkLinkAlarm()
  checkBatteryAlarm()
end

-- ---------- BATTERY ----------
local function drawBattery(x, y, w, h)
  local packV, ncell, minCell = readCells()
  local v, pct, col, sub, tag
  if packV then                              -- real per-cell data (SMART ESC)
    v = packV
    pct = (minCell - 3.30) / 0.90            -- health = weakest cell
    col = (minCell >= 3.70) and GOOD or (minCell >= 3.50) and WARN or CRIT
    sub = string.format("%dS  min %s", ncell, fmt2(minCell)); tag = "PACK"
  else
    v = val("volt") or 0
    if v > 8.6 then                          -- multi-cell from a single sensor
      local c = cellCount(v); local pc = v / c
      pct = (pc - 3.30) / 0.90
      col = (pc >= 3.70) and GOOD or (pc >= 3.50) and WARN or CRIT
      sub = string.format("%dS  %s V/c", c, fmt2(pc)); tag = "PACK"
    else                                     -- RX / BEC rail
      pct = (v - 4.5) / 2.0
      col = (v >= 4.95) and GOOD or (v >= 4.75) and WARN or CRIT
      sub = "RX / BEC rail"; tag = "BEC"
    end
  end
  panel(x, y, w, h, "BATTERY")
  D.text(x + w - 8, y + 5, tag, SMLSIZE + RIGHT + ACC)
  local cx, cy, ro = x + w / 2, y + 86, 80
  zones(cx, cy, ro, -135, 270)
  ticks(cx, cy, ro - 6, -135, 270, 10, 5, EDGE, MUT)
  needle(cx, cy, 5, ro - 12, -135 + 270 * clampn(pct, 0, 1), col)
  hub(cx, cy, FG)
  D.text(cx, cy + 22, fmt2(v) .. "V", DBLSIZE + CENTER + col)
  if DEBUG_CELLS then                            -- diagnostic: raw per-cell reads
    local parts = {}
    for i = 1, 6 do
      if getFieldInfo("Cel" .. i) then
        local cv = getValue("Cel" .. i)
        parts[#parts + 1] = (type(cv) == "number") and fmt1(cv) or "?"
      end
    end
    if #parts > 0 then sub = table.concat(parts, " ") end
  end
  D.text(cx, cy + 58, sub, SMLSIZE + CENTER + MUT)
  -- health strip: peak power (left) · internal resistance/cell (center) · min V (right)
  local hy = y + h - 9
  if peakW > 0 then D.text(x + 6, hy, "PK " .. math.floor(peakW) .. "W", SMLSIZE + MUT) end
  if irCell then D.text(cx, hy, "IR " .. math.floor(irCell * 1000) .. "mR", SMLSIZE + CENTER + MUT) end
  if minV then D.text(x + w - 6, hy, "min " .. fmt2(minV), SMLSIZE + RIGHT + MUT) end
end

-- ---------- TIMER clock ----------
local function drawTimer(x, y, w, h)
  local v, st
  if isDemo() then
    local t = getTime() / 100
    st = 90; v = math.floor(90 - (t % 110))
  else
    local tm = model.getTimer(0)
    v  = (tm and tm.value) or 0
    st = (tm and tm.start) or 0
  end
  if lastTV ~= nil then
    if v < lastTV - 0.5 then dirDown = true
    elseif v > lastTV + 0.5 then dirDown = false end
  end
  lastTV = v
  local isCd = (st > 0) or dirDown
  local av = math.abs(v)
  local mn, sc = math.floor(av / 60) % 60, av % 60
  local tstr = string.format("%s%d:%02d", v < 0 and "-" or "", math.floor(av / 60), av % 60)
  local dcol = FG
  if isCd then
    if     v <= 10 then dcol = CRIT
    elseif v <= 60 then dcol = WARN
    else                dcol = GOOD end
  end
  panel(x, y, w, h)
  D.text(x + 8, y + 5, "TIMER  " .. tstr, SMLSIZE + dcol)
  local cx, cy, ro = x + w / 2, y + 84, 66
  if isCd and v > 0 and v <= 60 then
    local a, aE = 0, 360 * (v / 60)
    while a <= aE do spoke(cx, cy, ro + 3, ro + 8, a, dcol); a = a + 3 end
  end
  for i = 0, 11 do spoke(cx, cy, ro - 7, ro, i * 30, (i % 3 == 0) and FG or MUT) end
  needle(cx, cy, 4, ro * 0.52, ((mn) + sc / 60) / 60 * 360, ACC)
  local as = (sc / 60) * 360
  spoke(cx, cy, 4, ro * 0.82, as,       CRIT)
  spoke(cx, cy, 4, ro * 0.82, as - 0.9, CRIT)
  spoke(cx, cy, 4, ro * 0.82, as + 0.9, CRIT)
  hub(cx, cy, FG)
  if isCd and v <= 60 then
    local big  = (v <= 10) and XXLSIZE or DBLSIZE
    local flag = (v <= 10) and BLINK or 0
    D.text(cx, cy - (v <= 10 and 16 or 11), tstr, big + CENTER + dcol + flag)
  end
end

-- ---------- bottom strip ----------
local function drawBottom(x, y, w, h)
  panel(x, y, w, h)
  -- LINK: analog needle driven by the receiver's own HOLD count (Spektrum),
  -- or by a real RSSI on radios that report one (FlySky). Full = clean.
  local sx, sy, sro = x + 40, y + 26, 20
  D.text(sx, y + 3, "LINK", SMLSIZE + CENTER + MUT)
  ticks(sx, sy, sro, -135, 270, 6, 3, EDGE, MUT)
  local sn, sv, spct = readSignal()
  local q
  if sn and sv and sv ~= 0 then                 -- live RSSI (e.g. FlySky)
    local p
    if spct then p = sv elseif sv < 0 then p = (sv + 100) / 70 * 100 else p = sv end
    q = clampn(p, 0, 100) / 100
  elseif teleLive() then
    q = linkQuality()                            -- Spektrum: frame-loss-rate quality
  end
  if q then
    local hd = math.floor(val("hold") or 0)
    local col = (q >= 0.55) and GOOD or (q >= 0.30) and WARN or CRIT
    if hd > 0 then col = CRIT end
    needle(sx, sy, 3, sro - 3, -135 + 270 * q, col)
    hub(sx, sy, FG)
    D.text(sx, y + h - 12, math.floor(q * 100) .. "%", SMLSIZE + CENTER + col)
  else
    hub(sx, sy, MUT)
    D.text(sx, y + h - 12, "--", SMLSIZE + CENTER + MUT)
  end

  local tiles = {}
  local function add(l, vv) tiles[#tiles + 1] = {l, vv} end
  local c  = val("curr"); if c then add("CUR", fmt1(c) .. "A") end
  if c then                                          -- live power = pack V x current
    local pv = (readCells()) or val("volt")
    if pv and pv > 5 then add("PWR", math.floor(pv * c) .. "W") end
  end
  local rp = val("rpm");  if rp and rp > 0 then add("RPM", tostring(math.floor(rp))) end
  local tp = val("temp"); if tp and tp > 0 then add("TEMP", math.floor(tp) .. "C") end
  local m  = val("mah");  if m then add("mAh", tostring(math.floor(m))) end
  local s  = val("spd");  if s then add("SPD", fmt1(s)) end
  local a  = val("alt");  if a then add("ALT", fmt1(a)) end
  add("MIN V", minV and fmt2(minV) or "--")
  add("MAX HOLD", tostring(math.floor(maxHold)))
  local x0 = x + 84
  local n  = math.min(4, #tiles)
  local gw = ((x + w) - x0) / n
  for i = 1, n do
    local tx = x0 + (i - 1) * gw
    D.text(tx + 6, y + 8,  tiles[i][1], SMLSIZE + MUT)
    D.text(tx + 6, y + 26, tiles[i][2], MIDSIZE + FG)
  end
end

local function drawHeader()
  D.rect(0, 0, 480, 17, PANEL)
  local name = model.getInfo().name
  if name == "" then name = "TELEMETRY HUD" end
  D.text(8, 4, name, SMLSIZE + FG)
  if isDemo() then
    D.rect(480 - 90, 2, 44, 13, MAG)
    D.text(480 - 68, 3, "DEMO", SMLSIZE + CENTER + FG)
  end
  local tele = val("volt")
  local live = tele and tele > 0.5
  D.rect(480 - 14, 5, 8, 8, live and GOOD or (hadTele and CRIT or MUT))
end

local function drawBanner()
  local hold = val("hold") or 0
  local packV, ncell, minCell = readCells()
  local v = packV or (val("volt") or 0)
  local isPack = packV ~= nil or v > 8.6
  local brown  = (not isPack) and v > 0.5 and v < 4.75
  local low
  if packV then low = minCell < BATT_CRIT
  else low = isPack and v > 0.5 and (v / cellCount(v)) < BATT_CRIT end
  local lost = hadTele and v <= 0.5
  local msg
  if lost         then msg = "! TELEMETRY LOST !"
  elseif hold > 0 then msg = "! LINK HOLD x" .. math.floor(hold) .. " !"
  elseif brown    then msg = "! BEC LOW / BROWNOUT RISK !"
  elseif low      then msg = "! PACK VOLTAGE LOW !"
  end
  if msg then
    D.rect(0, 272 - 16, 480, 16, CRIT)
    D.text(240, 272 - 15, msg, SMLSIZE + CENTER + FG + BLINK)
  end
end

-- ===================== V2 "PIT-WALL" RENDER =====================
-- RPM shift-light strip: green -> amber -> red -> violet, redline at the top
local function drawShift(rpm, rmax)
  local x0, y0, w, h, n, gap = 6, 3, 468, 14, 16, 2
  local sw = (w - gap * (n - 1)) / n
  local lit = math.floor(clampn((rpm or 0) / rmax, 0, 1) * n + 0.5)
  for i = 0, n - 1 do
    local col = (i >= 15) and VIOLET or (i >= 13) and CRIT or (i >= 9) and WARN or GOOD
    D.rect(x0 + i * (sw + gap), y0, sw, h, (i < lit) and col or TRK)
  end
end

-- slim top status: flight timer (left), model name + telemetry dot (right), DEMO badge
local function drawStatus()
  local secs
  if isDemo() then secs = math.floor(getTime() / 100) % 3600
  else local tm = model.getTimer(0); secs = math.abs((tm and tm.value) or 0) end
  D.text(8, 21, string.format("T %d:%02d", math.floor(secs / 60), secs % 60), SMLSIZE + FG)
  local rx = 474
  local tele = val("volt"); local live = tele and tele > 0.5
  if isDemo() then D.rect(rx - 40, 20, 40, 13, MAG); D.text(rx - 20, 21, "DEMO", SMLSIZE + CENTER + FG); rx = rx - 46 end
  D.rect(rx - 8, 23, 7, 7, live and GOOD or (hadTele and CRIT or MUT))
  local nm = model.getInfo().name; if nm == "" then nm = "FLTHD2" end
  D.text(rx - 14, 21, nm, SMLSIZE + RIGHT + MUT)
end

-- vertical segmented rail (battery / link), value below
local function drawRail(x, y, w, h, frac, col, label, valstr)
  D.text(x + w / 2, y - 13, label, SMLSIZE + CENTER + MUT)
  local n, gap = 10, 2
  local ch = (h - gap * (n - 1)) / n
  local lit = math.floor(clampn(frac, 0, 1) * n + 0.5)
  for i = 0, n - 1 do
    D.rect(x, y + h - (i + 1) * ch - i * gap, w, ch, (i < lit) and col or TRK)
  end
  D.text(x + w / 2, y + h + 2, valstr, SMLSIZE + CENTER + col)
end

-- analog needle gauge with the value digital below (label above)
local function gauge(cx, cy, r, frac, label, valstr, col)
  local alert = (col == WARN or col == CRIT)          -- out-of-whack: light the whole gauge up
  ticks(cx, cy, r, -135, 270, 10, 2, alert and col or EDGE, alert and col or MUT)
  needle(cx, cy, 3, r - 4, -135 + 270 * clampn(frac, 0, 1), col)
  hub(cx, cy, alert and col or FG)
  D.text(cx, cy - r - 19, label, SMLSIZE + CENTER + (alert and col or MUT))
  D.text(cx, cy + r + 2, valstr, SMLSIZE + CENTER + (alert and col or FG))
end

local function drawFull()
  D.rect(0, 0, 480, 272, BG)
  local rpm = val("rpm"); if rpm then rpm = rpm / RPM_DIV end
  drawShift(rpm, RPM_MAX)
  -- RPM readout (small, far left)
  local rlit = (rpm or 0) >= RPM_MAX * 0.9
  D.text(6, 19, "RPM", SMLSIZE + (rlit and VIOLET or CYAN))
  D.text(36, 19, rpm and tostring(math.floor(rpm)) or "----", SMLSIZE + FG)
  local rx = 474
  local tdot = val("volt"); local live = tdot and tdot > 0.5
  D.rect(rx - 8, 23, 7, 7, live and GOOD or (hadTele and CRIT or MUT))
  local nm = model.getInfo().name; if nm == "" then nm = "FLTHD2" end
  D.text(rx - 14, 21, nm, SMLSIZE + RIGHT + MUT)
  -- confirm the pack size the fuel gauge is using (setting is x100, this shows real mAh).
  -- Only once a real pack is detected (startMah captured) -- no battery => nothing to confirm.
  if packMah > 0 and startMah and teleLive() then D.text(200, 19, "PACK  " .. math.floor(packMah / 100) .. " = " .. packMah .. " mAh", SMLSIZE + CENTER + FG) end

  local packV, ncell, minCell = readCells()
  local pv = packV or val("volt")
  local n  = ncell or (pv and pv > 8.6 and cellCount(pv)) or nil

  -- HERO pair: AMPS (load right now) + mAh USED (fuel burned), side by side
  local amps = val("curr")
  D.text(100, 46, amps and tostring(math.floor(amps + 0.5)) or "--", DBLSIZE + CENTER + CYAN)
  D.text(100, 78, "AMPS", SMLSIZE + CENTER + MUT)
  -- mAh: counts DOWN as "LEFT" when a pack size is set, else UP as "USED"
  local mah = val("mah"); if not mah and mahUsed > 0 then mah = mahUsed end
  local mtxt, mlbl, mcol = (mah and tostring(math.floor(mah)) or "0"), "mAh USED", CYAN
  if packMah > 0 and startMah and teleLive() then      -- only while a real pack is actually live
    local rem = startMah - mahUsed; if rem < 0 then rem = 0 end
    mtxt = tostring(math.floor(rem)); mlbl = "mAh LEFT"
    local f = rem / packMah                            -- % of FULL pack, not of plug-in charge
    mcol = (f <= 0.15) and CRIT or (f <= 0.30) and WARN or CYAN
  end
  D.text(198, 46, mtxt, DBLSIZE + CENTER + mcol)
  D.text(198, 78, mlbl, SMLSIZE + CENTER + MUT)
  local sub = (pv and pv > 5) and (minCell and (fmt2(pv) .. "V min " .. fmt2(minCell)) or (fmt2(pv) .. "V")) or "no pack"
  D.text(150, 96, sub, SMLSIZE + CENTER + FG)

  -- COUNTDOWN clock (shifted right) -- keeps counting negative past zero
  local cd
  if isDemo() then cd = 150 - (math.floor(getTime() / 100) % 260)
  else local ct = model.getTimer(0); cd = (ct and ct.value) or 0 end
  local ca = math.abs(cd)
  local cstr = string.format("%s%d:%02d", cd < 0 and "-" or "", math.floor(ca / 60), ca % 60)
  local ccol = (cd <= 0) and CRIT or (cd <= 30) and WARN or FG
  D.text(305, 44, cstr, XXLSIZE + CENTER + ccol)
  D.text(305, 106, "TIMER", SMLSIZE + CENTER + MUT)

  -- BATTERY rail (left, wider)
  local bf, bc, bv
  if minCell then bf = lipoSoC(minCell); bc = (minCell>=3.7) and GOOD or (minCell>=3.5) and WARN or CRIT; bv = math.floor(clampn(bf,0,1)*100) .. "%"
  elseif pv and pv > 8.6 then local pc = pv/n; bf = lipoSoC(pc); bc = (pc>=3.7) and GOOD or (pc>=3.5) and WARN or CRIT; bv = math.floor(clampn(bf,0,1)*100) .. "%"
  elseif pv and pv > 0.5 then bf = (pv-4.5)/2.0; bc = (pv>=4.95) and GOOD or (pv>=4.75) and WARN or CRIT; bv = fmt1(pv) .. "V"
  else bf, bc, bv = 0, MUT, "--" end
  drawRail(8, 64, 40, 48, bf, bc, "BAT", bv)

  -- LINK rail (right). NO telemetry (no battery / RX off) => dead link, "--" grey.
  -- Only once telemetry is actually flowing: Spektrum uses the frame-loss proxy,
  -- FrSky/FlySky use real RSSI/RQly. So it goes live the moment a battery is in.
  local q, lv
  if teleLive() then                                   -- telemetry actually arriving
    local fl = linkQuality()                           -- frame-loss rate (Spektrum)
    if fl then
      q = fl; lv = math.floor(q*100) .. "%"
    else
      local sn, sv, spct = readSignal()
      if sn and sv and sv ~= 0 then                    -- real RSSI/RQly (FrSky/FlySky)
        local p; if spct then p = sv elseif sv < 0 then p = (sv+100)/70*100 else p = sv end
        q = clampn(p,0,100)/100; lv = math.floor(q*100) .. "%"
      else
        q = 1; lv = "OK"                               -- live telem, no signal metric
      end
    end
  end
  local lc
  if q then lc = (q>=0.55) and GOOD or (q>=0.30) and WARN or CRIT else lc, lv, q = MUT, "--", 0 end
  drawRail(432, 64, 40, 48, q, lc, "SIGNAL", lv)

  -- per-cell row (SMART ESC / demo); auto-hides when absent
  local cells = cellArray()
  local hasCells = cells ~= nil
  if hasCells then
    local cn = #cells; local cw = 468 / cn
    for i = 1, cn do
      local ccx = 6 + (i - 1) * cw
      local cv = cells[i]
      local hc = (cv >= 3.75) and GOOD or (cv >= 3.55) and WARN or CRIT
      panel(ccx + 2, 138, cw - 4, 28)
      D.text(ccx + 8, 140, "C" .. i, SMLSIZE + MUT)
      D.text(ccx + cw - 8, 143, fmt2(cv), SMLSIZE + RIGHT + hc)
      D.rect(ccx + 7, 159, (cw - 14) * clampn((cv-3.3)/0.9, 0, 1), 4, hc)
    end
  end

  -- gauge cluster: 6 analog needle gauges
  local gy  = hasCells and 182 or 162
  local gcy = gy + 30
  local function G(idx, label, frac, valstr, col) gauge(40 + idx * 80, gcy, 21, frac, label, valstr, col) end
  if pv and pv > 0.5 and n then
    G(0, "VOLT", (pv-3.3*n)/(0.9*n), fmt1(pv), (minCell and ((minCell>=3.7) and GOOD or (minCell>=3.5) and WARN or CRIT)) or CYAN)
  elseif pv then G(0, "VOLT", (pv-4.5)/2.0, fmt1(pv), CYAN)
  else G(0, "VOLT", 0, "--", MUT) end
  if hasCells and #cells > 1 then                      -- cell balance = high-low cell spread (mV)
    local mx, mn = 0, 9; for _, c in ipairs(cells) do if c > mx then mx = c end; if c < mn then mn = c end end
    local imb = math.floor((mx - mn) * 1000)
    G(1, "BAL", imb/150, imb .. "", (imb>80) and CRIT or (imb>40) and WARN or CYAN)
  else G(1, "BAL", 0, "--", MUT) end
  local tp = val("temp")
  if tp and tp > 0 then G(2, "TEMP", (tp-20)/70, math.floor(tp) .. "", (tp>70) and CRIT or (tp>55) and WARN or CYAN)
  else G(2, "TEMP", 0, "--", MUT) end
  -- mAh gauge: fuel-gauge needle -- remaining (sweeps down) if a pack size is set, else used
  if packMah > 0 and startMah and teleLive() then      -- only while a real pack is actually live
    local rem = startMah - mahUsed; if rem < 0 then rem = 0 end
    local f = rem / packMah                            -- % of FULL pack capacity
    G(3, "mAh", f, tostring(math.floor(rem)), (f <= 0.15) and CRIT or (f <= 0.30) and WARN or CYAN)
  else
    local m3 = val("mah"); if not m3 and mahUsed > 0 then m3 = mahUsed end
    if m3 then G(3, "mAh", m3 / 2000, tostring(math.floor(m3)), CYAN) else G(3, "mAh", 0, "--", MUT) end
  end
  if peakA and peakA > 0 then G(4, "PK A", peakA/60, tostring(math.floor(peakA + 0.5)), CYAN) else G(4, "PK A", 0, "--", MUT) end
  if irCell and irCell > 0 then                        -- IR/cell (mOhm) = cell health; climbs as cells age/fail
    local mr = math.floor(irCell * 1000 + 0.5)
    G(5, "HEALTH", mr / 30, mr .. "", (mr > 15) and CRIT or (mr > 9) and WARN or CYAN)
  else G(5, "HEALTH", 0, "--", MUT) end

  drawTrims()
  drawBanner()
end

local function drawCompact(z)
  lcd.drawFilledRectangle(z.x, z.y, z.w, z.h, PANEL)
  lcd.drawRectangle(z.x, z.y, z.w, z.h, EDGE)
  local v = val("volt")
  local r = val("rssi")
  lcd.drawText(z.x + 6, z.y + 4, "BATT", SMLSIZE + MUT)
  lcd.drawText(z.x + 6, z.y + 16, v and (fmt2(v) .. "V") or "--", DBLSIZE + FG)
  lcd.drawText(z.x + z.w - 6, z.y + 4, "LINK", SMLSIZE + RIGHT + MUT)
  local rtxt = "--"
  if r then rtxt = (r < 0) and (math.floor(r) .. "dB") or (math.floor(r) .. "%") end
  lcd.drawText(z.x + z.w - 6, z.y + 16, rtxt, DBLSIZE + RIGHT + FG)
  local tm = model.getTimer(0)
  local secs = math.abs((tm and tm.value) or 0)
  lcd.drawText(z.x + 6, z.y + z.h - 16,
    string.format("T %d:%02d", math.floor(secs / 60), secs % 60), SMLSIZE + FG)
end

-- ---------- widget interface ----------
local function create(zone, options) return { zone = zone, options = options } end
local function update(w, options) w.options = options end
local function readPack(w)
  local pm = w and w.options and w.options.PackX100      -- pack size in units of 100 mAh
  packMah = (type(pm) == "number" and pm > 0) and pm * 100 or 0
end

local function background(w) readPack(w); updateStats() end

local function refresh(w, event, touchState)
  readPack(w)
  updateStats()
  local z = w.zone
  if z.w >= 300 and z.h >= 150 then
    setZone(z.x, z.y, z.w, z.h)
    lcd.drawFilledRectangle(z.x, z.y, z.w, z.h, BG)
    if event == EVT_VIRTUAL_ENTER then resetFlightStats() end
    drawFull()
  else
    drawCompact(z)
  end
end

return { name = "FLTHD2", options = { { "PackX100", VALUE, 0, 0, 99 } }, create = create,
         update = update, refresh = refresh, background = background }
