-- ============================================================================
-- AnimalSellRules.lua  (Animal Redux)
--
-- WHAT TO SELL, AND WHY. Layer 1 of three: this decides, persistence stores the
-- player's thresholds, and the executor carries it out. Both of those drive THIS,
-- so it is written to be pure and testable -- it reads the world and returns a
-- plan, and mutates nothing.
--
-- EVERY RULE HERE RESTS ON A MEASURED FACT (CLAUDE.md 11):
--   * value  = curve(ageMonths) x (0.40 + 0.60 x health).  Confirmed to 0.00000
--     across seven health points, and the age curve reproduced to the cent.
--   * THERE IS NO SEASONAL PRICE. "Sell at peak" means peak AGE, never peak
--     month, so nothing here waits for a market.
--   * a breeding cluster produces ONE OFFSPRING PER ANIMAL and DOUBLES.
--   * both breeding gates are cliffs: below minAgeMonth or below
--     minHealthFactor (0.75) nothing happens AND the counter is not advanced,
--     so a gated herd is frozen, not losing progress.
--   * A FULL PEN IS THE ONLY THING THAT DESTROYS ANYTHING. Births beyond the
--     free slots are discarded and the gestation is spent with them. Underfeeding
--     merely pauses.
--
-- THE RULE THAT FALLS OUT OF THAT, and it is not the one you would guess:
-- headroom outranks price. Selling below peak costs the DIFFERENCE; letting a
-- full pen breed costs whole animals plus a whole cycle. So a headroom sale is
-- allowed to lose money, and a peak sale never is.
--
-- PURE. No mutation, no money, no events, no GUI. Give it a placeable and a
-- config and it returns a plan; the caller decides whether to show it or do it.
-- ============================================================================

AnimalSellRules = {}

-- Deliberately conservative, and AUTO IS OFF. This module can propose selling a
-- player's herd; nothing acts on that until it is explicitly switched on.
AnimalSellRules.DEFAULTS = {
    enabled         = false,   -- auto-sell. OFF until the player says otherwise.
    keepFreeSlots   = -1,      -- -1 = derive it: enough for next cycle's births
    sellAtPeak      = true,    -- sell an animal that will only lose value from here
    minHealthToSell = 0.75,    -- do not realise a herd at 46% of book value
    keepBreeders    = 0,       -- never take the herd below this many breeding animals
}

AnimalSellRules.REASON_HEADROOM = "headroom"
AnimalSellRules.REASON_PEAK     = "peak"

-- ---------------------------------------------------------------------------
local function subTypeOf(sti)
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil or asys.getSubTypeByIndex == nil or sti == nil then return nil end
    local ok, st = pcall(asys.getSubTypeByIndex, asys, sti)
    if ok and type(st) == "table" then return st end
    return nil
end

local function priceOf(cl)
    if cl == nil or cl.getSellPrice == nil then return nil end
    local ok, v = pcall(cl.getSellPrice, cl)
    if ok and type(v) == "number" then return v end
    return nil
end

-- ---------------------------------------------------------------------------
-- THE PRICE CURVE, derived from the RUNNING GAME rather than from a table.
--
-- The shipped animals.xml carries every curve, but reading it at dev time is not
-- the same as knowing what THIS install is running: a map or a mod may replace
-- the definitions, and RealisticLivestock replaces the cluster class outright.
-- So the curve is measured, once per subtype, by asking a CLONE what it would be
-- worth at each age. That works for a modded animal nobody has ever seen.
--
-- CLONE ONLY, AND GATED. cluster:clone() is used exactly as arReproProbe uses
-- it, and for the same reason: a write to a live cluster would change the
-- player's herd. The gate proves the clone is independent before any sweep and
-- refuses everything if it is not -- a clone that forwards writes to the original
-- would silently age or re-price real animals.
local _curveCache = {}

function AnimalSellRules.cloneIsSafe(cl)
    if cl == nil or cl.clone == nil then return nil end
    local before = { n = cl.numAnimals, h = cl.health, a = cl.age }
    local ok, cp = pcall(cl.clone, cl)
    if not ok or type(cp) ~= "table" or cp == cl then return nil end

    -- THE CANARIES ARE DERIVED FROM THE CURRENT VALUES, never constants.
    -- With fixed canaries the gate has a blind spot that a harness found: a
    -- write-through clone leaves the ORIGINAL holding the canary values, so the
    -- NEXT call writes the same numbers, sees no change, and passes the very
    -- clone it just rejected. Offsetting from whatever the original holds now
    -- means the canary can never already be there.
    local wantAge, wantHealth = (before.a or 0) + 1000, (before.h or 0) + 1000
    pcall(function() cp.age, cp.health = wantAge, wantHealth end)
    if cp.age ~= wantAge or cp.health ~= wantHealth then return nil end   -- writes refused

    if cl.numAnimals ~= before.n or cl.health ~= before.h or cl.age ~= before.a then
        -- The write went THROUGH to the real cluster. Detecting that required
        -- making it happen, so put the original back before refusing: the gate
        -- must not itself be the thing that ages or re-prices a player's herd.
        pcall(function()
            cl.numAnimals, cl.health, cl.age = before.n, before.h, before.a
        end)
        return nil
    end
    return cp
end

---{ peakAge, priceAtPeak, priceAt(age), declines } for a subtype, cached.
-- Sampled at health 100 so the health term drops out and this is the raw curve.
function AnimalSellRules.priceCurve(cl)
    local sti = cl ~= nil and cl.subTypeIndex or nil
    if sti == nil then return nil end
    if _curveCache[sti] ~= nil then return _curveCache[sti] end

    local probe = AnimalSellRules.cloneIsSafe(cl)
    if probe == nil then return nil end

    local samples, peakAge, peakVal = {}, nil, nil
    for age = 0, 72, 3 do
        local c = nil
        local ok, cp = pcall(cl.clone, cl)
        if ok and type(cp) == "table" and cp ~= cl then c = cp end
        if c ~= nil then
            c.health, c.age = 100, age
            local p = priceOf(c)
            if p ~= nil then
                samples[#samples + 1] = { age = age, price = p }
                if peakVal == nil or p > peakVal then peakAge, peakVal = age, p end
            end
        end
    end
    if #samples < 2 then return nil end

    -- Does it DECLINE after the peak? Measured: only cows do. Asking the curve
    -- rather than the species means a modded animal answers for itself.
    local declines, worstAfter = false, peakVal
    for _, s in ipairs(samples) do
        if s.age > peakAge and s.price < worstAfter then
            worstAfter = s.price
            declines = true
        end
    end

    local curve = { samples = samples, peakAge = peakAge, peakPrice = peakVal,
                    declines = declines, lowestAfterPeak = worstAfter }
    _curveCache[sti] = curve
    return curve
end

---Forget the measured curves. Called when the world changes under us.
function AnimalSellRules.clearCache()
    _curveCache = {}
end

-- ---------------------------------------------------------------------------
---Everything the rules need about one barn, read live and mutating nothing.
function AnimalSellRules.assess(p)
    local out = { clusters = {}, animals = 0, capacity = 0, free = 0,
                  births = 0, breeders = 0, lost = 0, value = 0 }
    if p == nil or p.getClusters == nil then return out end

    local okC, clusters = pcall(p.getClusters, p)
    if not okC or type(clusters) ~= "table" then return out end

    local function num(fn, dflt)
        if p[fn] == nil then return dflt end
        local ok, v = pcall(p[fn], p)
        return (ok and type(v) == "number") and v or dflt
    end
    out.animals  = num("getNumOfAnimals", 0)
    out.capacity = num("getMaxNumOfAnimals", 0)
    out.free     = num("getNumOfFreeAnimalSlots", math.max(0, out.capacity - out.animals))

    local remaining = out.free
    for _, cl in pairs(clusters) do
        local n   = cl.numAnimals or 0
        local age = cl.age or 0
        local hp  = cl.health or 0
        local st  = subTypeOf(cl.subTypeIndex)
        local each = priceOf(cl)
        local curve = AnimalSellRules.priceCurve(cl)

        local minAge = st ~= nil and st.reproductionMinAgeMonth or nil
        local minH   = st ~= nil and st.reproductionMinHealth or nil
        local dur    = st ~= nil and st.reproductionDurationMonth or nil

        -- the gates, in the engine's own order (age, then health)
        local tooYoung = (minAge ~= nil and age < minAge)
        local unwell   = (not tooYoung) and (minH ~= nil and (hp / 100) < minH)
        local willBreed = not tooYoung and not unwell

        -- periods until this cluster births, on the measured counter model
        local due = nil
        if willBreed and dur ~= nil and dur > 0 then
            due = math.max(1, math.ceil((100 - (cl.reproduction or 0)) / (100 / dur)))
        end

        -- PAST PEAK: worth less later than now, so holding it costs money. Only
        -- meaningful on a curve that actually declines.
        local pastPeak = false
        if curve ~= nil and curve.declines and age >= curve.peakAge then pastPeak = true end
        local atPeak = (curve ~= nil and age >= curve.peakAge)

        local lost = 0
        if willBreed then
            out.births   = out.births + n
            out.breeders = out.breeders + n
            lost = math.max(0, n - remaining)
            remaining = math.max(0, remaining - n)
            out.lost = out.lost + lost
        end
        out.value = out.value + (each or 0) * n

        out.clusters[#out.clusters + 1] = {
            cluster = cl, subTypeIndex = cl.subTypeIndex,
            name = (st ~= nil and tostring(st.name) or "?"),
            count = n, age = age, healthPct = hp, each = each,
            total = (each ~= nil) and each * n or nil,
            willBreed = willBreed, tooYoung = tooYoung, unwell = unwell,
            dueInMonths = due, lostIfFull = lost,
            atPeak = atPeak, pastPeak = pastPeak,
            peakAge = curve ~= nil and curve.peakAge or nil,
            declines = curve ~= nil and curve.declines or false,
        }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- THE PLAN.
--
-- Two rules, and their PRECEDENCE is the whole design:
--
--   1. HEADROOM outranks everything, and is allowed to lose money. A full pen
--      destroys `numAnimals` offspring AND the whole gestation that made them,
--      every cycle, for as long as it stays full. Against that, selling a beast
--      a few months before its peak costs the difference and nothing else.
--
--   2. PEAK never loses money. An animal past the top of its curve is worth less
--      every month it is kept, so selling it is pure gain -- but only on a curve
--      that actually DECLINES, which measurement says is cows alone. On a flat
--      curve there is nothing to be early or late for and this rule stays silent.
--
-- The health floor suppresses (2) and NOT (1), which is the subtle part. Selling
-- a starving herd realises 46% of book value, so peak sales wait for feeding to
-- recover them. A headroom sale cannot wait: the calves are destroyed this cycle
-- whatever the price, so a low price is better than a total loss.
--
-- WHICH ANIMALS. Headroom takes from the clusters with the LEAST future in them
-- first -- past peak, then at peak, then oldest -- so the herd keeps the animals
-- that are still appreciating. Never below `keepBreeders`.
function AnimalSellRules.plan(p, cfg)
    cfg = cfg or {}
    local function opt(k)
        local v = cfg[k]
        if v == nil then return AnimalSellRules.DEFAULTS[k] end
        return v
    end

    local a = AnimalSellRules.assess(p)
    local plan = { lines = {}, total = 0, revenue = 0, assess = a, notes = {} }
    if #a.clusters == 0 then return plan end

    -- Notes carry DATA, never a sentence. This module is pure and has no business
    -- knowing what language the player reads: the GUI formats and localises. It
    -- also keeps the harness asserting on figures rather than on wording.
    local function note(kind, data)
        data = data or {}
        data.kind = kind
        plan.notes[#plan.notes + 1] = data
    end

    -- health floor: a herd this sick is worth 0.40 + 0.60h of book. Feeding it
    -- first is worth more than any peak sale, so peak sales stand down.
    local herdH = 0
    do
        local sum, cnt = 0, 0
        for _, c in ipairs(a.clusters) do sum = sum + c.healthPct * c.count; cnt = cnt + c.count end
        if cnt > 0 then herdH = (sum / cnt) / 100 end
    end
    local floor = opt("minHealthToSell")
    local tooSickToSell = (type(floor) == "number" and herdH < floor)

    -- how many slots the barn must have free. -1 derives it from the measured
    -- 1:1 doubling: next cycle needs one slot per breeding animal.
    local want = opt("keepFreeSlots")
    if type(want) ~= "number" or want < 0 then want = a.births end
    local needed = math.max(0, want - a.free)

    -- never take the herd below the breeder floor
    local keep = opt("keepBreeders") or 0
    local breederRoom = math.max(0, a.breeders - keep)

    -- ---- rank: least future first --------------------------------------
    local order = {}
    for _, c in ipairs(a.clusters) do order[#order + 1] = c end
    table.sort(order, function(x, y)
        if x.pastPeak ~= y.pastPeak then return x.pastPeak end       -- losing value now
        if x.atPeak ~= y.atPeak then return x.atPeak end             -- nothing left to gain
        if x.age ~= y.age then return x.age > y.age end              -- oldest first
        return tostring(x.name) < tostring(y.name)                   -- stable
    end)

    local function take(c, n, reason)
        if n <= 0 then return 0 end
        n = math.min(n, c.count)
        if n <= 0 then return 0 end
        plan.lines[#plan.lines + 1] = {
            cluster = c.cluster, name = c.name, count = n, reason = reason,
            each = c.each, revenue = (c.each or 0) * n,
            age = c.age, healthPct = c.healthPct,
        }
        plan.total = plan.total + n
        plan.revenue = plan.revenue + (c.each or 0) * n
        return n
    end

    -- ---- 1. HEADROOM ----------------------------------------------------
    local left = needed
    local budget = breederRoom
    if needed > 0 then
        for _, c in ipairs(order) do
            if left <= 0 then break end
            local allowed = c.willBreed and math.min(left, budget) or left
            local took = take(c, allowed, AnimalSellRules.REASON_HEADROOM)
            left = left - took
            if c.willBreed then budget = budget - took end
        end
        if left > 0 then note("blocked", { short = left, keepBreeders = keep }) end
    end

    -- ---- 2. PEAK --------------------------------------------------------
    if opt("sellAtPeak") then
        if tooSickToSell then
            note("held", { healthPct = math.floor(herdH * 100 + 0.5),
                           realisePct = math.floor((0.40 + 0.60 * herdH) * 100 + 0.5) })
        else
            local sold = {}
            for _, ln in ipairs(plan.lines) do sold[ln.cluster] = (sold[ln.cluster] or 0) + ln.count end
            for _, c in ipairs(order) do
                if c.pastPeak then
                    local free = c.count - (sold[c.cluster] or 0)
                    local allowed = c.willBreed and math.min(free, budget) or free
                    local took = take(c, allowed, AnimalSellRules.REASON_PEAK)
                    if c.willBreed then budget = budget - took end
                end
            end
        end
    end

    if a.lost > 0 and needed <= 0 then note("info", { lost = a.lost }) end
    return plan
end

---One line per reason, for a UI that wants to say WHY rather than list clusters.
function AnimalSellRules.summarise(plan)
    local by = {}
    for _, ln in ipairs(plan.lines or {}) do
        local e = by[ln.reason]
        if e == nil then e = { count = 0, revenue = 0 }; by[ln.reason] = e end
        e.count = e.count + ln.count
        e.revenue = e.revenue + (ln.revenue or 0)
    end
    return by
end
