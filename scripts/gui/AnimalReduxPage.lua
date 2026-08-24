-- ============================================================================
-- AnimalReduxPage.lua  (Animal Redux) -- the "Animals" tab in DR's menu
--
-- Two panes, matching DR's building tabs. Left: every husbandry with the
-- production factor the ENGINE reports for it right now. Right: the selected
-- barn's food groups, one row each, showing which is short and by how much.
--
-- WHY BOTH AN ENGINE AND A MODEL FIGURE. The engine number is the truth --
-- measured through the real consumeFood, the same call the game scales
-- production by. The model number is Animal Redux's prediction. They should
-- agree; where they do not, the model is wrong and wants looking at. Keeping
-- them side by side is what would have caught the quantity-sensitivity on day
-- one instead of it surfacing from a player noticing sorghum was not moving.
--
-- THE CLASS IS BUILT AT INSTALL TIME, NOT AT CHUNK LOAD. It extends DR's
-- DistributionMenuPage, and DR's environment does not exist when this file is
-- sourced: mods load alphabetically and FS25_Animal_Redux comes first. Methods
-- are defined on a plain table here and the inheritance is wired in install().
--
-- MEASURING IS SAFE. consumeFood does not remove food -- it fills a table and
-- returns a factor, and the caller applies the removal. AnimalFeedModel
-- .measureFactor snapshots and restores fillLevels on every path. Here the mix
-- IS the current trough, so the values written back are the ones already there.
-- ============================================================================

AnimalReduxPage = {}

local SUMMARY_NONE = "ar_sum_none"

-- ---------------------------------------------------------------------------
local function l10n(key, fallback)
    if AnimalRedux ~= nil and AnimalRedux.l10n ~= nil then return AnimalRedux.l10n(key, fallback) end
    return fallback
end

---Volumes through DR's own formatter, so this tab reads like every other one
-- (litres below 1,000, kilolitres above). Falls back to plain litres.
local function vol(v)
    local SD = AnimalRedux ~= nil and AnimalRedux.DR or nil
    if SD ~= nil and SD.formatVolume ~= nil then
        local ok, s = pcall(SD.formatVolume, v)
        if ok and s ~= nil then return s end
    end
    return string.format("%.0f L", v or 0)
end

local function ftName(ft)
    local m = g_fillTypeManager
    if m ~= nil and m.getFillTypeNameByIndex ~= nil then
        local ok, n = pcall(m.getFillTypeNameByIndex, m, ft)
        if ok and n ~= nil then return tostring(n) end
    end
    return "?"
end

-- Red below this share of a group's need, amber below the next. A group at or
-- near its need is the healthy case and stays white.
local MET_BAD, MET_WARN = 0.01, 0.95
local function setColour(cell, met)
    if cell == nil or cell.setTextColor == nil then return end
    -- Cells are RECYCLED by SmoothList, so the healthy path must ACTIVELY reset
    -- to white or a row inherits the colour of whatever row last used that slot.
    if met < MET_BAD then          cell:setTextColor(0.85, 0.20, 0.20, 1)
    elseif met < MET_WARN then     cell:setTextColor(0.95, 0.65, 0.15, 1)
    else                           cell:setTextColor(1, 1, 1, 1) end
end

-- ---------------------------------------------------------------------------
-- DATA
-- ---------------------------------------------------------------------------

---Everything the tab shows for one husbandry, read live.
local function readBarn(p)
    local spec = p.spec_husbandryFood
    if spec == nil or AnimalFeedModel == nil then return nil end

    local name = "?"
    local okN, n = pcall(function() return p:getName() end)
    if okN and n ~= nil then name = tostring(n) end

    local ati = AnimalFeedModel.animalTypeIndexOf(p)
    if ati == nil then return nil end
    local model = AnimalFeedModel.read(ati, spec.supportedFillTypes)

    -- The barn's REAL appetite. Measuring at anything else misreports a healthy
    -- trough as starved, which an earlier version of the console probe did.
    local demand = AnimalFeedModel.demandPerHour(p)
    local hasAnimals = demand > 0

    -- WHAT THE ANIMALS CAN EAT, not merely what has been delivered. A grazing barn
    -- has meadow grass that never reaches the trough (measured: a cow barn holding
    -- only hay and silage still reported 828 L of grass available), and showing 0
    -- against an engine factor of 0.40 was the contradiction that exposed it.
    local everyFt = {}
    if model ~= nil then
        for _, g in ipairs(model.groups) do
            for _, ft in ipairs(g.fts) do everyFt[#everyFt + 1] = ft end
        end
    end
    local trough, held = AnimalFeedModel.availableOf(p, everyFt)
    local delivered = select(2, AnimalFeedModel.troughOf(p))   -- trough alone, for the summary
    local engine, modelF = nil, nil
    if model ~= nil and hasAnimals then
        engine = select(1, AnimalFeedModel.measureFactor(p, ati, trough, demand))
        modelF = AnimalFeedModel.factorOf(model, trough, demand)
    end

    local groups = {}
    if model ~= nil then
        local eatSum = 0
        for _, g in ipairs(model.groups) do eatSum = eatSum + g.eat end
        for _, g in ipairs(model.groups) do
            local gHeld = 0
            for _, ft in ipairs(g.fts) do gHeld = gHeld + (trough[ft] or 0) end
            -- SERIAL: one tier feeds the whole herd, so its need is the full demand.
            -- PARALLEL: each group supplies its eat share.
            local need = 0
            if hasAnimals then
                if model.consumptionType == "SERIAL" then need = demand
                elseif eatSum > 0 then need = demand * g.eat / eatSum end
            end
            local met = 1
            if need > 0 then met = math.min(1, gHeld / need) end
            local names = {}
            for _, ft in ipairs(g.fts) do
                if spec.supportedFillTypes == nil or spec.supportedFillTypes[ft] ~= nil then
                    names[#names + 1] = ftName(ft)
                end
            end
            groups[#groups + 1] = {
                title = g.title, need = need, held = gHeld, met = met,
                contributes = g.production * met, max = g.production,
                accepts = table.concat(names, ", "),
            }
        end
    end

    -- ---- PRODUCTIVITY, the base game's own headline -------------------------
    -- productivity = globalProductionFactor x productionFactor, exactly as
    -- PlaceableHusbandryAnimals:getConditionInfos computes it. This is NOT the
    -- food factor: food is one input to it, so a barn can be perfectly fed and
    -- still be at 60% for a reason nothing else on this tab would show.
    --
    -- The base game HIDES this for horses and pigs (they do not produce
    -- continuously), so it is flagged rather than silently presented as
    -- meaningful for them.
    local prod = nil
    if p.getGlobalProductionFactor ~= nil and p.getProductionFactor ~= nil then
        local okG, gf = pcall(p.getGlobalProductionFactor, p)
        local okP, pf = pcall(p.getProductionFactor, p)
        if okG and okP and type(gf) == "number" and type(pf) == "number" then
            prod = gf * pf
        end
    end
    local prodApplies = true
    if AnimalType ~= nil and ati ~= nil then
        prodApplies = (ati ~= AnimalType.HORSE and ati ~= AnimalType.PIG)
    end

    -- ---- HERD: how many, and how healthy ------------------------------------
    local numAnimals, maxAnimals, health = nil, nil, nil
    if p.getNumOfAnimals ~= nil then
        local okN, v = pcall(p.getNumOfAnimals, p); if okN then numAnimals = v end
    end
    if p.getMaxNumOfAnimals ~= nil then
        local okM, v = pcall(p.getMaxNumOfAnimals, p); if okM then maxAnimals = v end
    end
    if p.getClusters ~= nil then
        local okC, clusters = pcall(p.getClusters, p)
        if okC and type(clusters) == "table" and #clusters > 0 then
            health = AnimalReduxPage.herdHealthFactor(clusters)
        end
    end

    -- ---- THE GAME'S OWN CONDITION LIST --------------------------------------
    -- One call gives water, bedding, output stores and productivity, already
    -- titled and normalised, from six specs at once. Rendered generically, so an
    -- entry this mod has never heard of (a modded husbandry's own) still shows.
    local conditions = {}
    if p.getConditionInfos ~= nil then
        local okI, infos = pcall(p.getConditionInfos, p)
        if okI and type(infos) == "table" then
            for _, i in ipairs(infos) do
                if type(i) == "table" then
                    conditions[#conditions + 1] = {
                        title = tostring(i.title or "?"),
                        value = tonumber(i.value),
                        valueText = i.valueText,
                        ratio = tonumber(i.ratio),
                        -- invertedBar means a HIGH reading is the bad one, which is
                        -- how a backing-up output store is expressed
                        inverted = i.invertedBar == true,
                    }
                end
            end
        end
    end

    local SD = AnimalRedux ~= nil and AnimalRedux.DR or nil
    local uid = (SD ~= nil and SD.assetUid ~= nil) and SD.assetUid(p) or tostring(p)

    -- A MEADOW IS A FOOD SOURCE THE TROUGH DOES NOT SHOW. PlaceableHusbandryMeadow
    -- overrides getAvailableFood / removeFood / getFoodInfos, so grazed grass
    -- reaches consumeFood without ever passing through spec_husbandryFood
    -- .fillLevels. That is why a cow barn can read every group at 0 L and still
    -- score 0.40: the herd is eating the pasture, and 0.40 is the Grass tier.
    -- Reported rather than hidden -- the numbers are right, they just are not the
    -- whole story, and a contradiction on screen is worse than a caveat.
    local grazes = p.spec_husbandryMeadow ~= nil

    return { placeable = p, uid = uid, name = name, model = model, demand = demand,
             hasAnimals = hasAnimals, held = held, delivered = delivered,
             engine = engine, modelF = modelF, grazes = grazes, groups = groups,
             prod = prod, prodApplies = prodApplies, numAnimals = numAnimals,
             maxAnimals = maxAnimals, health = health, conditions = conditions }
end

function AnimalReduxPage:rebuild()
    self.barns = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    -- THIS FARM'S BUILDINGS ONLY. Walking every placeable with a food spec listed
    -- husbandries that belong to the MAP, not the player: three "Shed With Open
    -- Chicken Pasture" turned up that are nowhere on the farm (and appear in no
    -- savegame -- they are map-embedded). DR would never feed them, so a tab
    -- about whether DR is feeding things correctly must not show them.
    --
    -- Both tests are DR's own, so this tab shows exactly the set DR manages:
    --   isAssetEnrolled  participation, and the Animal Husbandry class toggle
    --   _farmCanUse      ownership, including the public-map-storage rule (5.63)
    -- Each fails OPEN if DR does not expose it, so a version mismatch shows too
    -- much rather than an empty tab.
    local SD = AnimalRedux ~= nil and AnimalRedux.DR or nil
    local myFarm = (SD ~= nil and SD._playerFarmId ~= nil) and SD._playerFarmId() or nil

    local seen = {}
    for _, p in ipairs(ps.placeables) do
        -- ONE ROW PER PLACEABLE. Guarding on identity rather than trusting the
        -- list: a building appearing twice here would be a counting fault, and
        -- silently showing it twice is exactly the sort of thing that gets
        -- mistaken for the farm really having two of them.
        if p.spec_husbandryFood ~= nil and seen[p] == nil then
            local enrolled = SD == nil or SD.isAssetEnrolled == nil or SD.isAssetEnrolled(p)
            local usable   = myFarm == nil or SD == nil or SD._farmCanUse == nil
                             or SD._farmCanUse(p, myFarm)
            if enrolled and usable then
                seen[p] = true
                local b = readBarn(p)
                if b ~= nil then self.barns[#self.barns + 1] = b end
            end
        end
    end

    -- DUPLICATE NAMES get a " (n)" suffix, DR's convention (CLAUDE.md 5.7). Three
    -- buildings called "Shed With Open Chicken Pasture" are indistinguishable
    -- otherwise, and the reasonable reading of three identical rows is that
    -- something is listing one building three times.
    --
    -- Numbered by uniqueId, NOT by position in this list, so a building keeps its
    -- number as others are built or demolished around it.
    local byName = {}
    for _, b in ipairs(self.barns) do
        local g = byName[b.name]
        if g == nil then g = {}; byName[b.name] = g end
        g[#g + 1] = b
    end
    for name, group in pairs(byName) do
        if #group > 1 then
            table.sort(group, function(x, y) return tostring(x.uid) < tostring(y.uid) end)
            for i, b in ipairs(group) do b.name = string.format("%s (%d)", name, i) end
        end
    end

    table.sort(self.barns, function(a, b) return a.name < b.name end)

    -- SELECTION FOLLOWS THE BUILDING, not the row number. This list is rebuilt on
    -- every refresh tick, and a barn being built or demolished would otherwise
    -- slide a different one under the player's selection (the same reason DR's
    -- Overview matches double-clicks on identity rather than index, 5.37).
    self.selectedBarn = 1
    if self.selectedUid ~= nil then
        for i, b in ipairs(self.barns) do
            if b.uid == self.selectedUid then self.selectedBarn = i; break end
        end
    end
    local sel = self.barns[self.selectedBarn]
    self.selectedUid = sel ~= nil and sel.uid or nil
    self.rows = (sel or {}).groups or {}
    self.conds = (sel or {}).conditions or {}

    -- built EVERY rebuild, not only when their view is showing: the Trade view
    -- reads the herd totals the cluster pass computes, and the summary strip
    -- wants them whichever pane is up.
    local clRows, herd = self:buildClusterRows(sel)
    self.clusterRows = clRows
    self._herd = herd

    -- The PLAN walks the clusters again and, the first time it meets a subtype,
    -- clone-sweeps a price curve out of the running game. That is cheap and
    -- cached, but it is work no other view needs -- so only the Trade view pays,
    -- the same reasoning as _realtimeLists.
    if self:viewIndexSafe() == AnimalReduxPage.VIEW_TRADE then
        self.tradeRows = self:buildTradeRows(sel, herd)
    end
end

---Called by DR's paced refresh for pages that CACHE their figures -- which this
-- one does, in self.barns. Without it the tab would show whatever it read when
-- it was opened and never move again.
--
-- One engine measureFactor per barn per refresh. That is the cost of the ENGINE
-- column being the truth rather than an opinion, and DR's duty-cycle limiter
-- measures the whole refresh and stretches the interval if it gets expensive, so
-- it is self-limiting on a big farm.
function AnimalReduxPage:rebuildRealtimeData()
    self:rebuild()
    self:updateSummary()
end

function AnimalReduxPage:updateSummary()
    if self.summaryLine == nil then return end
    local b = self.barns ~= nil and self.barns[self.selectedBarn] or nil
    if b == nil then
        self.summaryLine:setText(l10n(SUMMARY_NONE, "No animal husbandry on this farm."))
        return
    end
    if not b.hasAnimals then
        self.summaryLine:setText(string.format(
            l10n("ar_sum_noAnimals", "%s  -  no animals, so nothing is being fed"), b.name))
        return
    end
    self.summaryLine:setText(string.format(
        l10n("ar_sum_line", "%s  -  %s  -  eats %.1f L/h  -  trough %s  -  ENGINE %.4f  -  model %.4f%s"),
        b.name,
        (b.model ~= nil and b.model.consumptionType or "?"),
        b.demand,
        (b.grazes and b.held > b.delivered + 0.5)
            and string.format("%s (%s delivered + grazing)", vol(b.held), vol(b.delivered))
            or vol(b.held),
        b.engine or 0, b.modelF or 0,
        (b.engine ~= nil and b.modelF ~= nil and math.abs(b.engine - b.modelF) > 0.02)
            and l10n("ar_sum_disagree", "   <<< MODEL DISAGREES") or "")
        -- Appended rather than folded into the format string: each part is
        -- conditional, and a format with six optional slots is unreadable in a
        -- translation file.
        .. ((b.numAnimals ~= nil and b.maxAnimals ~= nil)
            and string.format(l10n("ar_sum_herd", "   -  %d/%d animals"),
                              b.numAnimals, b.maxAnimals) or "")
        .. ((b.health ~= nil)
            and string.format(l10n("ar_sum_health", " at %d%% health"),
                              math.floor(b.health * 100 + 0.5)) or "")
        -- PRODUCTIVITY is the base game's own headline and is NOT the food factor
        -- printed above it. Both are shown so "fed perfectly but only 60%
        -- productive" is visible as the distinct situation it is.
        .. ((b.prod ~= nil and b.prodApplies)
            and string.format(l10n("ar_sum_prod", "   -  PRODUCTIVITY %d%%"),
                              math.floor(b.prod * 100 + 0.5)) or "")
        .. (b.grazes and l10n("ar_sum_grazes",
            "   -  GRAZES A MEADOW: pasture grass feeds these animals without appearing in the trough")
            or ""))
end

-- ---------------------------------------------------------------------------
-- CLUSTER + TRADE ROWS
--
-- Everything here rests on what arReproProbe measured (CLAUDE.md 11.9 / 11.11):
--   reproduction climbs by 100/durationMonth each period; at >= 100 the whole
--   cluster births ONE OFFSPRING PER ANIMAL and resets to 0. Both gates are
--   cliffs: below minHealthFactor (0.75) or below minAgeMonth nothing happens
--   AND the counter is not even advanced, so an underfed herd is frozen rather
--   than losing progress.
--
-- The gates are therefore checked in the same order the engine checks them, and
-- "no room" is reported LAST -- because it is the only one of the three that
-- destroys anything. A gated cluster is paused and fully recoverable; a cluster
-- that breeds into a full pen loses the calves AND the months that made them.
-- ---------------------------------------------------------------------------

local function money(v)
    if v == nil then return "-" end
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, s = pcall(g_i18n.formatMoney, g_i18n, v, 0, true, true)
        if ok and s ~= nil then return tostring(s) end
    end
    return string.format("%d", math.floor((v or 0) + 0.5))
end

---Herd health as a FACTOR (0..1), weighted by headcount.
--
-- WEIGHTED because a cluster is a GROUP, not an animal: a cluster of one sick
-- beast must not count for as much as a cluster of two hundred healthy ones.
-- (It makes no difference on horses, where the game gives every animal its own
-- cluster, and a great deal on everything else.)
--
-- 0..1 because that is the unit of every other factor on the barn record
-- (engine, modelF, prod), while the raw cluster field is 0..100. Mixing the two
-- is exactly how the Trade view came to print 10000%: the summary line and the
-- trade row each multiplied an already-percent figure by 100 again. The unit now
-- lives in the NAME -- `health` is a factor, `healthPct` on a cluster row is the
-- raw percentage.
--
-- A FIELD rather than an inline block inside readBarn, deliberately: the bug
-- shipped because this arithmetic sat in a function that needs half the mod to
-- construct, so nothing could drive it. Here a harness can.
function AnimalReduxPage.herdHealthFactor(clusters)
    if type(clusters) ~= "table" then return nil end
    local sum, counted = 0, 0
    for _, c in ipairs(clusters) do
        local n = c.numAnimals or 0
        sum = sum + (c.health or 0) * n
        counted = counted + n
    end
    if counted <= 0 then return nil end
    return (sum / counted) / 100
end

local function subTypeOf(sti)
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil or asys.getSubTypeByIndex == nil or sti == nil then return nil end
    local ok, st = pcall(asys.getSubTypeByIndex, asys, sti)
    if ok and type(st) == "table" then return st end
    return nil
end

---One row per cluster of the selected barn, plus the herd totals the Trade view
-- reads back off self._herd.
function AnimalReduxPage:buildClusterRows(b)
    local rows = { }
    -- lowHealth and noRoom are counted SEPARATELY: one is a pause that costs
    -- nothing and recovers fully, the other destroys animals. Folding them
    -- into one 'blocked' figure would report them as the same problem.
    local herd = { value = 0, atFullHealth = 0, births = 0, breeding = 0,
                   lowHealth = 0, noRoom = 0 }
    if b == nil or b.placeable == nil then return rows, herd end

    local p = b.placeable
    if p.getClusters == nil then return rows, herd end
    local okC, clusters = pcall(p.getClusters, p)
    if not okC or type(clusters) ~= "table" then return rows, herd end

    local free = 0
    if p.getNumOfFreeAnimalSlots ~= nil then
        local okF, f = pcall(p.getNumOfFreeAnimalSlots, p)
        if okF and type(f) == "number" then free = f end
    end
    -- free slots are consumed by the clusters in order (PlaceableHusbandryAnimals
    -- :onPeriodChanged decrements as it goes), so the same order is walked here
    local remaining = free

    for _, cl in pairs(clusters) do
        local n     = cl.numAnimals or 0
        local age   = cl.age or 0
        local hp    = cl.health or 0            -- 0..100
        local st    = subTypeOf(cl.subTypeIndex)
        local each  = nil
        if cl.getSellPrice ~= nil then
            local okP, v = pcall(cl.getSellPrice, cl)
            if okP and type(v) == "number" then each = v end
        end
        local total = (each ~= nil) and (each * n) or nil

        -- what the SAME animals would fetch fed properly. price scales exactly
        -- 0.40 + 0.60h (CLAUDE.md 11.1), so the full health figure is a ratio of
        -- the current one and needs no price curve.
        local hFactor = 0.40 + 0.60 * (hp / 100)
        local full = (each ~= nil and hFactor > 0) and (each / hFactor * n) or nil

        local minAge  = st ~= nil and st.reproductionMinAgeMonth or nil
        local minH    = st ~= nil and st.reproductionMinHealth or nil
        local dur     = st ~= nil and st.reproductionDurationMonth or nil
        local repro   = cl.reproduction or 0

        local status, birth = l10n("ar_st_breeding", "Breeding"), "-"
        local warn = false
        if minAge ~= nil and age < minAge then
            status = string.format(l10n("ar_st_tooYoung", "Too young (%d mo)"), minAge)
            birth  = l10n("ar_birth_paused", "paused")
        elseif minH ~= nil and (hp / 100) < minH then
            status = string.format(l10n("ar_st_lowHealth", "Health below %d%%"),
                                   math.floor(minH * 100 + 0.5))
            birth  = l10n("ar_birth_paused", "paused")
            warn   = true
            herd.lowHealth = herd.lowHealth + n
        else
            -- it WILL breed. Does the pen have room for one offspring per animal?
            if n > remaining then
                status = string.format(l10n("ar_st_noRoom", "NO ROOM: %d lost"), n - remaining)
                warn   = true
                herd.noRoom = herd.noRoom + (n - remaining)
            end
            herd.breeding = herd.breeding + n
            herd.births   = herd.births + n
            if dur ~= nil and dur > 0 then
                local step = 100 / dur
                local need = math.max(0, 100 - repro)
                local periods = math.ceil(need / step)
                if periods <= 0 then periods = 1 end
                birth = string.format(l10n("ar_birth_in", "in %d mo"), periods)
            end
            remaining = math.max(0, remaining - n)
        end
        herd.value = herd.value + (total or 0)
        herd.atFullHealth = herd.atFullHealth + (full or 0)

        rows[#rows + 1] = {
            animal = (st ~= nil and tostring(st.name) or "?"),
            count  = n,
            age    = age,
            healthPct = hp,          -- RAW 0..100, unlike the barn's 0..1 factor
            each   = each,
            total  = total,
            birth  = birth,
            status = status,
            warn   = warn,
        }
    end

    table.sort(rows, function(x, y)
        if x.animal ~= y.animal then return x.animal < y.animal end
        return (x.age or 0) > (y.age or 0)
    end)
    return rows, herd
end

---SCAFFOLDING. These are the decision inputs the sell rules will read; the rules
-- themselves are not written. Stated as facts rather than settings so the view
-- is honest about being unfinished instead of showing controls that do nothing.
function AnimalReduxPage:buildTradeRows(b, herd)
    local rows = {}
    local function row(factor, value, meaning, warn)
        rows[#rows + 1] = { factor = factor, value = value, meaning = meaning, warn = warn }
    end
    if b == nil then return rows end

    local free = (b.maxAnimals or 0) - (b.numAnimals or 0)
    if free < 0 then free = 0 end

    row(l10n("ar_tr_capacity", "Pen capacity"),
        string.format("%d / %d", b.numAnimals or 0, b.maxAnimals or 0),
        string.format(l10n("ar_tr_capacityM", "%d free slot(s)"), free), free == 0)

    row(l10n("ar_tr_births", "Births next cycle"),
        string.format("%d", herd.births or 0),
        (herd.births or 0) == 0
            and l10n("ar_tr_birthsNone", "nothing is breeding right now")
            or ((herd.noRoom or 0) > 0
                and string.format(l10n("ar_tr_birthsLost",
                    "%d would be DISCARDED, and the gestation spent with them"),
                    herd.noRoom)
                or l10n("ar_tr_birthsFit", "the pen has room for all of them")),
        (herd.noRoom or 0) > 0)

    -- THE GATE IS PER CLUSTER, so an AVERAGE cannot answer it: a barn of 200
    -- healthy animals and 10 starving ones averages well above 0.75 while ten
    -- animals are gated. The average is still shown, because it is what the herd
    -- is worth (price scales on each animal's own health), but the VERDICT comes
    -- from the per cluster pass, which counts the animals actually gated.
    local gated = herd.lowHealth or 0
    row(l10n("ar_tr_health", "Herd health"),
        string.format("%d%%", math.floor((b.health or 0) * 100 + 0.5)),
        gated > 0
            and string.format(l10n("ar_tr_healthLow",
                "%d animal(s) below the 75%% breeding gate: paused, but NOT losing progress"),
                gated)
            or l10n("ar_tr_healthOk", "every animal is above the 75% breeding gate"),
        gated > 0)

    row(l10n("ar_tr_value", "Herd value now"),
        money(herd.value),
        l10n("ar_tr_valueM", "what the whole barn would fetch at today's health"), false)

    local gap = (herd.atFullHealth or 0) - (herd.value or 0)
    row(l10n("ar_tr_valueFull", "Value at full health"),
        money(herd.atFullHealth),
        gap > 1
            and string.format(l10n("ar_tr_valueGap", "%s recoverable by feeding alone"), money(gap))
            or l10n("ar_tr_valueNoGap", "already at full value"),
        gap > 1)

    -- ---- WHAT THE RULES WOULD DO ---------------------------------------
    -- READ ONLY. Nothing here sells anything: the plan is computed and shown, and
    -- the player acts through Buy / Sell, which opens the game's own screen.
    local plan = nil
    if AnimalSellRules ~= nil and AnimalSellRules.plan ~= nil and b.placeable ~= nil then
        local okP, pl = pcall(AnimalSellRules.plan, b.placeable, nil)
        if okP and type(pl) == "table" then plan = pl end
    end
    if plan == nil then
        -- The engine is a separate sourceFile and could be absent or have thrown.
        -- Say so rather than quietly showing five facts and no recommendation --
        -- an absent verdict is indistinguishable from "nothing to do".
        row(l10n("ar_tr_rules", "Sell rules"),
            l10n("ar_tr_rulesNA", "unavailable"),
            l10n("ar_tr_rulesNAM", "the sell rules module did not load, so no recommendation is shown"),
            true)
        return rows
    end

    for _, ln in ipairs(plan.lines or {}) do
        local headroom = (ln.reason == AnimalSellRules.REASON_HEADROOM)
        row(string.format(l10n("ar_tr_sell", "SELL %d x %s"), ln.count, ln.name),
            money(ln.revenue),
            headroom
                and l10n("ar_tr_whyHeadroom",
                    "headroom: these slots are needed or next cycle's births are destroyed")
                or l10n("ar_tr_whyPeak",
                    "past peak: worth less every month it is kept, and holding gains nothing"),
            headroom)
    end

    if (plan.total or 0) > 0 then
        row(l10n("ar_tr_total", "Recommended total"),
            string.format(l10n("ar_tr_totalHead", "%d head"), plan.total),
            string.format(l10n("ar_tr_totalM", "%s at today's prices"), money(plan.revenue)),
            false)
    else
        row(l10n("ar_tr_total", "Recommended total"),
            l10n("ar_tr_nothing", "sell nothing"),
            l10n("ar_tr_nothingM", "the pen has room and nothing is past its peak"),
            false)
    end

    -- Notes carry FIGURES, not sentences -- the engine is pure and does not know
    -- what language this is. Formatting and localising them is the GUI's job.
    for _, n in ipairs(plan.notes or {}) do
        local text, warn = nil, false
        if n.kind == "held" then
            text = string.format(l10n("ar_tr_noteHeld",
                "peak sales held: at %d%% health these would realise %d%% of book value"),
                n.healthPct or 0, n.realisePct or 0)
        elseif n.kind == "blocked" then
            text = string.format(l10n("ar_tr_noteBlocked",
                "still %d slot(s) short: the breeder floor of %d blocks any further sale"),
                n.short or 0, n.keepBreeders or 0)
            warn = true
        elseif n.kind == "info" then
            text = string.format(l10n("ar_tr_noteLost",
                "%d birth(s) would still be discarded next cycle"), n.lost or 0)
            warn = true
        end
        if text ~= nil then row(l10n("ar_tr_note", "Note"), "", text, warn) end
    end

    row(l10n("ar_tr_rules", "Sell rules"),
        l10n("ar_tr_rulesValue", "read only"),
        l10n("ar_tr_rulesM",
            "nothing is sold automatically. Buy / Sell opens the game's own screen for this barn."),
        false)
    return rows
end

-- ============================================================================
-- VIEWS. One tab, one barn list, three right hand panes.
--
-- The left pane never changes: all three views answer a question about the SAME
-- selected barn, so they are not peers of it, they are children of it. Three
-- separate TABS would have meant three copies of the barn list with a different
-- right hand side, which is a view switch pretending to be navigation.
--
-- Mechanically this follows DR's Overview (its Show Settings / Show Flows
-- toggle): a second and third header + list declared in the XML, swapped by
-- setVisible, with activeList() as the SINGLE place that decides which one
-- reloads so the panes cannot drift apart. _realtimeLists follows the toggle, or
-- DR's paced refresh keeps repopulating a hidden pane.
-- ============================================================================

AnimalReduxPage.VIEW_FEED, AnimalReduxPage.VIEW_CLUSTERS, AnimalReduxPage.VIEW_TRADE = 1, 2, 3

function AnimalReduxPage:viewIndexSafe()
    local v = self.viewIndex
    if type(v) ~= "number" or v < 1 or v > 3 then return AnimalReduxPage.VIEW_FEED end
    return v
end

function AnimalReduxPage:initViewOption()
    self.viewIndex = self:viewIndexSafe()
    local o = self.viewOption
    if o == nil or o.setTexts == nil then return end
    o:setTexts({
        l10n("ar_view_feed",     "View: Feed"),
        l10n("ar_view_clusters", "View: Animals"),
        l10n("ar_view_trade",    "View: Trade"),
    })
    if o.setState ~= nil then pcall(function() o:setState(self.viewIndex) end) end
end

function AnimalReduxPage:onViewChanged(state)
    local o = self.viewOption
    if type(state) ~= "number" and o ~= nil and o.getState ~= nil then state = o:getState() end
    if type(state) == "number" and state >= 1 and state <= 3 then self.viewIndex = state end
    self:applyView()
end

---The one place that decides which list is on screen. Every reload goes through
-- it, so the three panes cannot get out of step with the selector.
function AnimalReduxPage:activeList()
    local v = self:viewIndexSafe()
    if v == AnimalReduxPage.VIEW_CLUSTERS then return self.clusterList end
    if v == AnimalReduxPage.VIEW_TRADE then return self.tradeList end
    return self.groupList
end

function AnimalReduxPage:applyView()
    local v = self:viewIndexSafe()
    local feed  = (v == AnimalReduxPage.VIEW_FEED)
    local clust = (v == AnimalReduxPage.VIEW_CLUSTERS)
    local trade = (v == AnimalReduxPage.VIEW_TRADE)

    local function vis(el, show)
        if el ~= nil and el.setVisible ~= nil then pcall(function() el:setVisible(show) end) end
    end
    -- the FEED view is two stacked tables; both halves move together
    vis(self.feedHeaderRow,    feed)
    vis(self.groupList,        feed)
    vis(self.condHeaderRow,    feed)
    vis(self.conditionList,    feed)
    vis(self.clusterHeaderRow, clust)
    vis(self.clusterList,      clust)
    vis(self.tradeHeaderRow,   trade)
    vis(self.tradeList,        trade)

    -- DR's paced refresh repopulates whatever is in here. Leaving a hidden
    -- pane listed would pay for cells nobody can see.
    if feed then
        self._realtimeLists = { "barnList", "groupList", "conditionList" }
    elseif clust then
        self._realtimeLists = { "barnList", "clusterList" }
    else
        self._realtimeLists = { "barnList", "tradeList" }
    end

    self:updateViewButtons()
    self:rebuild()
    if self.barnList ~= nil then self.barnList:reloadData() end
    local l = self:activeList()
    if l ~= nil then l:reloadData() end
    -- the feed view's SECOND table is not the active list and would otherwise
    -- keep whatever the previous barn left in it
    if feed and self.conditionList ~= nil then self.conditionList:reloadData() end
    self:updateSummary()
end

---Buy / Sell belongs to the Trade view alone. The footer is re-assigned rather
-- than relabelled, so the other two views are not carrying a button that would
-- open a screen having nothing to do with what is on them.
function AnimalReduxPage:updateViewButtons()
    local all = self._allButtons
    if all == nil or self.applyFooterButtons == nil then return end
    local trade = (self:viewIndexSafe() == AnimalReduxPage.VIEW_TRADE)
    local vis = {}
    for _, b in ipairs(all) do
        if b._role ~= "buySell" or trade then vis[#vis + 1] = b end
    end
    self:applyFooterButtons(vis)
end

---Open the BASE GAME's own animal screen for the selected barn.
--
-- CONFIRMED IN GAME: setController(husbandry, nil, true) then
-- showGui("AnimalScreen") opens the dealer screen scoped to that barn, with a
-- buy tab and a sell tab. So there is nothing to reimplement: no price table,
-- no money handling, no multiplayer event.
--
-- setController is pcall'd and the screen is shown ONLY if it succeeded. A half
-- set controller followed by a shown screen is how a GUI ends up throwing on
-- every frame, and an extension must not be able to do that to the game.
function AnimalReduxPage:onBuySell()
    local b = self.barns ~= nil and self.barns[self.selectedBarn] or nil
    if b == nil or b.placeable == nil then return end
    if g_animalScreen == nil or g_animalScreen.setController == nil then return end
    local ok = pcall(function() g_animalScreen:setController(b.placeable, nil, true) end)
    if not ok then return end
    if g_gui ~= nil and g_gui.showGui ~= nil then pcall(g_gui.showGui, g_gui, "AnimalScreen") end
end

-- ---------------------------------------------------------------------------
-- FRAME
-- ---------------------------------------------------------------------------
function AnimalReduxPage:onGuiSetupFinished()
    AnimalReduxPage:superClass().onGuiSetupFinished(self)
    for _, id in ipairs({ "barnList", "groupList", "conditionList",
                          "clusterList", "tradeList" }) do
        local list = self[id]
        if list ~= nil then
            list:setDataSource(self)
            list:setDelegate(self)
        end
    end
end

function AnimalReduxPage:onFrameOpen()
    AnimalReduxPage:superClass().onFrameOpen(self)
    -- applyView sets _realtimeLists (DR's paced tick repopulates whatever is in
    -- it), rebuilds, reloads and re-applies the footer -- so the view the player
    -- last chose survives leaving and re-entering the tab.
    self:initViewOption()
    self:applyView()
end

-- ---- SmoothList delegate (two lists, told apart by identity) ---------------
function AnimalReduxPage:getNumberOfItemsInSection(list, section)
    if list == self.barnList then return #(self.barns or {}) end
    if list == self.conditionList then return #(self.conds or {}) end
    if list == self.clusterList then return #(self.clusterRows or {}) end
    if list == self.tradeList then return #(self.tradeRows or {}) end
    return #(self.rows or {})
end

function AnimalReduxPage:populateCellForItemInSection(list, section, index, cell)
    -- EVERY cell is written on EVERY path, colour included. SmoothList RECYCLES
    -- cells, so a row that skips a field inherits whatever the previous row left
    -- there -- the trap DR hit twice, once with figures and once with colours.
    if list == self.clusterList then
        local r = (self.clusterRows or {})[index]
        if r == nil then return end
        local function setc(name, text, warn)
            local c = cell:getAttribute(name)
            if c == nil then return end
            if c.setText ~= nil then c:setText(text or "") end
            setColour(c, warn and 0 or 1)
        end
        setc("clAnimal", r.animal)
        setc("clCount",  string.format("%d", r.count or 0))
        setc("clAge",    string.format(l10n("ar_fmt_months", "%d mo"), r.age or 0))
        -- health drives up to 60% of the sale price AND gates breeding at 75%,
        -- so it is amber below the gate rather than only at zero
        local hc = cell:getAttribute("clHealth")
        if hc ~= nil then
            if hc.setText ~= nil then hc:setText(string.format("%d%%", r.healthPct or 0)) end
            setColour(hc, ((r.healthPct or 0) / 100 >= 0.75) and 1 or 0.5)
        end
        setc("clEach",   r.each ~= nil and money(r.each) or "-")
        setc("clTotal",  r.total ~= nil and money(r.total) or "-")
        setc("clBirth",  r.birth)
        setc("clStatus", r.status, r.warn)
        return
    end

    if list == self.tradeList then
        local r = (self.tradeRows or {})[index]
        if r == nil then return end
        local function setc(name, text, warn)
            local c = cell:getAttribute(name)
            if c == nil then return end
            if c.setText ~= nil then c:setText(text or "") end
            setColour(c, warn and 0 or 1)
        end
        setc("trFactor",  r.factor)
        setc("trValue",   r.value,   r.warn)
        setc("trMeaning", r.meaning, r.warn)
        return
    end

    if list == self.barnList then
        local b = (self.barns or {})[index]
        if b == nil then return end
        local nameCell = cell:getAttribute("barnName")
        if nameCell ~= nil then nameCell:setText(b.name) end
        local aCell = cell:getAttribute("barnAnimals")
        if aCell ~= nil then
            if b.numAnimals ~= nil and b.maxAnimals ~= nil then
                aCell:setText(string.format("%d/%d", b.numAnimals, b.maxAnimals))
                -- a FULL barn is not a fault, so it is never red; empty is just empty
                setColour(aCell, 1)
            else
                aCell:setText("-")
                setColour(aCell, 1)
            end
        end
        local pCell = cell:getAttribute("barnProd")
        if pCell ~= nil then
            if not b.hasAnimals or b.prod == nil then
                pCell:setText("-")
                setColour(pCell, 1)
            elseif not b.prodApplies then
                -- the base game does not use productivity for horses or pigs, so
                -- showing a bare number here would invite chasing a figure that
                -- drives nothing
                pCell:setText("n/a")
                setColour(pCell, 1)
            else
                pCell:setText(string.format("%.0f%%", b.prod * 100))
                setColour(pCell, b.prod)
            end
        end
        return
    end

    if list == self.conditionList then
        local c = (self.conds or {})[index]
        if c == nil then return end
        local nCell = cell:getAttribute("condName")
        if nCell ~= nil then nCell:setText(c.title) end
        local vCell = cell:getAttribute("condValue")
        if vCell ~= nil then
            vCell:setText(c.valueText or (c.value ~= nil and vol(c.value)) or "-")
        end
        local rCell = cell:getAttribute("condRatio")
        if rCell ~= nil then
            if c.ratio == nil then
                rCell:setText("-")
                setColour(rCell, 1)
            else
                rCell:setText(string.format("%.0f%%", c.ratio * 100))
                -- invertedBar means HIGH is the bad reading, which is how a
                -- backing-up output store is expressed. Colour accordingly, or a
                -- full slurry pit would read as healthy.
                setColour(rCell, c.inverted and (1 - c.ratio) or c.ratio)
            end
        end
        return
    end

    local g = (self.rows or {})[index]
    if g == nil then return end
    local function setc(attr, text)
        local c = cell:getAttribute(attr)
        if c ~= nil then c:setText(text) end
        return c
    end
    setc("groupName", g.title)
    setc("groupNeed", g.need > 0 and string.format("%.1f L/h", g.need) or "-")
    setc("groupHeld", vol(g.held))
    local metCell = setc("groupMet", string.format("%.0f%%", g.met * 100))
    setColour(metCell, g.met)
    setc("groupContrib", string.format("%.3f", g.contributes))
    setc("groupMax", string.format("%.3f", g.max))
    setc("groupAccepts", g.accepts)
end

function AnimalReduxPage:onListSelectionChanged(list, section, index)
    if list ~= self.barnList then return end
    local b = (self.barns or {})[index]
    self.selectedBarn = index
    self.selectedUid = b ~= nil and b.uid or nil    -- remembered by IDENTITY, so a refresh
                                                    -- cannot slide another barn underneath it
    self.rows = (b or {}).groups or {}
    self.conds = (b or {}).conditions or {}
    if self.groupList ~= nil then self.groupList:reloadData() end
    if self.conditionList ~= nil then self.conditionList:reloadData() end
    self:updateSummary()
end

-- ---------------------------------------------------------------------------
-- INSTALL -- called from AnimalRedux once DR's menu exists
-- ---------------------------------------------------------------------------
function AnimalReduxPage.install(menu)
    local SD  = AnimalRedux ~= nil and AnimalRedux.DR or nil
    local env = AnimalRedux ~= nil and AnimalRedux.DR_ENV or nil
    if SD == nil or env == nil or menu == nil then return false, "no DR menu" end

    local base = env.DistributionMenuPage
    if base == nil then return false, "DR's DistributionMenuPage not found" end
    if SD.API == nil or SD.API.loadMenuPage == nil or SD.API.addMenuPage == nil then
        return false, "DR's menu API is older than v3"
    end

    -- Wire the inheritance now that DR exists. Methods were defined above on the
    -- plain table; Class only attaches the metatables, so they survive.
    local mt = Class(AnimalReduxPage, base)
    AnimalReduxPage.new = function(target, custom_mt)
        local self = base.new(target, custom_mt or mt)
        self.pageName = "ANIMALREDUX_PAGE"
        self.barns, self.rows, self.selectedBarn = {}, {}, 1
        return self
    end

    local page = AnimalReduxPage.new()
    if not SD.API.loadMenuPage(page, "animalReduxPage",
                               AnimalRedux.MOD_DIR .. "gui/AnimalReduxPage.xml") then
        return false, "page XML failed to load"
    end

    -- APPENDED (position nil), not slotted in beside the Animal Husbandry tab
    -- where it would sit more naturally. PagingElement:addElement appends, and
    -- TabbedMenu:registerPage would insert at whatever position is asked for --
    -- so requesting one leaves the tab strip (which follows pageFrames order) and
    -- the paging element in DIFFERENT orders. Appending keeps them in step.
    -- Revisit only with a way to insert into both.
    --
    -- The icon is a base-game slice, which is why DR's helper is used rather than
    -- TabbedMenu:addPage: that one takes a texture file and UVs instead.
    -- Back plus Buy / Sell. Both are registered up front because the footer set
    -- is fixed at install time; updateViewButtons then FILTERS it per view, so
    -- Buy / Sell appears on the Trade view alone rather than sitting on the Feed
    -- view offering to open a screen unrelated to what is on it.
    local buttons = {
        SD.API.menuBackButton(menu),
        {
            inputAction = InputAction.MENU_EXTRA_1,
            text = l10n("ar_btn_buySell", "Buy / Sell"),
            callback = function()
                local pg = AnimalReduxPage._page
                if pg ~= nil and pg.onBuySell ~= nil then pg:onBuySell() end
            end,
            _role = "buySell",
        },
    }

    local ok = SD.API.addMenuPage(menu, page, nil, "gui.icon_ingameMenu_animals",
                                  l10n("ar_tab_animals", "Animal Redux"),
                                  function() return true end,
                                  buttons)
    if not ok then return false, "addMenuPage refused" end

    AnimalReduxPage._page = page
    return true
end
