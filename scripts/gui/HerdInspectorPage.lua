-- ============================================================================
-- HerdInspectorPage.lua  (Animal Redux) -- the second Animals tab
--
-- A SECOND tab beside the existing one, not a replacement. Both load, both work,
-- and the old one is deleted only once this has earned it -- which is the whole
-- point: the comparison is the acceptance test, so breaking the baseline would
-- defeat it. Nothing here writes to the old page.
--
-- TWO VIEWS.
--   GROUPS  every animal group on the farm, filtered by animal type. Full width,
--           no barn list: the BARN column already says where each group is, and
--           the list would cost 370px to repeat it.
--   BARN    the barn list on the left; on the right a summary strip across the
--           top, then the barn's groups beside its feed and production.
--
-- A CLUSTER IS THE UNIT THE GAME THINKS IN. Every recommendation the sell rules
-- make acts on one, so a screen that only ever shows barn totals is a screen you
-- cannot check the recommendations against. 10.3 measured a horse barn as 16
-- clusters of ONE animal -- which is also why the type filter is not a
-- convenience: unfiltered, this farm is 18 rows and 16 of them are horses.
--
-- L/DAY IS THE COLUMN THAT IS NEW, and it is the reason for the tab. 14.4
-- measured every output as age-curved and matched the live spec on 17 rows of
-- 17: milk is a CLIFF at 12 months, manure and slurry RAMP FROM BIRTH. So a
-- young group reports an honest zero for milk while still making manure, which
-- no current screen says.
--
-- THE CLASS IS BUILT AT INSTALL TIME, not at chunk load: it extends DR's
-- DistributionMenuPage and DR's environment does not exist when this file is
-- sourced (mods load alphabetically and FS25_Animal_Redux comes first). Methods
-- are defined on a plain table here; the inheritance is wired in install().
-- ============================================================================

HerdInspectorPage = {}

HerdInspectorPage.VIEW_GROUPS, HerdInspectorPage.VIEW_BARN = 1, 2
---THE THIRD VIEW: what this barn keeps each BREED for. It shares the barn list
-- with VIEW_BARN, because a purpose is per (barn, breed) and the barn has to be
-- chosen before the question means anything (29.1).
HerdInspectorPage.VIEW_BREEDS = 3

---EVERY LIST ON THE PAGE, and the subset that depends on WHICH BARN is selected.
--
-- NAMED BECAUSE THE LITERALS DRIFTED TWICE IN ONE BUILD. Adding the breed list
-- meant adding its id to five separate hand-written lists, and two were missed:
-- one bound every list's data source (so the new list had none) and one reloaded
-- the right-hand panes after a barn was clicked (so the new list did not refresh
-- until the next PACED tick, reported as "it takes a few seconds"). Neither
-- errored; both simply did nothing.
HerdInspectorPage.LIST_IDS = { "groupList", "barnList", "barnGroupList",
                               "inputList", "prodList", "breedList" }
---The panes that answer for the SELECTED barn. barnList is excluded deliberately:
-- it is the list being clicked, and reloading a list inside its own selection
-- callback is how a selection gets reset out from under the player.
HerdInspectorPage.DETAIL_LISTS = { "barnGroupList", "inputList", "prodList", "breedList" }

-- ---------------------------------------------------------------------------
-- THE TIMESCALE.
--
-- Every rate on this page is stored in its NATURAL unit -- the feed and output
-- tables per HOUR, the value-change column per MONTH, because that is what the
-- price curve's three-month sampling can honestly resolve -- and scaled only at
-- render time. So changing the period is a repopulate, never a rebuild, and the
-- row data never carries a unit that depends on a widget.
--
-- A CYCLE IS ONE IN-GAME HOUR: that is DR's own word for one hourly allocation
-- pass, which is the granularity everything here is actually computed at.
-- A MONTH is 24 x daysPerPeriod hours, read from the environment rather than
-- assumed, and a YEAR is twelve of them.
--
-- THE COLUMN HEADERS CARRY NO UNIT (DR 5.11 dropped its own "/mo" suffixes for
-- exactly this reason): one legend at the top of the page beats eight headers
-- that would have to be re-tiled every time the period changed, and re-tiling
-- hand-pitched columns is where 5.55's truncation bug came from.
HerdInspectorPage.PERIOD_CYCLE, HerdInspectorPage.PERIOD_MONTH, HerdInspectorPage.PERIOD_YEAR = 1, 2, 3
-- The profit key is STORED, not composed from `key`. A key built at runtime is
-- invisible to tools/check_l10n_animal.py, which is the only thing that would ever
-- notice one of these going missing -- and a missing key renders as a raw
-- "$l10n_..." on screen with nothing in the log (5.60).
HerdInspectorPage.PERIODS = {
    { key = "cycle", label = "ar_hi_per_cycle", fallback = "PER: CYCLE (1 HOUR)",
      profit = "ar_hi_profit_cycle", profitFallback = "PROFIT / CYCLE" },
    { key = "month", label = "ar_hi_per_month", fallback = "PER: MONTH",
      profit = "ar_hi_profit_month", profitFallback = "PROFIT / MO" },
    { key = "year",  label = "ar_hi_per_year",  fallback = "PER: YEAR",
      profit = "ar_hi_profit_year",  profitFallback = "PROFIT / YR" },
}

-- ---------------------------------------------------------------------------
local function l10n(key, fallback)
    if AnimalRedux ~= nil and AnimalRedux.l10n ~= nil then return AnimalRedux.l10n(key, fallback) end
    return fallback
end

---Volumes through DR's own formatter, so this tab reads like every other one.
local function vol(v)
    local SD = AnimalRedux ~= nil and AnimalRedux.DR or nil
    if SD ~= nil and SD.formatVolume ~= nil then
        local ok, s = pcall(SD.formatVolume, v)
        if ok and s ~= nil then return s end
    end
    return string.format("%d L", math.floor((v or 0) + 0.5))
end

---A fill type's DISPLAY title, not its internal name.
local function ftTitle(ft)
    if ft == nil then return "?" end
    local m = g_fillTypeManager
    if m ~= nil and m.getFillTypeTitleByIndex ~= nil then
        local ok, t = pcall(m.getFillTypeTitleByIndex, m, ft)
        if ok and t ~= nil then return tostring(t) end
    end
    return "?"
end

-- `signedVol` LIVED HERE AND IS GONE with the two CHANGE columns it formatted.
-- Verified callerless before deleting rather than assumed (6.27).

local function money(v)
    if v == nil then return "-" end
    local places = (v ~= 0 and math.abs(v) < 10) and 2 or 0
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, s = pcall(g_i18n.formatMoney, g_i18n, v, places, true, true)
        if ok and s ~= nil then return tostring(s) end
    end
    return string.format("%." .. places .. "f", v)
end

---ALL FOUR COLOURS, never setTextColor alone. TextElement:getColor prefers the
-- selected / focused colours whenever the row is in those states, so a status
-- colour written only to `textColor` is silently discarded on the selected row --
-- which on a fresh list is row 1 (DR 5.77b, and 16.6 here).
local function setColour(cell, tone)
    if cell == nil or cell.setTextColor == nil then return end
    local r, g, b
    if tone == "bad" then      r, g, b = 0.85, 0.20, 0.20
    elseif tone == "warn" then r, g, b = 0.95, 0.65, 0.15
    elseif tone == "good" then r, g, b = 0.55, 0.78, 0.25
    elseif tone == "mute" then r, g, b = 0.59, 0.61, 0.64
    else                       r, g, b = 1, 1, 1 end
    cell:setTextColor(r, g, b, 1)
    for _, setter in ipairs({ "setTextSelectedColor", "setTextFocusedColor",
                              "setTextFocusedSelectedColor" }) do
        if type(cell[setter]) == "function" then pcall(cell[setter], cell, r, g, b, 1) end
    end
end

---An icon cell, which must be actively HIDDEN when there is no file: SmoothList
-- recycles cells, so a row with no picture would otherwise inherit the last
-- row's. `setImageFilename` on a missing file leaves the previous texture in
-- place, so hiding is the only reliable clear.
local function setIcon(cell, name, file)
    local c = cell:getAttribute(name)
    if c == nil then return end
    if file ~= nil and c.setImageFilename ~= nil then
        pcall(c.setImageFilename, c, file)
        if c.setVisible ~= nil then c:setVisible(true) end
    elseif c.setVisible ~= nil then
        c:setVisible(false)
    end
end

---Cells are RECYCLED by SmoothList, so every field must be written on every path
-- including its colour, or a row inherits whatever the last row left there.
local function setc(cell, name, text, tone)
    local c = cell:getAttribute(name)
    if c == nil then return end
    if c.setText ~= nil then c:setText(text or "") end
    setColour(c, tone)
end

-- ---------------------------------------------------------------------------
-- DATA
-- ---------------------------------------------------------------------------

---What a cluster's reproduction state actually is, in the engine's own order:
-- age gate first, then health. 11.9 measured both; `assess` applies them the same
-- way, and this only words the answer.
local function reproText(c)
    if c.tooYoung then return l10n("ar_hi_repro_young", "too young"), "mute" end
    if c.unwell then return l10n("ar_hi_repro_unwell", "below the 75% gate"), "warn" end
    if c.dueInMonths ~= nil then
        return string.format(l10n("ar_hi_repro_due", "breeding - due %d mo"), c.dueInMonths), nil
    end
    return l10n("ar_hi_repro_breeding", "breeding"), nil
end

---Every group on the farm, one row per cluster, with its barn attached.
-- Barn identity travels as an INDEX into self.barns AND as a uid: the index is
-- what the drill-through selects, the uid is what survives a rebuild sliding a
-- different barn underneath it (DR 5.37).
---Hours in one of this page's periods. daysPerPeriod is READ, never assumed: a
-- server running 3-day months would otherwise be out by 3x on every figure here.
function HerdInspectorPage:periodHours()
    local idx = self:periodIndexSafe()
    if idx == HerdInspectorPage.PERIOD_CYCLE then return 1 end
    local days = 1
    if AnimalEconomics ~= nil and AnimalEconomics.daysPerMonth ~= nil then
        local ok, d = pcall(AnimalEconomics.daysPerMonth)
        if ok and type(d) == "number" and d >= 1 then days = d end
    end
    local month = 24 * days
    if idx == HerdInspectorPage.PERIOD_YEAR then return month * 12 end
    return month
end

---Multiplier for a figure stored PER HOUR (the feed and output tables).
function HerdInspectorPage:hourScale() return self:periodHours() end

---Multiplier for a figure stored PER MONTH (the value-change column, and the
-- panel's profit block). Expressed as a RATIO of the two periods rather than
-- recomputed, so the two scales can never disagree about how long a month is.
function HerdInspectorPage:monthScale()
    local days = 1
    if AnimalEconomics ~= nil and AnimalEconomics.daysPerMonth ~= nil then
        local ok, d = pcall(AnimalEconomics.daysPerMonth)
        if ok and type(d) == "number" and d >= 1 then days = d end
    end
    return self:periodHours() / (24 * days)
end

---nil in, nil out -- a figure we could not compute must not become a zero just
-- because it was multiplied (15.6).
local function scaled(v, k)
    if type(v) ~= "number" then return nil end
    return v * k
end

---THE RECOMMENDATION AS A SENTENCE. AnimalSellRules returns a code and the group's
-- OWN figures; this is where they become words, which is the same split the plan's
-- `notes` have always used.
--
-- Each string names the group's own number wherever one adds something -- "gaining
-- EUR 96 / mo" beats "still appreciating", because the second is true of half the
-- farm and the first tells you which half is worth the slot.
--
-- BUDGET: the column is 204px at 12px, about 34 characters. Anything longer is
-- truncated, not wrapped (5.55).
local REC_TEXT = {
    calf         = { "ar_hi_rec_calf",         "Sell newborns - nursery pays more" },
    headroom     = { "ar_hi_rec_headroom",     "Sell %d - pen full, births lost" },
    peak         = { "ar_hi_rec_peak",         "Sell - past peak, losing %s / mo" },
    plan         = { "ar_hi_rec_plan",         "Sell %d - see the Animals tab" },
    unwell       = { "ar_hi_rec_unwell",       "Feed - too unwell to breed (%d%%)" },
    young        = { "ar_hi_rec_young",        "Keep - producing in %d mo" },
    growing      = { "ar_hi_rec_growing",      "Keep - still growing" },
    appreciating = { "ar_hi_rec_appreciating", "Keep - gaining %s / mo" },
    outearns     = { "ar_hi_rec_outearns",     "Keep - earns %s / mo over decline" },
    declining    = { "ar_hi_rec_declining",    "Sell - old, losing %s / mo" },
    steady       = { "ar_hi_rec_steady",       "Keep - steady earner, %s / mo" },
    unprofitable = { "ar_hi_rec_unprofitable", "Sell - costs more than it earns" },
    unknown      = { "ar_hi_rec_unknown",      "-" },
}

function HerdInspectorPage.recommendationText(rec)
    if rec == nil then return "-", "mute" end
    local e = REC_TEXT[rec.code]
    if e == nil then return "-", "mute" end
    local fmt, d = l10n(e[1], e[2]), rec.data or {}
    local txt = fmt
    -- ONE substitution per code, chosen when the code is: a format string with the
    -- wrong argument type is a hard throw, and from a GUI populate that aborts the
    -- page mid-render and shows an EMPTY list (DR 5.44 / 5.57).
    local ok, out = pcall(function()
        if rec.code == "headroom" or rec.code == "plan" then
            return string.format(fmt, d.count or 0)
        elseif rec.code == "young" then
            return string.format(fmt, math.floor((d.months or 0) + 0.5))
        elseif rec.code == "unwell" then
            return string.format(fmt, math.floor((d.health or 0) + 0.5))
        elseif rec.code == "peak" or rec.code == "declining" then
            return string.format(fmt, money(math.abs(d.drift or 0)))
        elseif rec.code == "appreciating" then
            return string.format(fmt, money(d.gain or 0))
        elseif rec.code == "outearns" then
            return string.format(fmt, money(d.margin or 0))
        elseif rec.code == "steady" then
            return string.format(fmt, money(d.earns or 0))
        end
        return fmt
    end)
    if ok and type(out) == "string" then txt = out end

    -- KEEP is green, SELL is ORANGE rather than red -- it is an action to take, not
    -- a fault -- and only a herd too sick to breed is red, because that one IS a
    -- fault and the only row here the player is losing money by ignoring.
    local tone = "mute"
    if rec.action == AnimalSellRules.REC_KEEP then tone = "good"
    elseif rec.action == AnimalSellRules.REC_SELL then tone = "warn"
    elseif rec.action == AnimalSellRules.REC_ACT then tone = "bad" end
    return txt, tone
end

function HerdInspectorPage:buildGroupRows()
    local rows = {}
    for bi, b in ipairs(self.barns or {}) do
        local eff = 1
        if AnimalEconomics ~= nil and AnimalEconomics.efficiency ~= nil then
            local okE, e = pcall(AnimalEconomics.efficiency, b.placeable)
            if okE and type(e) == "number" then eff = e end
        end
        for _, c in ipairs(b.clusters or {}) do
            -- RESOLVED FROM THE INDEX. assess carries subTypeIndex and NOT the
            -- subtype, so reading c.subType yields nil and every curve with it.
            local st = c.subType or AnimalHerdData.subTypeOf(c.subTypeIndex)
            local milk = nil
            if st ~= nil then
                local per = AnimalHerdData.ratePerAnimal(st, c.age, "milk")
                if per ~= nil then milk = per * (c.count or 0) * eff end
            end
            local rTxt, rTone = reproText(c)
            -- WHAT THIS GROUP'S BOOK VALUE DID THIS MONTH, for the whole group.
            -- `driftPerMonth` is signed the other way (positive = LOSING), so it
            -- is negated here: this column answers "richer or poorer", and a
            -- reader should not have to invert a sign to find out which.
            -- nil where the price curve could not be sampled -- never a zero,
            -- which would read as "flat" (15.6).
            local change = nil
            local dpm = (c.econ ~= nil) and c.econ.driftPerMonth or nil
            if type(dpm) == "number" then change = -dpm * (c.count or 0) end
            -- WHAT TO DO WITH THIS GROUP, and why. A CODE and DATA, never a
            -- sentence: AnimalSellRules is pure and has no business knowing what
            -- language the player reads, so the wording is resolved below.
            local rec = nil
            if AnimalSellRules ~= nil and AnimalSellRules.recommendation ~= nil then
                local okR, r = pcall(AnimalSellRules.recommendation, c, b.plan)
                if okR and type(r) == "table" then rec = r end
            end
            rows[#rows + 1] = {
                icon = AnimalHerdData.animalIconFile(c.subTypeIndex, c.age),
                animal = c.name, barn = b.name, barnIndex = bi, barnUid = b.uid,
                typeIndex = b.typeIndex, count = c.count, age = c.age,
                healthPct = c.healthPct, repro = rTxt, reproTone = rTone,
                litresPerDay = milk, each = c.each, total = c.total,
                change = change, capped = (eff < 0.999), rec = rec,
                cluster = c.cluster,   -- identity, for the trade dialog's default
            }
        end
    end
    table.sort(rows, function(x, y)
        if x.barn ~= y.barn then return x.barn < y.barn end
        return (x.age or 0) > (y.age or 0)
    end)
    return rows
end

---The animal types actually present, for the filter. DERIVED FROM THE FARM, so
-- it can never offer a type nothing is standing in, and never miss a modded one.
function HerdInspectorPage:buildTypeList()
    local seen, list = {}, {}
    for _, b in ipairs(self.barns or {}) do
        if b.typeIndex ~= nil and seen[b.typeIndex] == nil then
            seen[b.typeIndex] = true
            list[#list + 1] = { index = b.typeIndex, name = b.typeName or tostring(b.typeIndex) }
        end
    end
    table.sort(list, function(x, y) return x.name < y.name end)
    table.insert(list, 1, { index = nil, name = l10n("ar_hi_filter_all", "All animals") })
    return list
end

---EVERY INPUT THE BARN TAKES, one row per PRODUCT rather than per group.
--
-- A food GROUP is a tier (a cow has TMR / Silage / Hay / Grass) and SEVERAL
-- PRODUCTS can satisfy each one, so a per-group table cannot say which of them
-- the barn is actually holding. This lists the products and names the group each
-- answers to, then goes wider than food: a barn's inputs are everything it takes
-- in, which is how DR treats any receiver.
--
-- NEEDS / H IS THE GROUP'S, repeated on each of its products, and COST / H is
-- what meeting that need ENTIRELY FROM THIS PRODUCT would cost per hour. That is
-- the comparison worth having, because it says which way of feeding a tier is
-- cheapest, and a per-group table cannot express it at all.
---What to call a declared (non-food) input in the GROUP column. It names the
-- PURPOSE, not the product, which is why it is not simply the fill type's title:
-- "Bedding" says what the straw is for.
function HerdInspectorPage.inputGroupTitle(key)
    if key == "water" then return l10n("ar_hi_group_water", "Water") end
    if key == "straw" then return l10n("ar_hi_group_bedding", "Bedding") end
    return tostring(key or "?")
end

function HerdInspectorPage:buildInputRows(b)
    local rows = {}
    if b == nil then return rows end
    local trough = b.trough or {}
    local function priceOf(ft)
        if AnimalEconomics == nil or AnimalEconomics.pricePerLitre == nil then return nil end
        return AnimalEconomics.pricePerLitre(ft)
    end

    -- WHAT THE BARN IS ACTUALLY EATING, AND WHAT THAT COSTS -- resolved by
    -- AnimalEconomics.feedCostPerHour, not here.
    --
    -- The tier rule (SERIAL feeds from the best tier PRESENT, PARALLEL from every
    -- group with stock) used to be written out in this function AND in the
    -- husbandry panel AND, once profit was added, in a third place. It is one
    -- rule, so it is one function now -- which is also what stops the COST NOW
    -- column below disagreeing with the PROFIT figure on the panel above it, a
    -- figure computed from exactly these litres.
    --
    -- It also brought the GRAZING correction with it: getAvailableFood reports
    -- trough PLUS meadow, so this column used to charge market price for pasture
    -- the farm already owns -- a fully-grazing barn was billed in full for eating
    -- nothing it bought. Only the trough's share is charged now.
    local feed = nil
    if AnimalEconomics ~= nil and AnimalEconomics.feedCostPerHour ~= nil then
        local okF, fc = pcall(AnimalEconomics.feedCostPerHour,
                              b.placeable, b.model, b.trough, b.demand)
        if okF and type(fc) == "table" then feed = fc end
    end
    local byFt = (feed ~= nil and feed.byFillType) or {}

    local seen = {}
    for _, g in ipairs(b.groups or {}) do
        for _, ft in ipairs(g.fts or {}) do
            seen[ft] = true
            local price = priceOf(ft)
            local held = trough[ft] or 0
            local e = byFt[ft]
            -- A REAL ZERO READS AS ONE and an unpriceable product still reports
            -- nil: "costing nothing" and "cannot be priced" are different facts.
            local actual = nil
            if price ~= nil then actual = (e ~= nil and e.cost or 0) end
            rows[#rows + 1] = {
                fillType = ft, group = g.title,
                held = held, needs = g.need,
                cost = (price ~= nil and g.need ~= nil) and (price * g.need) or nil,
                actual = actual,
            }
        end
    end

    -- BEDDING, AND ANYTHING ELSE THE SUBTYPE DECLARES AS AN INPUT. Straw is
    -- age-curved (15.4), so its need is summed over CLUSTERS exactly as the
    -- outputs are rather than assumed flat across the herd.
    --
    -- BEDDING AND WATER, FROM THE SAME FUNCTION THE PROFIT LINE USES.
    --
    -- This block used to gate COST NOW on `trough[ft]` -- and `trough` only ever
    -- holds FOOD fill types, so straw and water resolved nil and read as "using
    -- nothing" on EVERY barn ever shown. A permanent false zero, whose tell was the
    -- "-" sitting in their HELD column. Meanwhile the panel above charged both
    -- unconditionally, so one hour read -31 there and -24 here. Reported 2026-08-31.
    --
    -- declaredInputCostPerHour asks the BUILDING (getHusbandryFillLevel) instead,
    -- which is the only thing that can answer it, and knows that a barn with no
    -- water tank is paying by direct debit rather than drinking free.
    -- `food` stays excluded: it is the same litres the tier table above prices.
    local decl = nil
    if AnimalEconomics ~= nil and AnimalEconomics.declaredInputCostPerHour ~= nil then
        local okD, d = pcall(AnimalEconomics.declaredInputCostPerHour, b.placeable, b.clusters)
        if okD and type(d) == "table" then decl = d end
    end
    for slot, e in pairs((decl ~= nil and decl.byFillType) or {}) do
        local ft = e.fillType
        if ft ~= nil and not seen[ft] then
            local price = priceOf(ft)
            rows[#rows + 1] = {
                fillType = ft, group = HerdInspectorPage.inputGroupTitle(e.key),
                held = e.held, autoSupply = e.auto, needs = e.rate,
                -- COST IF ALL is still the hypothetical FULL rate, so the two
                -- columns keep meaning what they mean on the food rows above
                cost = price ~= nil and (price * e.rate) or nil,
                actual = e.cost,
            }
        end
    end

    -- grouped, so a tier's products sit together and the tiers keep the order
    -- readBarn sorted them into (the best tier first)
    local order = {}
    for i, g in ipairs(b.groups or {}) do order[g.title] = i end
    table.sort(rows, function(x, y)
        local ox, oy = order[x.group] or 99, order[y.group] or 99
        if ox ~= oy then return ox < oy end
        return (x.fillType or 0) < (y.fillType or 0)
    end)
    return rows
end

---WHAT THE BARN PRODUCES: what it is holding, how fast, and what that is worth.
--
-- PRODUCT | HELD | PROD RATE | VALUE (author's call). The two CHANGE columns are
-- gone: they carried a one-month forecast, which sat oddly beside a period selector
-- offering three of them, and HELD is the figure a reader actually wants next to a
-- rate -- what is in the barn now, and how fast it is filling.
--
-- AN ANIMAL'S DECLARATION IS NOT A BUILDING'S CAPABILITY. Reported 2026-08-31: the
-- base Cow Barn (large) listed SLURRY at 2 L/h. COW_ANGUS declares
-- output.liquidManure, so the animal is willing -- but specialCowStable has no
-- <liquidManure> block, so the barn has no slurry spec and the code that would make
-- it never runs. producibleOutputKeys asks the BUILDING.
--
-- PER ANIMAL IS GONE for its own reason: a per-animal rate on a mixed-age barn
-- described no animal standing in it.
--
-- VALUE IS AT TODAY'S PRICE and says so by being nil when there is no price: pricing
-- an output at zero would read as "worthless" rather than "unpriced".
function HerdInspectorPage:buildProductionRows(b)
    local rows = {}
    if b == nil or AnimalHerdData == nil then return rows end
    local eff, allowed = 1, nil
    if AnimalEconomics ~= nil then
        if AnimalEconomics.efficiency ~= nil then
            local okE, e = pcall(AnimalEconomics.efficiency, b.placeable)
            if okE and type(e) == "number" then eff = e end
        end
        if AnimalEconomics.producibleOutputKeys ~= nil then
            allowed = AnimalEconomics.producibleOutputKeys(b.placeable)
        end
    end

    -- summed over CLUSTERS at their own ages: a barn holding a calf and a cow does
    -- not produce twice the cow's rate
    local acc, order = {}, {}
    for _, c in ipairs(b.clusters or {}) do
        local st = c.subType or AnimalHerdData.subTypeOf(c.subTypeIndex)
        for _, r in ipairs(AnimalHerdData.outputRates(st, c.age or 0, allowed)) do
            local e = acc[r.key]
            if e == nil then
                e = { key = r.key, fillType = r.fillType, rate = 0 }
                acc[r.key] = e; order[#order + 1] = e
            end
            -- per DAY from the curve, reported per HOUR
            e.rate = e.rate + r.perDay * (c.count or 0) * eff / 24
        end
    end

    -- HELD comes from DR's assetHeld, which is the figure DR's own tabs print -- it
    -- folds a pen's pallets and its pending queue in (5.21), which getHusbandryFillLevel
    -- alone cannot see. One basis for one quantity across both mods.
    local SD = AnimalRedux ~= nil and AnimalRedux.DR or nil
    for _, e in ipairs(order) do
        local price = nil
        if AnimalEconomics ~= nil and AnimalEconomics.pricePerLitre ~= nil then
            price = AnimalEconomics.pricePerLitre(e.fillType)
        end
        local held = nil
        if SD ~= nil and SD.assetHeld ~= nil and e.fillType ~= nil then
            local okH, h = pcall(SD.assetHeld, b.placeable, e.fillType)
            if okH and type(h) == "number" then held = h end
        end
        rows[#rows + 1] = {
            product = e.fillType, key = e.key, held = held,
            rate = e.rate,
            value = price ~= nil and (e.rate * price) or nil,
        }
    end
    return rows
end

-- ---------------------------------------------------------------------------
function HerdInspectorPage:rebuild()
    self.barns = (AnimalHerdData ~= nil and AnimalHerdData.enumerate ~= nil)
        and AnimalHerdData.enumerate() or {}

    -- the cluster pass, and the animal TYPE each barn declares
    for _, b in ipairs(self.barns) do
        if AnimalHerdData ~= nil and AnimalHerdData.animalTypeOf ~= nil then
            b.typeIndex, b.typeName = AnimalHerdData.animalTypeOf(b.placeable)
        end
        b.clusters, b.plan = {}, nil
        -- PLAN, NOT assess -- and it costs no more. `plan` calls `assess` itself and
        -- hands it back as `plan.assess`, so asking for both would walk every cluster
        -- twice. The plan is what makes the RECOMMENDATION column agree with the
        -- Animals tab rather than being a second opinion about the same herd.
        if AnimalSellRules ~= nil and AnimalSellRules.plan ~= nil then
            local ok, pl = pcall(AnimalSellRules.plan, b.placeable)
            if ok and type(pl) == "table" and type(pl.assess) == "table" then
                b.plan = pl
                local a = pl.assess
                b.clusters = a.clusters or {}
                b.herdValue = a.value
                b.animals, b.capacity, b.free = a.animals, a.capacity, a.free
            end
        end
    end

    -- SELECTION FOLLOWS THE BUILDING, not the row number: the list is rebuilt on
    -- every refresh tick and a barn being built or demolished would otherwise
    -- slide a different one under the player's selection.
    self.selectedBarn = self.selectedBarn or 1
    if self.selectedUid ~= nil then
        for i, b in ipairs(self.barns) do
            if b.uid == self.selectedUid then self.selectedBarn = i; break end
        end
    end
    if self.selectedBarn > #self.barns then self.selectedBarn = 1 end

    self.types = self:buildTypeList()
    local allGroups = self:buildGroupRows()
    local want = self.filterType
    if want == nil then
        self.groupRows = allGroups
    else
        self.groupRows = {}
        for _, r in ipairs(allGroups) do
            if r.typeIndex == want then self.groupRows[#self.groupRows + 1] = r end
        end
    end

    local sel = self.barns[self.selectedBarn]
    self.barnGroupRows = {}
    for _, r in ipairs(allGroups) do
        if sel ~= nil and r.barnUid == sel.uid then
            self.barnGroupRows[#self.barnGroupRows + 1] = r
        end
    end
    self.inputRows = self:buildInputRows(sel)
    self.prodRows = self:buildProductionRows(sel)
    self.breedRows = self:buildBreedRows(sel)
end

---ONE ROW PER BREED THIS BARN COULD HOLD, held ones first.
--
-- BREEDS WITH NO STOCK ARE SHOWN TOO (author's call): a purpose and its rules are
-- worth setting BEFORE the animals arrive, and a list that appeared a row at a
-- time as stock changed would be a poor place to prepare a purchase.
--
-- THEY HAVE NO ECONOMICS, and that is honest rather than broken: an unheld breed
-- has no clusters, so no verdict, no earnings and no terms. Those cells read as a
-- dash and the row carries only what the player has said about it.
--
-- SORTED HELD-FIRST THEN BY NAME, never by count. A list ordered by headcount
-- reshuffles under the player as animals are bought and sold, which is 24.3's
-- complaint about clusters one level up -- and this list is one you click on.
function HerdInspectorPage:buildBreedRows(b)
    local rows = {}
    if b == nil then return rows end

    -- what the barn HOLDS, with its verdict and its terms (28.7 / 28.8)
    local byName = {}
    local a = b.plan ~= nil and b.plan.assess or nil
    if a ~= nil and AnimalSellRules ~= nil and AnimalSellRules.slotUseByType ~= nil then
        for _, g in ipairs(AnimalSellRules.slotUseByType(a) or {}) do
            g.held = true
            byName[g.name] = g
            rows[#rows + 1] = g
        end
    end

    -- ...and every other breed of this barn's animal TYPE, so a purpose can be set
    -- before the first one is bought.
    for _, st in ipairs(self:breedsOfType(b.placeable, b.typeIndex, b.typeName)) do
        if byName[st] == nil then
            rows[#rows + 1] = { name = st, count = 0, held = false }
        end
    end

    for _, r in ipairs(rows) do
        r.barnUid  = b.uid
        r.purpose  = AnimalHerdPolicy ~= nil and AnimalHerdPolicy.purposeOf(b.uid, r.name) or nil
    end
    table.sort(rows, function(x, y)
        if x.held ~= y.held then return x.held end
        return tostring(x.name) < tostring(y.name)
    end)
    return rows
end

---Pull subtype NAMES out of whatever shape a subtypes list turns out to be:
-- records, or indices to be resolved. `want` filters on the type where the list
-- covers more than one; nil takes everything, which is right for a list that came
-- off a single type in the first place.
local function subTypeNames(list, out, want)
    if type(list) ~= "table" then return false end
    local found = false
    for _, e in pairs(list) do
        local st = e
        if type(e) == "number" then
            local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
            if asys ~= nil and asys.getSubTypeByIndex ~= nil then
                local okS, v = pcall(asys.getSubTypeByIndex, asys, e)
                st = okS and v or nil
            end
        end
        if type(st) == "table" and type(st.name) == "string" and st.name ~= "" then
            if want == nil or st.typeIndex == want then
                out[#out + 1] = st.name
                found = true
            end
        end
    end
    return found
end

---EVERY BREED OF ONE ANIMAL TYPE, by NAME.
--
-- BY NAME AND NOT BY INDEX, because that is what the policy store is keyed on and
-- an index means a different animal with RealisticLivestock enabled (10.4).
--
-- THE FIRST VERSION CALLED a getSubTypes method, WHICH DOES NOT EXIST. It was a
-- guessed name, it failed inside a pcall, and the tab therefore listed only the
-- breeds a barn already held. SILENTLY, because a pcall that fails returns exactly
-- what "this barn has no other breeds" returns. Reported as the feature simply not
-- being there.
--
-- AnimalSystem is NOT in the readable SDK source (8.1), so the shape cannot be read
-- and a second guess would be no better than the first. These are the routes AR
-- ALREADY PROVES elsewhere, tried in order:
--   1. the barn own spec_husbandryAnimals.animalType table, which
--      AnimalHerdData.animalTypeOf already reads for its name;
--   2. getTypeByIndex, which that same function already calls successfully;
--   3. an index walk over getSubTypeByIndex, used in shipping code in three
--      places, filtered by the type own name prefix.
--
-- ROUTE 3 FILTERS ON THE NAME, and that limit is worth stating: a subtype matches
-- when it is called COW_something for a type called COW. A modded breed not
-- following that convention is missed, which costs a row in a list and never a
-- wrong answer about a breed that IS there.
--
-- IT SAYS WHICH ROUTE ANSWERED, once. The failure mode here is silence rather than
-- an error, and a player cannot be talked through enabling debug (5.63).
function HerdInspectorPage:breedsOfType(placeable, typeIndex, typeName)
    if typeIndex == nil then return {} end
    self._breedCache = self._breedCache or {}
    if self._breedCache[typeIndex] ~= nil then return self._breedCache[typeIndex] end

    local out, route = {}, nil
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil

    local spec = placeable ~= nil and placeable.spec_husbandryAnimals or nil
    local at = spec ~= nil and spec.animalType or nil
    if type(at) == "table" and subTypeNames(at.subTypes, out, nil) then route = "barn spec" end

    if route == nil and asys ~= nil and asys.getTypeByIndex ~= nil then
        local okT, t = pcall(asys.getTypeByIndex, asys, typeIndex)
        if okT and type(t) == "table" and subTypeNames(t.subTypes, out, nil) then
            route = "getTypeByIndex"
        end
    end

    if route == nil and asys ~= nil and asys.getSubTypeByIndex ~= nil
       and type(typeName) == "string" and typeName ~= "" then
        local prefix = typeName:upper() .. "_"
        for i = 1, 200 do
            local okS, st = pcall(asys.getSubTypeByIndex, asys, i)
            if okS and type(st) == "table" and type(st.name) == "string"
               and st.name:upper():sub(1, #prefix) == prefix then
                out[#out + 1] = st.name
            end
        end
        if #out > 0 then route = "index walk" end
    end

    table.sort(out)
    self._breedCache[typeIndex] = out
    if not self._breedRouteSaid then
        self._breedRouteSaid = true
        -- SAID ONLY WHEN IT IS INTERESTING. Finding nothing means the breed list
        -- will be empty and the player will see a blank tab with no explanation
        -- (29.11: a guessed method name failing silently is what this line exists
        -- to catch), so that stays unconditional. A route that WORKED is progress
        -- chatter and follows the Debug setting.
        local msg = string.format("breeds of type %s: %d found via %s",
                                  tostring(typeName or typeIndex), #out,
                                  tostring(route or "NOTHING"))
        if route == nil or #out == 0 then
            if AnimalRedux ~= nil and AnimalRedux.warn ~= nil then AnimalRedux.warn("%s", msg)
            else print("[AnimalRedux] " .. msg) end
        elseif AnimalRedux ~= nil and AnimalRedux.log ~= nil then
            AnimalRedux.log("%s", msg)
        end
    end
    return out
end

function HerdInspectorPage:rebuildRealtimeData()
    self:rebuild()
    self:updateSummary()
end

---THE BARN HEADER IS DR'S OWN PANEL, DRAWN BY DR'S OWN FUNCTION.
--
-- Not a second implementation of the same figures. `drawHusbandryPanel(root, d)`
-- takes a root element and the data an API v4 provider returns, and this mod IS
-- that provider - so the Animal Husbandry tab and this one render from one code
-- path and one data source, and cannot drift into disagreeing about a barn.
--
-- The panel's child NAMES are the contract. They are copied verbatim in the XML
-- for that reason; renaming one draws nothing and reports nothing.
function HerdInspectorPage:updateSummary()
    local SD = AnimalRedux ~= nil and AnimalRedux.DR or nil
    local root = self.animalPanel
    if SD == nil or root == nil or SD.drawHusbandryPanel == nil then return end
    local onBarn = (self:viewIndexSafe() == HerdInspectorPage.VIEW_BARN)
    local b = onBarn and (self.barns or {})[self.selectedBarn] or nil

    -- THE PANEL SHOWS ITSELF. drawHusbandryPanel calls setVisible(true) whenever
    -- it has data, so applyView hiding it first achieved nothing: this runs LAST
    -- and put it straight back on the groups view. Passing nil is that function's
    -- own contract for "hide", so the two are not fighting over one element.
    local data = nil
    if b ~= nil and b.placeable ~= nil and SD.husbandryPanelData ~= nil then
        local ok, d = pcall(SD.husbandryPanelData, b.placeable)
        if ok then data = d end
    end
    -- THE PANEL FOLLOWS THIS PAGE'S PERIOD SELECTOR. The provider states profit per
    -- MONTH; `opts` is drawHusbandryPanel's own hook for a page that quotes rates in
    -- something else, so the headline cannot read "/ MO" while the tables beneath it
    -- read per year. DR's own Animal Husbandry tab passes nothing and stays monthly.
    local per = HerdInspectorPage.PERIODS[self:periodIndexSafe()]
    local opts = { profitScale = self:monthScale(),
                   profitLabel = l10n(per.profit, per.profitFallback) }
    -- nil hides the panel, which is drawHusbandryPanel's own contract for a barn
    -- that cannot answer - better than a strip of dashes claiming to be figures
    pcall(SD.drawHusbandryPanel, root, data, opts)
    if self.panelHeader ~= nil and self.panelHeader.setVisible ~= nil then
        pcall(self.panelHeader.setVisible, self.panelHeader, onBarn)
    end
end

-- ---------------------------------------------------------------------------
-- VIEWS
-- ---------------------------------------------------------------------------
function HerdInspectorPage:viewIndexSafe()
    local v = self.viewIndex
    if type(v) ~= "number" or v < 1 or v > 3 then return HerdInspectorPage.VIEW_GROUPS end
    return v
end

---THE VIEW TABS. Named initViewOption still because every call site means "the
-- view control has changed, redraw it" -- what that control IS is this function's
-- business, not its callers'.
function HerdInspectorPage:initViewOption()
    if AnimalTabs == nil then return end
    AnimalTabs.render(self, { l10n("ar_hi_view_groups", "HERD INSPECTOR"),
                              l10n("ar_hi_view_barn",   "BARN INSPECTOR"),
                              l10n("ar_hi_view_breeds", "BREEDS") },
                      self:viewIndexSafe())
end

---A tab click. The two share one path because the only thing that differs is
-- which index, and the index is bounds-checked against the labels actually drawn.
function HerdInspectorPage:selectView(i)
    if i == nil or i == self:viewIndexSafe() then return end
    self.viewIndex = i
    self:initViewOption()
    self:applyView()
end

function HerdInspectorPage:onTab1() return self:selectView(HerdInspectorPage.VIEW_GROUPS) end
function HerdInspectorPage:onTab2() return self:selectView(HerdInspectorPage.VIEW_BARN) end
function HerdInspectorPage:onTab3() return self:selectView(HerdInspectorPage.VIEW_BREEDS) end

-- `onViewChanged` LIVED HERE AND IS GONE with the selector it answered. Verified
-- callerless before deleting rather than assumed (6.27): the XML no longer
-- declares a viewOption, so nothing can raise it.

function HerdInspectorPage:periodIndexSafe()
    local v = self.periodIndex
    if type(v) ~= "number" or v < 1 or v > #HerdInspectorPage.PERIODS then
        return HerdInspectorPage.PERIOD_MONTH
    end
    return v
end

function HerdInspectorPage:initPeriodOption()
    local o = self.periodOption
    if o == nil then return end
    local texts = {}
    for _, e in ipairs(HerdInspectorPage.PERIODS) do
        texts[#texts + 1] = l10n(e.label, e.fallback)
    end
    if o.setTexts ~= nil then o:setTexts(texts) end
    if o.setState ~= nil then o:setState(self:periodIndexSafe()) end
end

---A PERIOD CHANGE IS A REPOPULATE, NOT A REBUILD. Nothing about the world moved;
-- only the unit the same figures are quoted in. Rebuilding would re-walk every
-- cluster and re-read every trough for no new information.
function HerdInspectorPage:onPeriodChanged(state)
    -- the same guard onViewChanged carries: MultiTextOption's onClick raise site is
    -- in the stripped part of the SDK source, so the argument list is not readable
    -- and a non-number would silently pin the page to its fallback period, which
    -- looks exactly like "the selector does nothing"
    local o = self.periodOption
    if type(state) ~= "number" and o ~= nil and o.getState ~= nil then state = o:getState() end
    if type(state) ~= "number" or state < 1 or state > #HerdInspectorPage.PERIODS then return end
    self.periodIndex = state
    for _, id in ipairs({ "groupList", "barnGroupList", "inputList", "prodList", "breedList" }) do
        if self[id] ~= nil then self[id]:reloadData() end
    end
    self:updateSummary()
end

function HerdInspectorPage:initFilterOption()
    local o = self.filterOption
    if o == nil then return end
    local texts = {}
    for _, t in ipairs(self.types or {}) do texts[#texts + 1] = t.name end
    if #texts == 0 then texts = { l10n("ar_hi_filter_all", "All animals") } end
    -- setTexts only when the list actually CHANGED: reassigning it on every
    -- refresh fights a mid-click, and this list is rebuilt on a timer (DR 5.7).
    local joined = table.concat(texts, "\1")
    if joined ~= self._filterTexts and o.setTexts ~= nil then
        o:setTexts(texts)
        self._filterTexts = joined
    end
    if o.setState ~= nil then pcall(o.setState, o, self.filterIndex or 1, true) end
end

function HerdInspectorPage:onFilterChanged(state)
    local o = self.filterOption
    if type(state) ~= "number" and o ~= nil and o.getState ~= nil then state = o:getState() end
    if type(state) ~= "number" then return end
    self.filterIndex = state
    local t = (self.types or {})[state]
    self.filterType = t ~= nil and t.index or nil
    self:rebuild()
    if self.groupList ~= nil then self.groupList:reloadData() end
end

---Is the Herd Adviser switched on? FAILS OPEN, so a build without AnimalSettings
-- shows everything it always did.
function HerdInspectorPage.adviserOn()
    if AnimalSettings == nil or AnimalSettings.herdAdviserEnabled == nil then return true end
    return AnimalSettings.herdAdviserEnabled()
end

---The RECOMMENDATION header cell. Resolved by id, with getDescendantByName as the
-- fallback, and cached -- the tree does not change after load.
function HerdInspectorPage.headerRec(self)
    if self._ghRec ~= nil then return self._ghRec end
    local e = self.ghRec
    if e == nil and self.groupHeaderRow ~= nil and self.groupHeaderRow.getDescendantByName ~= nil then
        local ok, found = pcall(self.groupHeaderRow.getDescendantByName, self.groupHeaderRow, "ghRec")
        if ok then e = found end
    end
    self._ghRec = e
    return e
end

---Re-apply the view because a SETTING moved, not because the player changed view.
-- A setting that shows or hides a column changes the shape of a table, which a
-- repopulate cannot express -- the header is not part of the list.
function HerdInspectorPage.refreshView()
    local pg = HerdInspectorPage._page
    if pg == nil or pg.applyView == nil then return end
    pcall(pg.applyView, pg)
    local l = pg.activeList ~= nil and pg:activeList() or nil
    if l ~= nil and l.reloadData ~= nil then pcall(l.reloadData, l) end
end

function HerdInspectorPage:activeList()
    if self:viewIndexSafe() == HerdInspectorPage.VIEW_BREEDS then return self.breedList end
    if self:viewIndexSafe() == HerdInspectorPage.VIEW_BARN then return self.barnList end
    return self.groupList
end

---THE HEADING NAMES WHAT IS ON SCREEN. The two views answer different questions --
-- one surveys every group on the farm, the other examines a single building -- so a
-- heading that reads "Herd Inspector" over a barn is describing the other view.
--
-- Set from applyView rather than from the selector callback, so it is right on the
-- first open too: applyView runs on every path that changes the view, the callback
-- only on the ones the player drives.
function HerdInspectorPage:updateTitle()
    local t = self.pageTitle
    if t == nil or t.setText == nil then return end
    -- viewIndexSafe, not the raw field: applyView below decides the BODY with it,
    -- and a heading resolved from a different value could name the other view.
    local v = self:viewIndexSafe()
    if v == HerdInspectorPage.VIEW_BREEDS then
        t:setText(l10n("ar_hi_page_title_breeds", "ANIMAL REDUX - BREEDS"))
    elseif v == HerdInspectorPage.VIEW_BARN then
        t:setText(l10n("ar_hi_page_title_barn", "ANIMAL REDUX - BARN INSPECTOR"))
    else
        t:setText(l10n("ar_hi_page_title", "ANIMAL REDUX - HERD INSPECTOR"))
    end
end

function HerdInspectorPage:applyView()
    self:updateTitle()
    local v = self:viewIndexSafe()
    local groups = (v == HerdInspectorPage.VIEW_GROUPS)
    local breeds = (v == HerdInspectorPage.VIEW_BREEDS)
    -- THE BARN LIST SERVES TWO VIEWS. Breeds belong to a barn, so that view needs
    -- the same left-hand chooser, but none of the BARN view's own panes.
    local barn = (v == HerdInspectorPage.VIEW_BARN)
    local function vis(el, show)
        if el ~= nil and el.setVisible ~= nil then pcall(function() el:setVisible(show) end) end
    end
    -- THE WRAPPER, NOT THE LIST. Every list now sits in a GuiElement alongside its
    -- scrollbar (20.31), so hiding the list alone would leave the slider drawn
    -- beside nothing -- the same reason filterBox is toggled rather than the
    -- MultiTextOption inside it. Hiding the parent hides the children.
    vis(self.groupHeaderRow, groups)
    vis(self.groupListBox,   groups)
    -- THE RECOMMENDATION COLUMN follows the Herd Adviser setting. Hidden rather
    -- than dashed: 204px of "-" advertises a column that has nothing to say, which
    -- is the same call 5.33 made about a bunker's incoming table. It is the LAST
    -- column, so hiding it costs no re-tiling -- nothing sits to its right.
    -- The CELLS are hidden per row in populateCellForItemInSection; this is only
    -- the header, which is not part of the list.
    vis(HerdInspectorPage.headerRec(self), groups and HerdInspectorPage.adviserOn())
    -- the CONTAINER, not the option: hiding the MultiTextOption alone leaves its
    -- background box drawn behind nothing
    vis(self.filterBox,      groups)
    vis(self.barnHeaderRow,     barn or breeds)
    vis(self.barnListBox,       barn or breeds)
    vis(self.breedHeaderRow,    breeds)
    vis(self.breedListBox,      breeds)
    -- the panel and its header are BOTH left to updateSummary, which runs after
    -- this and would overrule anything set here anyway
    
    vis(self.bgHeaderRow,       barn)
    vis(self.barnGroupListBox,  barn)
    vis(self.inputHeaderRow,    barn)
    vis(self.inputListBox,      barn)
    vis(self.prodHeaderRow,     barn)
    vis(self.prodListBox,       barn)

    -- DR's paced refresh repopulates whatever is in here; a hidden pane listed
    -- would pay for cells nobody can see.
    if groups then
        self._realtimeLists = { "groupList" }
    elseif breeds then
        self._realtimeLists = { "barnList", "breedList" }
    else
        self._realtimeLists = { "barnList", "barnGroupList", "inputList", "prodList" }
    end

    self:applyButtonSet(breeds)
    self:rebuild()
    self:initFilterOption()
    local l = self:activeList()
    if l ~= nil then l:reloadData() end
    -- the panes that are NOT the active list still need reloading, or they keep
    -- whatever the previous barn left in them
    for _, id in ipairs({ "groupList", "barnGroupList", "inputList", "prodList", "breedList" }) do
        if self[id] ~= nil and self[id] ~= l then self[id]:reloadData() end
    end
    self:updateSummary()
end

-- ---------------------------------------------------------------------------
-- FRAME
-- ---------------------------------------------------------------------------
function HerdInspectorPage:onGuiSetupFinished()
    HerdInspectorPage:superClass().onGuiSetupFinished(self)
    for _, id in ipairs(HerdInspectorPage.LIST_IDS) do
        local list = self[id]
        if list ~= nil then
            list:setDataSource(self)
            list:setDelegate(self)
        end
    end
end

function HerdInspectorPage:onFrameOpen()
    HerdInspectorPage:superClass().onFrameOpen(self)
    self:initViewOption()
    self:initPeriodOption()
    self:applyView()
end

function HerdInspectorPage:getNumberOfItemsInSection(list, section)
    if list == self.groupList then return #(self.groupRows or {}) end
    if list == self.barnList then return #(self.barns or {}) end
    if list == self.barnGroupList then return #(self.barnGroupRows or {}) end
    if list == self.breedList then return #(self.breedRows or {}) end
    if list == self.inputList then return #(self.inputRows or {}) end
    if list == self.prodList then return #(self.prodRows or {}) end
    return 0
end

---WHERE A BREED'S EARNINGS COME FROM, in one short line.
--
-- The terms rather than the conclusion (28.8): the model prices RAW fill types and
-- cannot see what a farm does downstream, so a figure that is arithmetically right
-- can still be wrong for this player. Naming the products is what lets them argue
-- with it, and it is the reason this column exists at all.
--
-- BIGGEST FIRST AND CAPPED AT THREE: the column is 325px, and the tail of a list
-- of products is never the one being questioned.
function HerdInspectorPage:breedTermsText(r)
    if r == nil then return "-" end
    -- MADE BUT UNPRICEABLE IS NOT THE SAME AS EARNING NOTHING, and a dash would
    -- give the first answer when it means the second.
    if (r.earns == nil or next(r.earns) == nil) and (r.unpriced or 0) > 0 then
        return l10n("ar_hi_notPriced", "made, but not priceable")
    end
    if r.earns == nil then return "-" end
    local parts = {}
    for ft, v in pairs(r.earns) do parts[#parts + 1] = { ft = ft, v = v } end
    table.sort(parts, function(x, y)
        if x.v ~= y.v then return x.v > y.v end
        return tostring(x.ft) < tostring(y.ft)
    end)
    local bits, m = {}, g_fillTypeManager
    for i, e in ipairs(parts) do
        if i > 3 then break end
        local title = nil
        if m ~= nil and m.getFillTypeTitleByIndex ~= nil and type(e.ft) == "number" then
            local okT, v = pcall(m.getFillTypeTitleByIndex, m, e.ft)
            if okT and type(v) == "string" and v ~= "" then title = v end
        end
        bits[#bits + 1] = string.format("%s %s", title or tostring(e.ft), money(e.v))
    end
    if #bits == 0 then return "-" end
    return table.concat(bits, ", ")
end

---THE ARROWS. One callback is cloned into every row, so the only way to know which
-- breed was clicked is what populate left ON the element (DR 5.64) -- and the
-- raise site for a Button's onClick is in the stripped part of the SDK source, so
-- the varargs are SCANNED for the element carrying the field rather than a
-- position being assumed.
function HerdInspectorPage:clickedBreed(...)
    for i = 1, select("#", ...) do
        local e = select(i, ...)
        if type(e) == "table" and e.arBreed ~= nil then return e.arBreed, e.arBarnUid end
    end
    return nil, nil
end

function HerdInspectorPage:stepBreedPurpose(back, ...)
    if AnimalHerdPolicy == nil then return end
    local breed, uid = self:clickedBreed(...)
    if breed == nil or uid == nil then return end
    -- BACKWARDS IS THE FORWARD RING WALKED, never a second hand-written order: a
    -- reverse list is free to drift the next time a state is added, and these
    -- cannot (DR 5.64 draws the same conclusion about the mode ring).
    local steps = back and (#AnimalHerdPolicy.RING - 1) or 1
    for _ = 1, steps do AnimalHerdPolicy.cyclePurpose(uid, breed) end
    self:rebuild()
    if self.breedList ~= nil then self.breedList:reloadData() end
end

---SWAP THE FOOTER FOR THIS VIEW.
--
-- `setMenuButtonInfo` puts the set on the PAGE; the menu only re-reads it when it
-- updates the panel, so `updateButtonsPanel` has to be asked. Both are the base
-- game's own (TabbedMenuFrameElement / TabbedMenu, read from source) -- and
-- `getPageButtonInfo` calls `getHasCustomMenuButtons` first, which is true exactly
-- because a set was assigned at install.
--
-- ONLY WHEN IT CHANGES: this runs on every view switch, and re-adding the button
-- box rebuilds the footer, which is not something to do for a set already showing.
---Is a footer button switched OFF in AnimalSettings? Answered here rather than
-- read at the definition site, because a setting can move while this page is
-- open: the set has to be rebuilt on demand, not chosen once at install.
--
-- FAILS OPEN. With AnimalSettings absent (a load failure, an older build) every
-- button shows, which is the behaviour before the settings existed. A missing
-- settings file must not take features away.
local function buttonEnabled(kind)
    if AnimalSettings == nil then return true end
    if kind == "trade" then return AnimalSettings.tradingEnabled() end
    -- THE AUTO TRADER OWNS FOUR BUTTONS, NOT ONE. Author, 2026-09-04: the setting
    -- should take the two RULES buttons with it. That is right and the first
    -- version of this was wrong to keep them: sell rules are constraints on the
    -- engine that runs a standing SELL order (29.15a), and buy rules are a
    -- placeholder for guards on a standing BUY order -- so with the auto trader
    -- off they configure something that cannot run, and the orders they would have
    -- governed have just been deleted.
    if kind == "schedule" or kind == "sellRules" or kind == "buyRules" then
        return AnimalSettings.autoTraderEnabled()
    end
    return true
end

---The footer set for a view, with any switched-off entry left out.
-- BACK IS ALWAYS FIRST AND ALWAYS PRESENT: a page you cannot leave is worse than
-- a page with no buttons.
local function buildButtonSet(want)
    local b = HerdInspectorPage._buttons
    if b == nil then return nil end
    local out = { b.back }
    if want == "rules" then
        -- WITH THE AUTO TRADER OFF THIS VIEW HAS ONLY Back, and that is intended
        -- rather than a stranded tab: the breed PURPOSE arrows live in the rows,
        -- so setting what a barn keeps each breed for still works and the verdict
        -- columns still read. It is the standing-order RULES that go.
        if buttonEnabled("sellRules") then out[#out + 1] = b.sellRules end
        if buttonEnabled("buyRules")  then out[#out + 1] = b.buyRules end
    else
        if buttonEnabled("trade")    then out[#out + 1] = b.trade end
        if buttonEnabled("schedule") then out[#out + 1] = b.schedule end
    end
    return out
end

function HerdInspectorPage:applyButtonSet(breeds)
    if HerdInspectorPage._buttons == nil or self.setMenuButtonInfo == nil then return end
    local want = breeds and "rules" or "trade"
    -- THE SETTINGS ARE PART OF THE IDENTITY OF A SET, not just the view. Keying
    -- the "nothing changed" test on the view alone is what would leave a removed
    -- button on screen until the player switched views and back.
    -- EVERY SETTING THAT CAN CHANGE THE SET IS IN THE SIGNATURE. The auto trader now
    -- reaches BOTH views, so a signature carrying only the trading view's answers
    -- would leave the rules buttons on screen until the player switched views.
    local sig = want .. ":" .. tostring(buttonEnabled("trade")) .. ":"
                     .. tostring(buttonEnabled("schedule"))
    if self._buttonSet == sig then return end
    self._buttonSet = sig
    self:setMenuButtonInfo(buildButtonSet(want))
    HerdInspectorPage.repaintFooter(self)
end

---Push this page's buttons into the MENU's footer -- but ONLY while this page is
-- the one on screen.
--
-- TabbedMenu:updateButtonsPanel(page) assigns THAT page's buttons unconditionally
-- (TabbedMenu.lua:618). It is harmless when called from a view switch, because the
-- herd page is showing by definition -- and it is not harmless at all when called
-- from AnimalSettings, which runs while the player is on the SETTINGS page. That
-- shipped: toggling Buy / Sell or the Auto Trader put BUY / SELL and AUTO TRADER
-- into the Settings page's own footer.
--
-- setMenuButtonInfo above is left UNCONDITIONAL, and that is the half that makes
-- this correct rather than merely quiet: the set is stored on the page either way,
-- so the footer is already right the moment the player navigates back. Only the
-- immediate repaint is withheld.
function HerdInspectorPage.repaintFooter(page)
    local menu = HerdInspectorPage._menu
    if menu == nil or menu.updateButtonsPanel == nil then return end
    if menu.currentPage ~= nil and menu.currentPage ~= page then return end
    pcall(menu.updateButtonsPanel, menu, page)
end

---Rebuild the footer of the live page because a setting moved. Called from
-- AnimalSettings; a no-op when the tab has never been opened.
function HerdInspectorPage.refreshButtons()
    local pg = HerdInspectorPage._page
    if pg == nil or pg.applyButtonSet == nil then return end
    pg._buttonSet = nil                       -- force it through the signature test
    local breeds = (pg.viewIndexSafe ~= nil)
                   and (pg:viewIndexSafe() == HerdInspectorPage.VIEW_BREEDS) or false
    pcall(pg.applyButtonSet, pg, breeds)
end

---THE SELECTED BREED, for the two rules buttons. Nil when the list is empty or
-- nothing is picked, which is what keeps a button from acting on nothing.
function HerdInspectorPage:selectedBreedRow()
    local rows = self.breedRows or {}
    local i = self.breedRowIndex or 1
    return rows[i]
end

function HerdInspectorPage:openSellRules()
    if AnimalSettings ~= nil and not AnimalSettings.autoTraderEnabled() then return end
    local r = self:selectedBreedRow()
    local b = (self.barns or {})[self.selectedBarn]
    if r == nil or b == nil or AnimalRulesDialog == nil then return end
    AnimalRulesDialog.show(b.uid, r.name, b.name)
end

---BUY RULES ARE NOT BUILT YET, and the button says so rather than opening an empty
-- window. Buying is ASYMMETRIC to selling (28.x): sell rules are constraints on an
-- engine that decides, while a buy order is a literal instruction, so buy "rules"
-- are GUARDS -- and the one worth having, a cash floor, is farm-wide rather than
-- per barn-breed. What belongs in this window is still an open question.
function HerdInspectorPage:openBuyRules()
    if AnimalSettings ~= nil and not AnimalSettings.autoTraderEnabled() then return end
    if g_gui == nil or InfoDialog == nil then return end
    InfoDialog.show(l10n("ar_hi_buyRulesTodo",
        "Buy rules are not built yet. Buying has no engine choosing for it, so its rules are guards rather than policy - and the one worth having, a cash floor, belongs to the farm rather than to one breed."))
end

function HerdInspectorPage:onBreedNext(...) return self:stepBreedPurpose(false, ...) end
function HerdInspectorPage:onBreedPrev(...) return self:stepBreedPurpose(true, ...) end

---A click on the row itself changes nothing but the selection: the purpose is the
-- arrows' business, so a stray click cannot alter a setting.
function HerdInspectorPage:onBreedClick() end

-- WHY A BREED GOT ITS VERDICT. The engine hands back a code; the wording is ours,
-- because that module is pure. Mapped EXPLICITLY rather than built from the code,
-- so check_l10n_animal.py can see every key.
local ADVICE_REASON_KEY = {
    outputBeatsCalves = "ar_hi_why_outputBeats",
    calvesWorthMore   = "ar_hi_why_calvesWorth",
    noOutput          = "ar_hi_why_noOutput",
    nothingToWeigh    = "ar_hi_why_nothingToWeigh",
}

---THE VERDICT AND WHY, in one cell.
--
-- "Producers" on its own is a conclusion a player cannot argue with (28.8). The
-- reason is what makes it checkable against their own intention for the barn, and
-- noOutput says something quite different from calvesWorthMore though both read
-- "Breeders".
function HerdInspectorPage:adviceText(r)
    if r == nil or r.use == nil then return "-" end
    local word = (r.use == "NURSERY") and l10n("ar_hi_purpose_breeder", "Breeders")
                                      or  l10n("ar_hi_purpose_producer", "Producers")
    local key = ADVICE_REASON_KEY[r.reason or ""]
    if key == nil then return word end
    -- SHORTER NOW THAT THE FIGURES ARE BESIDE IT. The reason names WHICH side won;
    -- the two columns say by how much, which is what the sentence alone could not.
    return string.format(l10n("ar_hi_adviceWhy", "%s - %s"), word, l10n(key, ""))
end

---THE WORD FOR A PURPOSE, or a dash when nobody has said. Unset is a STATE and
-- never collapses into either answer (29.2).
function HerdInspectorPage:purposeText(p)
    if p == AnimalHerdPolicy.PRODUCER then return l10n("ar_hi_purpose_producer", "Producers") end
    if p == AnimalHerdPolicy.BREEDER  then return l10n("ar_hi_purpose_breeder",  "Breeders") end
    return "-"
end

function HerdInspectorPage:populateCellForItemInSection(list, section, index, cell)
    if list == self.breedList then
        local r = (self.breedRows or {})[index]
        if r == nil then return end
        setIcon(cell, "brIcon", (AnimalHerdData ~= nil and r.held)
                and AnimalHerdData.animalIconFile(r.subTypeIndex, r.age or 0) or nil)
        -- A BREED THIS BARN DOES NOT HOLD IS MUTED, not hidden: it is there so a
        -- purpose can be set before the animals arrive, and it should not read as
        -- part of the herd while it is empty.
        local tone = r.held and nil or "mute"
        setc(cell, "brName",    tostring(r.name), tone)
        setc(cell, "brCount",   r.held and string.format("%d", r.count or 0) or "-", tone)
        setc(cell, "brPurpose", self:purposeText(r.purpose))
        -- THE ENGINE'S VERDICT IS ADVICE AND SITS IN ITS OWN COLUMN, so it can be
        -- told apart from what the player chose (29.2). It says nothing about a
        -- breed with no animals to judge.
        setc(cell, "brAdvice", self:adviceText(r), "mute")
        -- A ZERO THAT IS REALLY AN ABSENCE reads as a dash: nothing here could be
        -- priced, so "0" would claim a measurement nobody made (DR 5.46c).
        -- SCALED TO THE PERIOD SELECTOR, like every other rate on this page. The
        -- figure is computed per MONTH and the selector sits directly above this
        -- table, so a column ignoring it quotes a different period from the one the
        -- page says it is showing.
        local earnsText = "-"
        if r.earnsPerAnimal ~= nil and not (r.earnsPerAnimal == 0 and (r.unpriced or 0) > 0) then
            earnsText = money(scaled(r.earnsPerAnimal, self:monthScale()))
        end
        setc(cell, "brEarns",  earnsText, tone)

        -- THE PAIR THE VERDICT WAS ACTUALLY DECIDED ON, which the advice column
        -- asserts and had no numbers behind (author, 2026-09-02).
        --
        -- NEITHER OF THEM IS THE RAW SALE VALUE, and that is the reason both are
        -- here rather than just the calf. `slotVerdict` compares
        --   KEEPS  = econ.marginPerMonth: the output LESS bedding and less the
        --            value the animal loses each month as it ages, and
        --   CALF   = the newborn's price spread over one breeding cycle.
        -- Putting the calf beside the RAW figure would invite a comparison the
        -- engine never made, and where straw and drift are large the raw value can
        -- exceed the calf while the verdict still says breeders. Showing the pair
        -- is what makes the advice checkable instead of merely asserted.
        local k = self:monthScale()
        setc(cell, "brKeeps", r.adult   ~= nil and money(scaled(r.adult, k))   or "-", tone)
        setc(cell, "brCalf",  r.nursery ~= nil and money(scaled(r.nursery, k)) or "-", tone)
        setc(cell, "brTerms",  self:breedTermsText(r), "mute")

        -- WHICH ROW AN ARROW BELONGS TO, stashed on the ELEMENT. One callback is
        -- cloned into every row (DR 5.64), so the handler has no other way to know
        -- what it was clicked on -- and it is stored as the BREED NAME, never the
        -- row index, because this list re-enumerates on a timer and an index
        -- captured at populate can point at another breed by the time it is used.
        for _, n in ipairs({ "brPrev", "brNext" }) do
            local e = cell:getAttribute(n)
            if e ~= nil then e.arBreed, e.arBarnUid = r.name, r.barnUid end
        end
        return
    end
    if list == self.groupList or list == self.barnGroupList then
        local src = (list == self.groupList) and self.groupRows or self.barnGroupRows
        local r = (src or {})[index]
        if r == nil then return end
        setIcon(cell, "fillIcon", r.icon)
        setc(cell, "giAnimal", r.animal)
        setc(cell, "giBarn",   r.barn)                       -- absent on the barn view template
        setc(cell, "giCount",  string.format("%d", r.count or 0))
        setc(cell, "giAge",    string.format(l10n("ar_hi_fmt_months", "%d mo"), r.age or 0))
        local hp = r.healthPct or 0
        setc(cell, "giHealth", string.format("%d%%", hp), hp >= 75 and "good" or "warn")
        setc(cell, "giRepro",  r.repro, r.reproTone)
        setc(cell, "giEach",   money(r.each))
        -- SIGNED AND COLOURED: green gaining, red losing. A bare figure here
        -- would need a minus sign hunted for to be read at all.
        local chg = scaled(r.change, self:monthScale())
        if chg == nil then
            setc(cell, "giChange", "-", "mute")
        else
            local sign = chg >= 0 and "+" or ""
            setc(cell, "giChange", sign .. money(chg),
                 chg > 0.5 and "good" or (chg < -0.5 and "bad" or "mute"))
        end
        setc(cell, "giTotal",  money(r.total))
        -- HIDDEN WITH ITS HEADER when the Herd Adviser is off. Cells are RECYCLED
        -- by SmoothList, so this must be set on BOTH paths or a row reusing a slot
        -- keeps the last one's visibility (the trap DR 5.7 and 5.57 both hit).
        local recCell = cell.getAttribute ~= nil and cell:getAttribute("giRec") or nil
        if recCell ~= nil and recCell.setVisible ~= nil then
            recCell:setVisible(HerdInspectorPage.adviserOn())
        end
        local rTxt, rTone = HerdInspectorPage.recommendationText(r.rec)
        setc(cell, "giRec", rTxt, rTone)
        return
    end

    if list == self.barnList then
        local b = (self.barns or {})[index]
        if b == nil then return end
        -- COUNT and FOOD % were dropped from this list: the panel beside it carries
        -- both for the selected barn, and they were the reason the name had 170px.
        setIcon(cell, "assetIcon", AnimalHerdData.barnIconFile(b.placeable))
        setc(cell, "blName", b.name)
        return
    end

    if list == self.inputList then
        local r = (self.inputRows or {})[index]
        if r == nil then return end
        setIcon(cell, "fillIcon", AnimalHerdData.fillIconFile(r.fillType))
        setc(cell, "inProduct", ftTitle(r.fillType))
        setc(cell, "inGroup",   r.group, "mute")
        -- HELD IS THE PRODUCT'S OWN, so a zero here on a group that is otherwise
        -- met means the tier is being covered by one of its OTHER products
        -- "auto" rather than a dash or a zero: a barn with no water tank is not
        -- short of water, it is billed for it directly (PlaceableHusbandryWater
        -- forces automaticWaterSupply on when WATER is not a supported fill type).
        if r.autoSupply then
            setc(cell, "inHeld", l10n("ar_hi_auto", "auto"), "mute")
        else
            setc(cell, "inHeld",  r.held ~= nil and vol(r.held) or "-",
                 (r.held == nil and "mute") or ((r.held or 0) <= 0 and "warn" or nil))
        end
        -- HELD IS A STOCK and does not scale; everything below it is a RATE and does
        local k = self:hourScale()
        local needs, cost, actual = scaled(r.needs, k), scaled(r.cost, k), scaled(r.actual, k)
        setc(cell, "inNeeds", needs ~= nil and vol(needs) or "-", needs == nil and "mute" or nil)
        setc(cell, "inCost",  cost ~= nil and money(cost) or "-", cost == nil and "mute" or nil)
        -- A REAL ZERO, not a dash: this product is genuinely costing nothing
        -- right now, which is different from not knowing what it costs.
        setc(cell, "inActual", actual ~= nil and money(actual) or "-",
             (actual == nil and "mute") or ((actual or 0) > 0 and "good" or "mute"))
        return
    end

    if list == self.prodList then
        local r = (self.prodRows or {})[index]
        if r == nil then return end
        setIcon(cell, "fillIcon", AnimalHerdData.fillIconFile(r.product))
        setc(cell, "pdProduct", ftTitle(r.product))
        -- HELD IS A STOCK and does not scale with the period; RATE and VALUE do.
        -- No " / h" suffix on either: the period selector states the unit once for
        -- the whole page, and a cell claiming "/ h" beside a legend reading YEAR is
        -- a contradiction on screen.
        local k = self:hourScale()
        setc(cell, "pdHeld", r.held ~= nil and vol(r.held) or "-", r.held == nil and "mute" or nil)
        local rate, val = scaled(r.rate, k), scaled(r.value, k)
        setc(cell, "pdRate", vol(rate or 0), (rate or 0) <= 0 and "mute" or nil)
        setc(cell, "pdValue", val ~= nil and money(val) or "-", val == nil and "mute" or nil)
        return
    end
end

---SELECTION for the barn list; DRILL-THROUGH for the groups list.
-- The two are different gestures and SmoothList reports them differently: a click
-- on an ALREADY-SELECTED row changes no selection and raises no selection event
-- at all (DR 6.29), so a drill-through built on selection would refuse to open
-- the row the player is looking at. onListClick is raised from notifyClick
-- regardless, which is why the jump lives there.
function HerdInspectorPage:onListSelectionChanged(list, section, index)
    -- remembered so the trade dialog can default to the group the player is looking
    -- at; the groups list is otherwise selection-agnostic
    if list == self.groupList then self.groupRowIndex = index; return end
    -- REMEMBERED, because the two rules buttons act on the SELECTED breed and the
    -- list is otherwise selection-agnostic.
    if list == self.breedList then self.breedRowIndex = index; return end
    if list ~= self.barnList then return end
    self.selectedBarn = index
    local b = (self.barns or {})[index]
    self.selectedUid = b ~= nil and b.uid or nil
    self:rebuild()
    -- IMMEDIATELY, not at the next paced tick. The page is repopulated on DR's own
    -- refresh interval, so a pane left out of this list still comes right -- seconds
    -- later, which reads as the click having been ignored.
    for _, id in ipairs(HerdInspectorPage.DETAIL_LISTS) do
        if self[id] ~= nil then self[id]:reloadData() end
    end
    self:updateSummary()
end

function HerdInspectorPage:onListClick(list, section, index)
    if list ~= self.groupList then return end
    local r = (self.groupRows or {})[index]
    if r == nil then return end
    -- BY UID, never by the index captured at populate: this table re-enumerates
    -- on a timer and rows can reorder between the click and the handler.
    self.selectedUid = r.barnUid
    self.selectedBarn = r.barnIndex
    -- IT NO LONGER JUMPS TO THE BARN VIEW. With the two views as TABS they are
    -- peers, so a click here selects which barn the other tab will show and
    -- nothing more -- the player moves between them by tab, which is the whole
    -- point of the change (2026-09-01). The selection is still applied to the
    -- barn list so switching tab lands on the row they picked.
    if self.barnList ~= nil then
        pcall(self.barnList.setSelectedItem, self.barnList, 1, self.selectedBarn, true)
    end
end

---OPEN THE BUY / SELL WINDOW, scoped to where the player is standing.
--
-- THE CONTEXT IS THE WHOLE POINT of this being ours rather than a shortcut to the
-- base game's screen:
--   * BARN view   -> that barn alone, and the dialog hides its barn selector,
--                    because there is then nothing to choose;
--   * GROUPS view -> every barn, defaulted to the SELECTED ROW's barn and to that
--                    row's group, so the thing the player was looking at is already
--                    the thing the dialog is about.
--
-- The group is passed as the CLUSTER OBJECT, not a name or an index: two groups of
-- the same animal at different ages are routine, and a name match would land on
-- whichever came first (the identity rule 5.37 and DR 6.29 both rest on).
function HerdInspectorPage:openTrade()
    -- DEFENCE IN DEPTH. The button is the only way here, so this should be
    -- unreachable with trading off -- but a footer that has not been rebuilt yet
    -- is exactly the state a stale button lives in, and opening a dialog for a
    -- feature the player switched off is worse than a button that does nothing.
    if AnimalSettings ~= nil and not AnimalSettings.tradingEnabled() then return end
    if AnimalTradeDialog == nil or AnimalTradeDialog.show == nil then return end
    local onBarn = (self:viewIndexSafe() == HerdInspectorPage.VIEW_BARN)
    local list, cluster = self.barns or {}, nil

    if onBarn then
        local b = (self.barns or {})[self.selectedBarn]
        if b == nil then return end
        list = { b }
    else
        local r = (self.groupRows or {})[self.groupRowIndex or 0]
        if r ~= nil then
            for i, b in ipairs(self.barns or {}) do
                if b.uid == r.barnUid then
                    -- reorder so the row's barn is the DEFAULT without removing the
                    -- others: the player may still want to trade elsewhere
                    list = {}
                    list[1] = b
                    for j, other in ipairs(self.barns) do
                        if j ~= i then list[#list + 1] = other end
                    end
                    break
                end
            end
            cluster = r.cluster
        end
    end
    AnimalTradeDialog.show(list, onBarn, cluster, AnimalTrade.MODE_SELL)
end

---THE STANDING-ORDER WINDOW, context sensitive the same way openTrade is: from the
-- BARN view that barn alone with the selector hidden, from GROUPS every barn with
-- the selected row's barn defaulted.
--
-- IT SHARES openTrade's CONTEXT RULE BUT NOT ITS ROW PREFERENCE. A sell row names a
-- CLUSTER the farm already owns, which means nothing to a buy schedule -- the thing
-- being chosen there is a DEALER row, and offering a preselection derived from the
-- herd would point at the wrong list entirely.
function HerdInspectorPage:openSchedule()
    if AnimalSettings ~= nil and not AnimalSettings.autoTraderEnabled() then return end
    if AnimalBuyScheduleDialog == nil or AnimalBuyScheduleDialog.show == nil then return end
    local onBarn = (self:viewIndexSafe() == HerdInspectorPage.VIEW_BARN)
    local list = self.barns or {}

    if onBarn then
        local b = list[self.selectedBarn]
        if b == nil then return end
        list = { b }
    else
        local r = (self.groupRows or {})[self.groupRowIndex or 0]
        if r ~= nil then
            for i, b in ipairs(self.barns or {}) do
                if b.uid == r.barnUid then
                    list = { b }
                    for j, other in ipairs(self.barns) do
                        if j ~= i then list[#list + 1] = other end
                    end
                    break
                end
            end
        end
    end
    AnimalBuyScheduleDialog.show(list, onBarn)
end

-- ---------------------------------------------------------------------------
-- INSTALL
-- ---------------------------------------------------------------------------
function HerdInspectorPage.install(menu)
    local SD  = AnimalRedux ~= nil and AnimalRedux.DR or nil
    local env = AnimalRedux ~= nil and AnimalRedux.DR_ENV or nil
    if SD == nil or env == nil or menu == nil then return false, "no DR menu" end

    local base = env.DistributionMenuPage
    if base == nil then return false, "DR's DistributionMenuPage not found" end
    if SD.API == nil or SD.API.loadMenuPage == nil or SD.API.addMenuPage == nil then
        return false, "DR's menu API is older than v3"
    end

    local mt = Class(HerdInspectorPage, base)
    HerdInspectorPage.new = function(target, custom_mt)
        local self = base.new(target, custom_mt or mt)
        -- a DISTINCT pageName: addMenuPage appends, and two pages answering to
        -- one name is how a paging element and a tab strip end up disagreeing
        self.pageName = "HERDINSPECTOR_PAGE"
        self.barns, self.selectedBarn = {}, 1
        -- OPENS ON THE BARN VIEW (author's call): it is the one carrying the panel,
        -- the three tables and the trade button, so it is where a player arrives
        -- wanting to do something rather than to survey.
        self.viewIndex, self.filterIndex = HerdInspectorPage.VIEW_BARN, 1
        return self
    end

    -- AR'S OWN PROFILES MUST BE IN g_gui BEFORE THE PAGE XML IS PARSED.
    --
    -- A LAYOUT NAMING A PROFILE THAT IS NOT LOADED DOES NOT ERROR: it falls back to
    -- a default with no positioning and no transparency (DR 5.64), which is a white
    -- block sprawling across the row rather than a 40px arrow. Reported from a
    -- screenshot 2026-09-02, and the tell was that the LEFT arrow drew correctly --
    -- it uses a base game profile, which is always there, while the right one uses
    -- ARRowArrowRight, which was not yet.
    --
    -- It used to be loaded by AnimalBuyScheduleDialog.register, which runs BELOW
    -- this: a dialog was simply the first thing that happened to need them. The
    -- call is guarded on AnimalRedux._profilesLoaded, so both sites are safe and
    -- whichever runs first wins.
    if AnimalBuyScheduleDialog ~= nil and AnimalBuyScheduleDialog.loadProfiles ~= nil then
        pcall(AnimalBuyScheduleDialog.loadProfiles)
    end

    local page = HerdInspectorPage.new()
    if not SD.API.loadMenuPage(page, "herdInspectorPage",
                               AnimalRedux.MOD_DIR .. "gui/HerdInspectorPage.xml") then
        return false, "page XML failed to load"
    end

    -- BACK IS A STEP, NOT AN EXIT, while the barn view is up. DR's own back
    -- button calls menu:onClickBack, which closes the whole menu -- correct from
    -- the top view and wrong from a view the player drilled INTO. The original
    -- callback is kept and delegated to, so leaving the tab still behaves
    -- exactly as every other DR tab does.
    -- BACK IS A PLAIN EXIT AGAIN. 18.8 made it a STEP (barn view -> groups view)
    -- because the barn view was something the player had drilled INTO. With the
    -- two views as TABS they are peers, there is nothing to step back out of, and
    -- a BACK that behaved differently from every other DR tab would now be the
    -- surprise rather than the courtesy.
    local back = SD.API.menuBackButton(menu)
    -- BUY / SELL, on both views. The dialog is registered here rather than at load
    -- because g_gui must exist and DR's profiles must already be in it -- this page
    -- has both by construction, being installed into DR's own menu.
    if AnimalTradeDialog ~= nil and AnimalTradeDialog.register ~= nil then
        pcall(AnimalTradeDialog.register)
    end
    if AnimalBuyScheduleDialog ~= nil and AnimalBuyScheduleDialog.register ~= nil then
        pcall(AnimalBuyScheduleDialog.register)
    end
    if AnimalRulesDialog ~= nil and AnimalRulesDialog.register ~= nil then
        pcall(AnimalRulesDialog.register)
    end
    local trade = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = l10n("ar_hi_btn_trade", "Buy / Sell"),
        callback = function()
            local pg = HerdInspectorPage._page
            if pg ~= nil then pg:openTrade() end
        end,
        showWhenPaused = true,
    }
    -- MENU_EXTRA_2 IS THE LAST SPARE FOOTER ACTION (DR 5.64: EXTRA_1 and EXTRA_2 are
    -- the only extras, and ACCEPT / ACTIVATE / BACK / CANCEL / PAGE_PREV / PAGE_NEXT
    -- are all taken). Anything after this needs a custom modDesc action.
    local schedule = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = l10n("ar_hi_btn_schedule", "Auto Trader"),
        callback = function()
            local pg = HerdInspectorPage._page
            if pg ~= nil then pg:openSchedule() end
        end,
        showWhenPaused = true,
    }
    -- THE RULES BUTTONS, which stand in place of the trading pair on the BREEDS
    -- view. Author, 2026-09-02: *"remove autotrader and buy/sell from the breeds
    -- tab, the only options here should be sell rules and buy rules... the buy and
    -- sell should only be through the barn view."*
    --
    -- THE SAME TWO INPUT ACTIONS. MENU_EXTRA_1 and EXTRA_2 are the only spare
    -- footer actions in the game (5.64), so a page cannot have four buttons -- it
    -- can only have two at a time, and which two is the view's business.
    local sellRules = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = l10n("ar_hi_btn_sellRules", "Sell Rules"),
        callback = function()
            local pg = HerdInspectorPage._page
            if pg ~= nil then pg:openSellRules() end
        end,
        showWhenPaused = true,
    }
    local buyRules = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = l10n("ar_hi_btn_buyRules", "Buy Rules"),
        callback = function()
            local pg = HerdInspectorPage._page
            if pg ~= nil then pg:openBuyRules() end
        end,
        showWhenPaused = true,
    }
    -- THE FIVE DEFINITIONS, not two fixed sets. Which of them a view shows is
    -- decided in buildButtonSet, per call, because AnimalSettings can switch the
    -- trading pair off while this page is open -- and a set frozen at install
    -- could never learn that.
    HerdInspectorPage._buttons = {
        back      = back,
        trade     = trade,
        schedule  = schedule,
        sellRules = sellRules,
        buyRules  = buyRules,
    }
    HerdInspectorPage._menu = menu
    local buttons = buildButtonSet("trade")
    -- TWO ICONS, BECAUSE THE TAB IS TWO VIEWS. The animals slice is the page's
    -- subject and carries the tab; the buildings slice -- DR's own Silos tab icon
    -- -- rides in the corner for the BARN view. It used to wear the STATISTICS
    -- icon, which was never a description of this page: it was chosen only so the
    -- second tab did not clash with the animals tab beside it, and that tab has
    -- been retired (20.28), so the icon that actually means "animals" is free.
    --
    -- badgeSliceId is OPTIONAL and needs DR API v7. An older DR ignores the extra
    -- argument entirely, so the tab simply carries the animals icon alone rather
    -- than failing to install -- which is why this is not gated on the version.
    local ok = SD.API.addMenuPage(menu, page, nil, "gui.icon_ingameMenu_animals",
                                  l10n("ar_hi_tab_title", "Herd Inspector"),
                                  function() return true end,
                                  buttons,
                                  "gui.icon_construction_buildings")
    if not ok then return false, "addMenuPage refused" end

    HerdInspectorPage._page = page
    return true
end
