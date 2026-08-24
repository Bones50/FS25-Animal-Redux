-- ============================================================================
-- AnimalFoodProbe.lua  (Animal Redux)  -- TEMPORARY DEV PROBE
--
-- Measures what the base game's AnimalFoodSystem:consumeFood actually rewards,
-- because it cannot be READ: AnimalFoodSystem is NOT in the shipped SDK source
-- (the only references anywhere are PlaceableHusbandryFood and MixerWagon), so
-- the mix -> production-factor curve is unreadable and has to be measured.
--
-- WHY IT MATTERS. PlaceableHusbandryFood:updateFeeding does:
--
--     factor = factor * animalFoodSystem:consumeFood(animalTypeIndex,
--                  litersPerHour * timeAdjustment, self, consumedFood)
--     for fillTypeIndex, delta in pairs(consumedFood) do
--         self:removeFood(delta, fillTypeIndex)
--     end
--
-- so production is SCALED by how well the trough matches the food groups, and
-- the base game renders each group's productionWeight as a PERCENTAGE of the mix
-- ("%s (%d%%)"). Distribution Redux instead treats productionWeight as a QUALITY
-- RANK and fills best-first. If the factor rewards a MIX, DR is suppressing
-- animal output on every multi-group feeder.
--
-- WHY SWEEPING IS SAFE. consumeFood does NOT remove food -- it fills the
-- `consumedFood` table and returns the factor, and the CALLER applies the
-- removal. So calling it never feeds anything and never consumes stock. The only
-- state touched is the barn's own fillLevels table, snapshotted and restored on
-- EVERY path including a throw (the sdStressBig rule).
--
-- A REAL barn is used rather than a duck-typed mock (the sdStress approach)
-- because consumeFood's body is unreadable: we cannot know which fields or
-- methods it touches, so a mock could silently answer a different question.
-- Borrowing a real barn guarantees the environment is exactly what the game uses.
--
-- Usage (needs game.xml <development><controls>true):
--     arFoodProbe                  -- first husbandry with a food spec
--     arFoodProbe <name fragment>  -- first barn whose name contains this
--     arFoodProbe <frag> <liters>  -- override the demand used per sample
--
-- REMOVE once the feed model is settled.
-- ============================================================================

AnimalFoodProbe = {}

local TOTAL_FOOD = 10000    -- litres placed in the trough per sample, capped to capacity
local DEMAND     = 100      -- litres asked for. Kept well under TOTAL so AVAILABILITY is
                            -- never the limiter and the only thing varying is the MIX.

-- ---------------------------------------------------------------------------
local function ftName(ft)
    if ft == nil then return "nil" end
    local m = g_fillTypeManager
    if m ~= nil and m.getFillTypeNameByIndex ~= nil then
        local ok, n = pcall(m.getFillTypeNameByIndex, m, ft)
        if ok and n ~= nil then return tostring(n) end
    end
    return "ft" .. tostring(ft)
end

local function pad(s, n)
    s = tostring(s)
    while #s < n do s = s .. " " end
    return s
end

local function out(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[arFoodProbe] " .. (ok and msg or tostring(fmt)))
end

-- ---------------------------------------------------------------------------
-- Every husbandry with a food spec, optionally filtered by a name fragment.
function AnimalFoodProbe.findBarns(fragment)
    local found = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return found end
    for _, p in ipairs(ps.placeables) do
        if p.spec_husbandryFood ~= nil then
            local name = "?"
            local okN, n = pcall(function() return p:getName() end)
            if okN and n ~= nil then name = tostring(n) end
            if fragment == nil or fragment == ""
               or string.find(string.lower(name), string.lower(fragment), 1, true) ~= nil then
                found[#found + 1] = { placeable = p, name = name }
            end
        end
    end
    return found
end

function AnimalFoodProbe.animalTypeIndexOf(p)
    local spec = p.spec_husbandryFood
    local ati = spec ~= nil and spec.animalTypeIndex or nil
    if ati == nil and p.getAnimalTypeIndex ~= nil then
        local ok, a = pcall(p.getAnimalTypeIndex, p)
        if ok then ati = a end
    end
    return ati
end

-- ---------------------------------------------------------------------------
-- The DECLARED target: each group's weight, plus a representative fill type to
-- stand for that group in a synthetic mix.
function AnimalFoodProbe.describeGroups(ati, supported)
    local afs = g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil
    if afs == nil or afs.getAnimalFood == nil then return nil, "no animalFoodSystem" end
    local okF, food = pcall(afs.getAnimalFood, afs, ati)
    if not okF or food == nil or food.groups == nil then return nil, "getAnimalFood returned nothing" end

    local groups = {}
    for _, grp in pairs(food.groups) do
        local fts, rep = {}, nil
        for _, ft in pairs(grp.fillTypes or {}) do
            fts[#fts + 1] = ft
            if rep == nil and (supported == nil or supported[ft] ~= nil) then rep = ft end
        end
        groups[#groups + 1] = {
            title  = tostring(grp.title or "?"),
            weight = grp.productionWeight or 0,
            fts    = fts,
            rep    = rep,
        }
    end
    table.sort(groups, function(a, b) return a.weight > b.weight end)
    return groups
end

function AnimalFoodProbe.mixturesFor(ati)
    local afs = g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil
    if afs == nil or afs.getMixturesByAnimalTypeIndex == nil then return {} end
    local ok, mix = pcall(afs.getMixturesByAnimalTypeIndex, afs, ati)
    if not ok or mix == nil then return {} end
    return mix
end

-- ---------------------------------------------------------------------------
---Measure the factor for one synthetic trough mix. `mix` is ft -> litres.
-- Returns factor, consumedTable, errText
function AnimalFoodProbe.sample(p, ati, mix, demand)
    local spec = p.spec_husbandryFood
    if spec == nil or spec.fillLevels == nil then return nil, nil, "no fillLevels" end
    local afs = g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil
    if afs == nil or afs.consumeFood == nil then return nil, nil, "no consumeFood" end

    -- snapshot the real trough
    local snap = {}
    for ft, lvl in pairs(spec.fillLevels) do snap[ft] = lvl end

    -- apply the synthetic mix
    for ft in pairs(spec.fillLevels) do spec.fillLevels[ft] = 0 end
    for ft, litres in pairs(mix) do spec.fillLevels[ft] = litres end

    local consumed = {}
    local okC, factorOrErr = pcall(afs.consumeFood, afs, ati, demand, p, consumed)

    -- restore on EVERY path, including a throw
    for ft in pairs(spec.fillLevels) do spec.fillLevels[ft] = nil end
    for ft, lvl in pairs(snap) do spec.fillLevels[ft] = lvl end

    if not okC then return nil, nil, tostring(factorOrErr) end
    return factorOrErr, consumed, nil
end

local function consumedText(consumed)
    if consumed == nil then return "" end
    local parts = {}
    for ft, d in pairs(consumed) do
        if d ~= nil and d > 0.0001 then
            parts[#parts + 1] = string.format("%s %.1f", ftName(ft), d)
        end
    end
    if #parts == 0 then return "(nothing)" end
    table.sort(parts)
    return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------------------
---Probe ONE barn.
function AnimalFoodProbe.probeBarn(barn, demand)
    local p    = barn.placeable
    local spec = p.spec_husbandryFood

    out("=====================================================================")
    out("barn: %s", barn.name)

    local ati = AnimalFoodProbe.animalTypeIndexOf(p)
    if ati == nil then
        out("could not resolve animalTypeIndex -- cannot probe this barn.")
        return
    end

    local capacity = spec.capacity or 0
    local total    = TOTAL_FOOD
    if capacity > 0 and capacity < total then total = capacity end

    out("animalTypeIndex=%s  capacity=%s  litersPerHour=%.2f  demand=%.1f  trough total=%.0f",
        tostring(ati), tostring(capacity), spec.litersPerHour or 0, demand, total)

    local supported, nSupported = spec.supportedFillTypes or {}, 0
    for _ in pairs(supported) do nSupported = nSupported + 1 end
    out("supported food types: %d", nSupported)

    -- ---- the DECLARED target --------------------------------------------
    local groups, why = AnimalFoodProbe.describeGroups(ati, supported)
    if groups == nil then
        out("could not read food groups: %s", tostring(why))
        return
    end

    out("---------------------------------------------------------------------")
    out("DECLARED FOOD GROUPS (the base game renders productionWeight as a %% of the mix)")
    local wsum = 0
    for _, g in ipairs(groups) do
        wsum = wsum + g.weight
        local names = {}
        for _, ft in ipairs(g.fts) do names[#names + 1] = ftName(ft) end
        out("  %s weight=%.3f (%3d%%)  rep=%s  fillTypes: %s",
            pad(g.title, 18), g.weight, math.floor(g.weight * 100 + 0.5),
            ftName(g.rep), table.concat(names, " "))
    end
    if math.abs(wsum - 1.0) < 0.02 then
        out("  weights sum to %.3f  <- a RATIO: the target is a MIX, not a single best food", wsum)
    else
        out("  weights sum to %.3f  <- does NOT sum to 1; interpret with care", wsum)
    end

    -- A single group cannot be mis-mixed: there is nothing to trade off, so
    -- best-first and the declared ratio are the SAME instruction. Say so, or a
    -- 1.0000 / 1.0000 result reads as evidence when it is just a degenerate case.
    if #groups < 2 then
        out("  ONLY ONE GROUP -- this animal type is trivially unaffected by fill order.")
        out("  The mix question can only be answered by a MULTI-GROUP animal (cow / pig / sheep / horse).")
    end

    local mixes = AnimalFoodProbe.mixturesFor(ati)
    if #mixes > 0 then
        local names = {}
        for _, ft in ipairs(mixes) do names[#names + 1] = ftName(ft) end
        out("  mixtures (complete rations): %s", table.concat(names, " "))
    else
        out("  mixtures (complete rations): none for this animal type")
    end

    -- ---- what Distribution Redux would do today --------------------------
    local SD = AnimalRedux ~= nil and AnimalRedux.DR or nil
    if SD ~= nil and SD._foodQualityMap ~= nil then
        local okQ, qmap = pcall(SD._foodQualityMap, p)
        if okQ and qmap ~= nil then
            local best, bestQ = nil, -1
            for ft, q in pairs(qmap) do
                if supported[ft] ~= nil and q > bestQ then best, bestQ = ft, q end
            end
            if best ~= nil then
                out("  Distribution Redux fills BEST-FIRST, i.e. all of: %s (weight %.3f)",
                    ftName(best), bestQ)
            end
        end
    end

    -- ---- build the sweep --------------------------------------------------
    local samples = {}
    local function addSample(label, mix) samples[#samples + 1] = { label = label, mix = mix } end

    addSample("EMPTY trough", {})

    for _, g in ipairs(groups) do
        if g.rep ~= nil then
            addSample(string.format("100%% %s", ftName(g.rep)), { [g.rep] = total })
        end
    end

    local declared, declaredOk = {}, true
    for _, g in ipairs(groups) do
        if g.rep == nil then
            declaredOk = false
        elseif g.weight > 0 then
            declared[g.rep] = (declared[g.rep] or 0) + total * g.weight
        end
    end
    if declaredOk and next(declared) ~= nil then
        addSample("DECLARED RATIO", declared)
    end

    -- blends between "all in the top group" (what DR does) and the declared ratio
    local top = groups[1]
    if declaredOk and top ~= nil and top.rep ~= nil and #groups > 1 then
        local steps = { 0.25, 0.50, 0.75 }
        for _, f in ipairs(steps) do
            local mix = {}
            for ft, litres in pairs(declared) do mix[ft] = litres * f end
            mix[top.rep] = (mix[top.rep] or 0) + total * (1 - f)
            addSample(string.format("%d%% toward declared", math.floor(f * 100 + 0.5)), mix)
        end
    end

    -- WITHIN one group: are its fill types interchangeable? The Grain group is
    -- WHEAT BARLEY SORGHUM, and if all three score the same then DR's per-fill-type
    -- preference is meaningless inside a group and only the GROUP SPLIT matters --
    -- which decides how granular the replacement model actually needs to be.
    if top ~= nil then
        local alt = nil
        for _, ft in ipairs(top.fts) do
            if ft ~= top.rep and supported[ft] ~= nil then alt = ft; break end
        end
        if alt ~= nil then
            addSample(string.format("100%% %s (same group)", ftName(alt)), { [alt] = total })
        end
    end

    for _, ft in ipairs(mixes) do
        if supported[ft] ~= nil then
            addSample(string.format("100%% %s (mixture)", ftName(ft)), { [ft] = total })
        end
    end

    -- ---- measure ----------------------------------------------------------
    out("---------------------------------------------------------------------")
    out("MEASURED FACTOR (trough total fixed at %.0f L, demand %.1f L, so only the MIX varies)",
        total, demand)
    out("  %s %s %s", pad("mix", 26), pad("factor", 10), "consumeFood took")
    for _, s in ipairs(samples) do
        local factor, consumed, err = AnimalFoodProbe.sample(p, ati, s.mix, demand)
        if err ~= nil then
            out("  %s %s ERROR: %s", pad(s.label, 26), pad("-", 10), err)
        else
            out("  %s %s %s", pad(s.label, 26),
                pad(string.format("%.4f", factor or -1), 10), consumedText(consumed))
        end
    end

    out("---------------------------------------------------------------------")
    if #groups >= 2 then
        out("HOW TO READ IT: if DECLARED RATIO scores HIGHER than '100%% <top group>',")
        out("filling best-first is wrong and Distribution Redux is losing production.")
    else
        out("Single group: nothing to conclude from this barn (see the note above).")
    end
    out("=====================================================================")
end

---With no name fragment, probe ONE barn per ANIMAL TYPE.
-- Probing "the first barn" was the first version and it was a poor default: it
-- landed on a chicken pasture, which has a single food group and therefore cannot
-- show the effect at all. One barn per animal type covers every distinct food
-- model on the farm in a single run, which is what the question actually needs.
function AnimalFoodProbe.run(fragment, demandArg)
    local demand = tonumber(demandArg) or DEMAND

    local barns = AnimalFoodProbe.findBarns(fragment)
    if #barns == 0 then
        out("no husbandry with a food spec found%s.",
            (fragment ~= nil and fragment ~= "") and (" matching '" .. tostring(fragment) .. "'") or "")
        return
    end

    if fragment ~= nil and fragment ~= "" then
        out("'%s' matched %d barn(s); probing the first.", tostring(fragment), #barns)
        AnimalFoodProbe.probeBarn(barns[1], demand)
        return
    end

    -- one representative barn per animal type
    local seen, chosen = {}, {}
    for _, b in ipairs(barns) do
        local ati = AnimalFoodProbe.animalTypeIndexOf(b.placeable)
        local key = ati ~= nil and ati or ("?" .. b.name)
        if seen[key] == nil then
            seen[key] = true
            chosen[#chosen + 1] = b
        end
    end

    out("%d barn(s) on the farm, %d distinct animal type(s). Probing one of each.",
        #barns, #chosen)
    for _, b in ipairs(chosen) do
        AnimalFoodProbe.probeBarn(b, demand)
    end
    out("all animal types probed. The MULTI-GROUP ones are the ones that answer the question.")
end

-- ============================================================================
-- arFeedPartial -- is the production factor PRESENCE-based or QUANTITY-based?
--
-- THE QUESTION. Everything measured so far had each food group either absent or
-- stocked well past its share, and the factor came out as the sum of the weights
-- of the groups PRESENT. What happens in between -- 100 L of soybean when the
-- pigs want 6,800 -- was never tested, and the two answers lead to very
-- different advice:
--
--   PRESENCE-BASED  a trickle of each group is enough, and the practical rule is
--                   just "get something from every group into every barn".
--   QUANTITY-BASED  each group must supply its full share every hour, and DR's
--                   sourcing has to keep pace or the factor sags.
--
-- HOW IT MEASURES. Every group is stocked far past its need, then ONE group is
-- swept from empty up to twice its hourly requirement while the others are held
-- constant -- so any movement in the factor is attributable to that group alone.
--
-- The sweep is in multiples of the group's HOURLY NEED (demand x its eat share),
-- not of the trough, because "enough" can only mean "enough for what will be
-- eaten this hour". Demand is the barn's real litersPerHour where it has one.
--
-- Single-group animals (sheep, chicken) are skipped: with one group the answer is
-- the trivial "food or no food".
--
-- Usage: arFeedPartial [name fragment]
-- ============================================================================

-- Multiples of the group's hourly need. 0 and the 1 L token are the two that
-- decide the question; the rest map whatever shape lies between them.
local PARTIAL_MULT  = { 0, -1, 0.25, 0.5, 1.0, 2.0 }    -- -1 means "literally 1 L"
local PARTIAL_LABEL = { "0 L", "1 L", "25%", "50%", "100%", "200%" }

local function sweepBarn(p, ati, name)
    local spec = p.spec_husbandryFood
    local model = AnimalFeedModel.read(ati, spec.supportedFillTypes)
    if model == nil or #model.groups < 2 then return false end

    out("=================================================================")
    out("%s   (%s, %d groups)", name, model.consumptionType, #model.groups)

    local demand = AnimalFeedModel.demandPerHour(p)
    if demand <= 0 then demand = 100 end

    local eatSum = 0
    for _, g in ipairs(model.groups) do
        if g.rep ~= nil then eatSum = eatSum + g.eat end
    end
    if eatSum <= 0 then
        out("  no usable groups in this building")
        return true
    end

    -- baseline: every group stocked far past anything it could eat this hour
    local BIG = math.max(demand * 50, 10000)
    local base = {}
    for _, g in ipairs(model.groups) do
        if g.rep ~= nil then base[g.rep] = BIG * g.eat / eatSum end
    end
    local fullF = select(1, AnimalFeedModel.measureFactor(p, ati, base, demand))
    out("  demand %.2f L/h; all groups stocked far past need -> factor %s",
        demand, fullF ~= nil and string.format("%.4f", fullF) or "?")

    local row = string.format("  %-20s", "group / stock")
    for _, lbl in ipairs(PARTIAL_LABEL) do row = row .. string.format(" %8s", lbl) end
    out("%s", row)

    for _, g in ipairs(model.groups) do
        if g.rep ~= nil then
            -- SERIAL tiers are ALTERNATIVES: one tier feeds the whole herd, so its
            -- need is the full demand. The first run split it by eat share and
            -- labelled 182.3 L "100%" for a cow that really needs 729 -- the sweep
            -- data was still valid (it swept absolute litres) but the columns lied.
            local need
            if model.consumptionType == "SERIAL" then
                need = demand
            else
                need = demand * g.eat / eatSum
            end
            local line = string.format("  %-20s", g.title)
            for i = 1, #PARTIAL_LABEL do
                local mult = PARTIAL_MULT[i]
                local litres = (mult < 0) and 1 or (need * mult)
                local mix = {}
                for ft, v in pairs(base) do mix[ft] = v end
                mix[g.rep] = litres
                local f = select(1, AnimalFeedModel.measureFactor(p, ati, mix, demand))
                line = line .. string.format(" %8s",
                    f ~= nil and string.format("%.4f", f) or "?")
            end
            out("%s   (needs %.1f L/h of %s)", line, need, ftName(g.rep))
        end
    end

    out("  READ IT: if the 1 L column already matches the 200%% column, the factor is")
    out("  PRESENCE-based and a trickle of each group is enough. If it climbs across")
    out("  the row, it is QUANTITY-based and every group must be kept to its share.")
    return true
end

function AnimalFoodProbe.runPartial(fragment)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then out("no placeableSystem"); return end
    if AnimalFeedModel == nil then out("AnimalFeedModel is not loaded"); return end

    local seen, reported = {}, 0
    for _, p in ipairs(ps.placeables) do
        if p.spec_husbandryFood ~= nil then
            local name = "?"
            local okN, nm = pcall(function() return p:getName() end)
            if okN and nm ~= nil then name = tostring(nm) end
            local matches = fragment == nil or fragment == ""
                or string.find(string.lower(name), string.lower(fragment), 1, true) ~= nil
            local ati = AnimalFeedModel.animalTypeIndexOf(p)
            if matches and ati ~= nil and seen[ati] == nil then
                seen[ati] = true
                if sweepBarn(p, ati, name) then reported = reported + 1 end
            end
        end
    end

    out("=================================================================")
    if reported == 0 then
        out("no multi-group animal type found%s; a single-group animal cannot answer this.",
            (fragment ~= nil and fragment ~= "") and (" matching '" .. tostring(fragment) .. "'") or "")
    else
        out("%d multi-group animal type(s) swept.", reported)
    end
end

function AnimalFoodProbe:consoleCommandPartial(fragment)
    local ok, err = pcall(AnimalFoodProbe.runPartial, fragment)
    if not ok then return "arFeedPartial failed: " .. tostring(err) end
    return "arFeedPartial done -- see log.txt"
end

-- ============================================================================
-- arMenuProbe -- how DR's menu actually places its pages.
--
-- PagingElement is ~64% stripped in the shipped source: addPage and
-- getPageIdByElement are both missing, so the contract for adding a page at
-- runtime has to be inferred from two readable call sites. Inferring it wrongly
-- is what broke DR's menu once and mislaid the Animals tab twice.
--
-- So: stop reasoning, dump what the game demonstrably does. For every page the
-- menu holds this prints the geometry the framework gave it, whether the paging
-- element can resolve it, and how ours compares. A page that renders in the wrong
-- place differs from a working one in exactly one of these numbers.
--
-- Usage: arMenuProbe
-- ============================================================================
local function xy(t)
    if type(t) ~= "table" then return "?" end
    return string.format("%.4f, %.4f", t[1] or -1, t[2] or -1)
end

function AnimalFoodProbe.runMenuProbe()
    local SD = AnimalRedux ~= nil and AnimalRedux.DR or nil
    local menu = SD ~= nil and SD._menu or nil
    if menu == nil then out("DR's menu is not registered"); return end
    local pe = menu.pagingElement
    out("=================================================================")
    out("pagingElement: %s", tostring(pe))
    if pe ~= nil then
        out("  position %s   size %s", xy(pe.position), xy(pe.size))
        out("  absPosition %s   absSize %s", xy(pe.absPosition), xy(pe.absSize))
        out("  #pages=%s  currentPageIndex=%s",
            tostring(pe.pages ~= nil and #pe.pages or "?"), tostring(pe.currentPageIndex))
        out("  methods: addPage=%s getPageIdByElement=%s addElement=%s",
            type(pe.addPage), type(pe.getPageIdByElement), type(pe.addElement))
    end

    out("--- pageFrames (what TabbedMenu registered) ---")
    for i, f in ipairs(menu.pageFrames or {}) do
        local id = nil
        if pe ~= nil and pe.getPageIdByElement ~= nil then
            local okI, v = pcall(pe.getPageIdByElement, pe, f); id = okI and v or "ERR"
        end
        local root = f.elements ~= nil and f.elements[1] or nil
        out("  [%d] %s", i, tostring(f.name or f.pageName or f))
        out("        pos %s  size %s", xy(f.position), xy(f.size))
        out("        abs %s  absSize %s", xy(f.absPosition), xy(f.absSize))
        local resolves = "n/a"
        if pe ~= nil and id ~= nil and id ~= "ERR" and pe.getPageById ~= nil then
            local okR, entry = pcall(pe.getPageById, pe, id)
            resolves = tostring(okR and entry ~= nil)
        end
        out("        pagingId=%s  resolves=%s  visible=%s",
            tostring(id), resolves, tostring(f.visible))
        if root ~= nil then
            out("        root: pos %s  size %s  abs %s", xy(root.position), xy(root.size),
                xy(root.absPosition))
        end
    end

    out("--- pagingElement.pages (what the paging element knows) ---")
    for i, pg in ipairs((pe ~= nil and pe.pages) or {}) do
        out("  [%d] id=%s  title=%s  disabled=%s  element=%s",
            i, tostring(pg.id), tostring(pg.title), tostring(pg.disabled), tostring(pg.element))
    end
    out("=================================================================")
end

function AnimalFoodProbe:consoleCommandMenu()
    local ok, err = pcall(AnimalFoodProbe.runMenuProbe)
    if not ok then return "arMenuProbe failed: " .. tostring(err) end
    return "arMenuProbe done -- see log.txt"
end

-- ============================================================================
-- arAvailFood -- what does getAvailableFood() actually return?
--
-- THE QUESTION. A husbandry's food is read here from
-- spec_husbandryFood.fillLevels, which is the TROUGH. But
-- PlaceableHusbandryMeadow overrides getAvailableFood / removeFood /
-- getFoodInfos, so a grazing barn has food that never appears there: a cow barn
-- was seen reading every group at 0 L while the engine scored it 0.40, the Grass
-- tier, from the pasture.
--
-- getAvailableFood is therefore the AUTHORITATIVE source and fillLevels is a
-- subset of it. Switching to it would fix the grazing blind spot and might stop
-- DR hauling grass to a barn already eating enough of it.
--
-- WHY THIS IS A SHAPE PROBE AND NOT A FIX. Both implementations are STRIPPED from
-- the shipped SDK source -- registered in PlaceableHusbandryFood, overridden in
-- PlaceableHusbandryMeadow, readable in neither -- so the return shape is
-- unknown. Guessing at stripped internals is what cost three rounds on the menu
-- tab (CLAUDE.md 2.4), so this reports what comes back rather than assuming a
-- ft -> litres map.
--
-- It tries the no-argument form and a per-fill-type form, prints the type and
-- structure of whatever returns, and DIFFS it against fillLevels -- because the
-- difference IS the grazing contribution, which is the number we actually want.
--
-- Usage: arAvailFood [name fragment]
-- ============================================================================
local function describe(v, depth)
    depth = depth or 0
    local t = type(v)
    if t ~= "table" then return t .. "(" .. tostring(v) .. ")" end
    if depth > 1 then return "table{...}" end
    local n, sample = 0, {}
    for k, val in pairs(v) do
        n = n + 1
        if n <= 4 then
            sample[#sample + 1] = string.format("[%s(%s)]=%s",
                tostring(k), type(k), describe(val, depth + 1))
        end
    end
    return string.format("table{%d entr%s: %s}", n, n == 1 and "y" or "ies",
        table.concat(sample, ", "))
end

function AnimalFoodProbe.runAvailFood(fragment)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then out("no placeableSystem"); return end

    local seen, n = {}, 0
    for _, p in ipairs(ps.placeables) do
        local spec = p.spec_husbandryFood
        if spec ~= nil then
            local name = "?"
            local okN, nm = pcall(function() return p:getName() end)
            if okN and nm ~= nil then name = tostring(nm) end
            local matches = fragment == nil or fragment == ""
                or string.find(string.lower(name), string.lower(fragment), 1, true) ~= nil
            local ati = AnimalFeedModel ~= nil and AnimalFeedModel.animalTypeIndexOf(p) or nil
            local key = ati or name

            if matches and seen[key] == nil then
                seen[key] = true
                n = n + 1
                out("=================================================================")
                out("%s   grazes=%s   getAvailableFood=%s",
                    name, tostring(p.spec_husbandryMeadow ~= nil), type(p.getAvailableFood))

                -- what the TROUGH says
                local troughTotal, troughParts = 0, {}
                for ft, lvl in pairs(spec.fillLevels or {}) do
                    if (lvl or 0) > 0 then
                        troughTotal = troughTotal + lvl
                        troughParts[#troughParts + 1] = string.format("%s %.1f", ftName(ft), lvl)
                    end
                end
                table.sort(troughParts)
                out("  fillLevels      total %.1f L : %s", troughTotal,
                    #troughParts > 0 and table.concat(troughParts, ", ") or "(empty)")

                if p.getAvailableFood ~= nil then
                    -- no-argument form
                    local ok, a, b = pcall(p.getAvailableFood, p)
                    if ok then
                        out("  getAvailableFood()      -> %s", describe(a))
                        if b ~= nil then out("      second return         -> %s", describe(b)) end
                        -- If it IS a ft -> litres map, the DIFF against the trough is
                        -- exactly what grazing supplies. Printed either way; a wrong
                        -- guess just prints nothing useful rather than misleading.
                        if type(a) == "table" then
                            local diffs = {}
                            for k, v in pairs(a) do
                                if type(k) == "number" and type(v) == "number" then
                                    local d = v - (spec.fillLevels[k] or 0)
                                    if math.abs(d) > 0.01 then
                                        diffs[#diffs + 1] = string.format("%s %+.1f", ftName(k), d)
                                    end
                                end
                            end
                            table.sort(diffs)
                            out("      minus fillLevels      -> %s",
                                #diffs > 0 and table.concat(diffs, ", ")
                                or "(identical, so nothing is being grazed right now)")
                        end
                    else
                        out("  getAvailableFood()      -> THREW: %s", tostring(a))
                    end

                    -- per-fill-type form, in case it takes one
                    local probeFt = nil
                    for ft in pairs(spec.supportedFillTypes or {}) do probeFt = ft; break end
                    if probeFt ~= nil then
                        local ok2, r2 = pcall(p.getAvailableFood, p, probeFt)
                        out("  getAvailableFood(%s) -> %s", ftName(probeFt),
                            ok2 and describe(r2) or ("THREW: " .. tostring(r2)))
                    end
                end

                -- getFoodInfos is the other meadow override and is what the base
                -- game's own UI reads, so it may already carry the merged picture.
                if p.getFoodInfos ~= nil then
                    local ok3, infos = pcall(p.getFoodInfos, p)
                    out("  getFoodInfos()          -> %s", ok3 and describe(infos)
                        or ("THREW: " .. tostring(infos)))
                end

                -- The condition panel's data source. Six specs contribute, and a
                -- modded husbandry may add its own entries, so the shape is worth
                -- seeing rather than assuming.
                if p.getConditionInfos ~= nil then
                    local ok4, conds = pcall(p.getConditionInfos, p)
                    if ok4 and type(conds) == "table" then
                        out("  getConditionInfos()     -> %d entr%s", #conds,
                            #conds == 1 and "y" or "ies")
                        for i, c in ipairs(conds) do
                            out("      [%d] %s", i, describe(c))
                        end
                    else
                        out("  getConditionInfos()     -> %s",
                            ok4 and describe(conds) or ("THREW: " .. tostring(conds)))
                    end
                end
                if p.getGlobalProductionFactor ~= nil and p.getProductionFactor ~= nil then
                    local okG, gf = pcall(p.getGlobalProductionFactor, p)
                    local okP, pf = pcall(p.getProductionFactor, p)
                    out("  productionFactor=%s  globalProductionFactor=%s  productivity=%s",
                        okP and tostring(pf) or "?", okG and tostring(gf) or "?",
                        (okG and okP and type(gf) == "number" and type(pf) == "number")
                            and string.format("%.4f", gf * pf) or "?")
                end
            end
        end
    end
    out("=================================================================")
    out("%d husbandr%s reported. Compare a GRAZING barn against a non-grazing one:",
        n, n == 1 and "y" or "ies")
    out("the difference between them is what the meadow contributes.")
end

function AnimalFoodProbe:consoleCommandAvail(fragment)
    local ok, err = pcall(AnimalFoodProbe.runAvailFood, fragment)
    if not ok then return "arAvailFood failed: " .. tostring(err) end
    return "arAvailFood done -- see log.txt"
end

-- ---------------------------------------------------------------------------
function AnimalFoodProbe.register()
    if addConsoleCommand == nil then return false end
    if AnimalFoodProbe._registered then return true end
    addConsoleCommand("arFoodProbe", "Measure the animal food mix -> production factor curve",
        "consoleCommand", AnimalFoodProbe)
    addConsoleCommand("arFeedPartial", "Is the food factor presence-based or quantity-based?",
        "consoleCommandPartial", AnimalFoodProbe)
    addConsoleCommand("arMenuProbe", "Dump how DR's menu places its pages",
        "consoleCommandMenu", AnimalFoodProbe)
    addConsoleCommand("arAvailFood", "What does getAvailableFood() actually return?",
        "consoleCommandAvail", AnimalFoodProbe)
    addConsoleCommand("arTradeProbe", "Do the base game's animal trade classes exist at runtime?",
        "consoleCommandTrade", AnimalFoodProbe)
    addConsoleCommand("arTradeOpen", "Open the game's own animal screen for a barn (no trailer)",
        "consoleCommandTradeOpen", AnimalFoodProbe)
    addConsoleCommand("arReproProbe", "Reproduction yield + the health/age price terms (clone-only)",
        "consoleCommandRepro", AnimalFoodProbe)
    AnimalFoodProbe._registered = true
    return true
end

function AnimalFoodProbe:consoleCommand(fragment, demand)
    local ok, err = pcall(AnimalFoodProbe.run, fragment, demand)
    if not ok then return "arFoodProbe failed: " .. tostring(err) end
    return "arFoodProbe done -- see log.txt"
end

-- ============================================================================
-- arTradeProbe / arTradeOpen   -- TEMPORARY DEV PROBE
--
-- WHAT IT ANSWERS. The base game's animal BUY/SELL path cannot be read:
-- gui/AnimalScreen.lua is 78% blank in the shipped SDK source (8 surviving
-- functions, none of them the transaction), its controller classes are absent
-- from the tree entirely, and there is no AnimalBuyEvent / AnimalSellEvent file
-- anywhere in it. Per the project rule, an ABSENCE in that source proves
-- nothing, so this asks the running game instead.
--
-- WHY WE EXPECT THEM TO EXIST. FS25_RealisticLivestockRM overwrites them:
--     AnimalScreenDealerFarm.initTargetItems = Utils.overwrittenFunction(
--         AnimalScreenDealerFarm.initTargetItems, RL_..initTargetItems)
--     AnimalScreen.setController = Utils.overwrittenFunction(
--         AnimalScreen.setController, RealisticLivestock_AnimalScreen.setController)
-- You cannot overwrite what does not exist. That names the doors; this probe
-- checks they open. RL is GPL v3 and NOTHING is taken from it: only the fact
-- that a given base-game symbol exists, which is then verified here.
--
-- THE CAVEAT THAT MATTERS MOST, AND IT IS PRINTED FIRST. A mod's override of a
-- base-game class lands in the SHARED global table, so with RealisticLivestock
-- installed every method list below is RL's, not the base game's. The probe
-- reports whether RL is active before anything else. RUN IT TWICE, once with RL
-- enabled and once with it disabled, or the answer is about RL.
--
-- READ-ONLY. arTradeProbe buys nothing, sells nothing, moves no animal and
-- touches no money: it reads names, levels and prices. The one side-effecting
-- half is deliberately a SEPARATE command (arTradeOpen), which opens the base
-- game's own screen and nothing more.
--
-- Usage (needs game.xml development controls true):
--     arTradeProbe                 : context + globals + first 3 barns
--     arTradeProbe <name fragment> : only barns whose name contains this
--     arTradeOpen  <name fragment> : open the game's screen for that barn
--     arTradeOpen  <frag> move     : as a farm-to-farm move, not a dealer buy
--
-- REMOVE with the other probes before release (open item 4).
-- ============================================================================

local function tout(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[arTrade] " .. (ok and msg or tostring(fmt)))
end

-- Every one of these is ABSENT from the shipped SDK source. Their presence at
-- runtime is the whole question.
local TRADE_GLOBALS = {
    "AnimalScreen", "AnimalScreenBase",
    "AnimalScreenDealer", "AnimalScreenDealerFarm", "AnimalScreenDealerTrailer",
    "AnimalScreenTrailer", "AnimalScreenTrailerFarm", "AnimalScreenMoveFarm",
    "AnimalItem", "AnimalItemStock",
    "AnimalBuyEvent", "AnimalSellEvent", "AnimalMoveEvent", "AnimalUnloadEvent",
}

-- Tested by NAME as well as enumerated. DR 6.12 found a class whose metatable is
-- PROTECTED (getmetatable returns a decoy with no __index while the methods
-- resolve perfectly), so an empty enumeration is not evidence of an empty class.
local CLUSTER_METHODS = {
    "getAge", "getNumAnimals", "getSubTypeIndex", "getSellPrice", "addInfos",
    "clone", "changeNumAnimals", "getSupportsMerging", "setName",
    "updateHealth", "updateReproduction",
}
local HUSB_METHODS = {
    "getClusters", "getCluster", "getClusterById", "addCluster", "addAnimals",
    "getNumOfAnimals", "getMaxNumOfAnimals", "getNumOfFreeAnimalSlots",
    "getSupportsAnimalSubType", "getAnimalTypeIndex", "getAnimalInfos",
    "getAnimalDescription", "getClusterSystem",
}
local ANIMALSYS_METHODS = {
    "getSaleAnimalsByTypeIndex", "getSubTypeByIndex", "getVisualByAge",
    "getTypeByIndex", "getSubTypeIndexByName", "getAnimalsByType",
}

-- ---------------------------------------------------------------------------
local function fnNamesOf(t)
    local names = {}
    if type(t) ~= "table" then return names end
    local ok = pcall(function()
        for k, v in pairs(t) do
            if type(k) == "string" and type(v) == "function" then names[#names + 1] = k end
        end
    end)
    if not ok then return {} end
    table.sort(names)
    return names
end

-- Which of `wanted` actually RESOLVE on obj. Indexing goes through the metatable,
-- so this sees a method that enumeration cannot.
local function resolvable(obj, wanted)
    local yes, no = {}, {}
    for _, n in ipairs(wanted) do
        local ok, v = pcall(function() return obj[n] end)
        if ok and type(v) == "function" then
            yes[#yes + 1] = n
        else
            no[#no + 1] = n
        end
    end
    return yes, no
end

local function joinList(t, max)
    if #t == 0 then return "(none)" end
    local n = math.min(#t, max or 999)
    local parts = {}
    for i = 1, n do parts[#parts + 1] = tostring(t[i]) end
    local s = table.concat(parts, ", ")
    if #t > n then s = s .. string.format(", ...(+%d more)", #t - n) end
    return s
end

local function callNum(obj, name)
    if obj == nil or obj[name] == nil then return nil end
    local ok, v = pcall(obj[name], obj)
    if ok and type(v) == "number" then return v end
    return nil
end

local function countPairs(t)
    local n = 0
    if type(t) ~= "table" then return 0 end
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------
local function ownerFarmOf(p)
    if p == nil or p.getOwnerFarmId == nil then return nil end
    local ok, f = pcall(p.getOwnerFarmId, p)
    if ok and type(f) == "number" then return f end
    return nil
end

-- The LOCAL player's farm, or nil. 0 is SPECTATOR, not a farm (DR 5.47), and the
-- caller treats nil as "no preference", so a dedicated server loses the ordering
-- rather than matching nothing.
local function playerFarmId()
    if g_currentMission == nil or g_currentMission.getFarmId == nil then return nil end
    local ok, f = pcall(g_currentMission.getFarmId, g_currentMission)
    if not ok or type(f) ~= "number" or f == 0 then return nil end
    return f
end

-- ---------------------------------------------------------------------------
-- Husbandries with an ANIMALS spec. Deliberately UNSCOPED by farm: a probe that
-- hides rows cannot tell you a row was hidden, so ownership is reported per barn
-- instead and a map-owned pen is visible AS map-owned.
local function findAnimalBarns(fragment)
    local found = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil or ps.placeables == nil then return found end
    for _, p in ipairs(ps.placeables) do
        if p.spec_husbandryAnimals ~= nil then
            local name = "?"
            local okN, n = pcall(function() return p:getName() end)
            if okN and n ~= nil then name = tostring(n) end
            if fragment == nil or fragment == ""
               or string.find(string.lower(name), string.lower(fragment), 1, true) ~= nil then
                found[#found + 1] = { placeable = p, name = name,
                                      count = callNum(p, "getNumOfAnimals") or 0,
                                      farm  = ownerFarmOf(p) }
            end
        end
    end

    -- ORDER MATTERS, and the first version got it wrong. Placeable order put three
    -- EMPTY chicken sheds first (two of them map-owned), so the default run printed
    -- "clusters: 0" three times and answered nothing about clusters at all. An empty
    -- barn is a valid row and a useless SAMPLE. So: the player's own farm first, then
    -- most animals first, then by name so the order is stable between runs.
    local myFarm = playerFarmId()
    table.sort(found, function(a, b)
        local am = (myFarm ~= nil and a.farm == myFarm) and 1 or 0
        local bm = (myFarm ~= nil and b.farm == myFarm) and 1 or 0
        if am ~= bm then return am > bm end
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    return found
end

-- ---------------------------------------------------------------------------
-- Is RealisticLivestock live? By GLOBALS, not by zip name: RL ships as both
-- FS25_RealisticLivestockRM and FS25_RealisticLivestock, so the name is not a
-- reliable test (AR CLAUDE.md 5).
local function realisticLivestockActive()
    local hits = {}
    local names = { "RealisticLivestock", "RLSettings", "RLModBridge",
                    "RLConstants", "RmLogging" }
    for _, g in ipairs(names) do
        local ok, v = pcall(function() return _G[g] end)
        if ok and v ~= nil then hits[#hits + 1] = g end
    end
    local mods = {}
    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        local okM, list = pcall(g_modManager.getActiveMods, g_modManager)
        if okM and type(list) == "table" then
            for _, mod in pairs(list) do
                local n = type(mod) == "table" and mod.modName or nil
                if type(n) == "string" and string.find(string.lower(n), "livestock", 1, true) then
                    mods[#mods + 1] = n
                end
            end
        end
    end
    return #hits > 0, hits, mods
end

-- ---------------------------------------------------------------------------
function AnimalFoodProbe.dumpTradeContext()
    tout("================= arTradeProbe =================")
    tout("CONTEXT")
    local rlOn, rlGlobals, rlMods = realisticLivestockActive()
    if rlOn or #rlMods > 0 then
        tout("  *** RealisticLivestock IS ACTIVE (globals: %s | mods: %s)",
             joinList(rlGlobals, 9), joinList(rlMods, 9))
        tout("  *** RL overwrites these classes IN THE SHARED GLOBAL TABLE, so every")
        tout("  *** method list below may be RL's and not the base game's.")
        tout("  *** Run this again with RL DISABLED to see the base game.")
    else
        tout("  RealisticLivestock not detected: what follows should be the BASE GAME.")
    end
    local farmId = "?"
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        local okF, f = pcall(g_currentMission.getFarmId, g_currentMission)
        if okF then farmId = tostring(f) end
    end
    tout("  isServer=%s  isClient=%s  farmId=%s",
         tostring(g_server ~= nil), tostring(g_client ~= nil), farmId)
end

function AnimalFoodProbe.dumpTradeGlobals()
    tout("")
    tout("GLOBALS: present at runtime? (all are absent from the shipped SDK source)")
    local missing = 0
    for _, name in ipairs(TRADE_GLOBALS) do
        local ok, v = pcall(function() return _G[name] end)
        if not ok then v = nil end
        if v == nil then
            missing = missing + 1
            tout("  %s  MISSING", pad(name, 26))
        else
            local fns = fnNamesOf(v)
            tout("  %s  %s, %d function(s)", pad(name, 26), type(v), #fns)
            tout("        %s", joinList(fns, 14))
        end
    end
    tout("  -> %d of %d missing", missing, #TRADE_GLOBALS)

    tout("")
    tout("g_animalScreen")
    if g_animalScreen == nil then
        tout("  MISSING: the screen singleton does not exist, so arTradeOpen cannot work")
    else
        local yes, no = resolvable(g_animalScreen, { "setController", "show", "onOpen", "onClose" })
        tout("  present. resolves: %s", joinList(yes, 9))
        if #no > 0 then tout("  does NOT resolve: %s", joinList(no, 9)) end
        tout("  controller currently: %s", tostring(g_animalScreen.controller))
    end

    tout("")
    tout("animalSystem")
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil then
        tout("  MISSING")
    else
        local yes, no = resolvable(asys, ANIMALSYS_METHODS)
        tout("  resolves: %s", joinList(yes, 9))
        if #no > 0 then tout("  does NOT resolve: %s", joinList(no, 9)) end
    end
end

-- ---------------------------------------------------------------------------
-- One barn: what the Animals view and the Trade view would each have to read.
function AnimalFoodProbe.dumpTradeBarn(p, name)
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil

    local ownerFarm = "?"
    local okO, of = pcall(function() return p:getOwnerFarmId() end)
    if okO then ownerFarm = tostring(of) end

    local ati = nil
    if p.getAnimalTypeIndex ~= nil then
        local okA, a = pcall(p.getAnimalTypeIndex, p)
        if okA then ati = a end
    end

    tout("")
    tout("BARN  %s   farm=%s  animalTypeIndex=%s", name, ownerFarm, tostring(ati))

    local hy, hn = resolvable(p, HUSB_METHODS)
    if #hn > 0 then tout("  husbandry does NOT resolve: %s", joinList(hn, 14)) end

    tout("  animals=%s / max=%s   freeSlots=%s",
         tostring(callNum(p, "getNumOfAnimals")),
         tostring(callNum(p, "getMaxNumOfAnimals")),
         tostring(callNum(p, "getNumOfFreeAnimalSlots")))

    -- CLUSTERS: the per-animal view's rows.
    local clusters = nil
    if p.getClusters ~= nil then
        local okC, c = pcall(p.getClusters, p)
        if okC then clusters = c end
    end
    if type(clusters) ~= "table" then
        tout("  getClusters returned %s: no per-animal rows available here", type(clusters))
        return
    end

    local total = countPairs(clusters)
    tout("  clusters: %d", total)

    local shown = 0
    for _, cl in pairs(clusters) do
        shown = shown + 1
        if shown > 5 then
            tout("    ...(%d more clusters not shown)", total - 5)
            break
        end

        if shown == 1 then
            local cy, cn = resolvable(cl, CLUSTER_METHODS)
            tout("    cluster methods resolving: %s", joinList(cy, 14))
            if #cn > 0 then tout("    cluster methods MISSING:   %s", joinList(cn, 14)) end
            local enumerated = fnNamesOf(cl)
            local mt = getmetatable(cl)
            if #enumerated == 0 and #cy > 0 then
                tout("    NOTE metatable is protected or indirect (enumeration empty, methods resolve);")
                tout("         getmetatable -> %s, __index -> %s", type(mt),
                     type(mt) == "table" and type(mt.__index) or "n/a")
            end
        end

        local function num(m)
            local ok, v = pcall(function() return cl[m](cl) end)
            if ok and v ~= nil then return tostring(v) end
            return "?"
        end

        local sti = cl.subTypeIndex
        local stName = "?"
        if asys ~= nil and asys.getSubTypeByIndex ~= nil and sti ~= nil then
            local okS, st = pcall(asys.getSubTypeByIndex, asys, sti)
            if okS and type(st) == "table" then
                stName = tostring(st.name or st.fillTypeIndex or "?")
                if shown == 1 then
                    local keys = {}
                    for k in pairs(st) do keys[#keys + 1] = tostring(k) end
                    table.sort(keys)
                    tout("    subType fields: %s", joinList(keys, 12))
                end
            end
        end
        tout("    #%d subType=%s(%s) n=%s age=%s health=%s sellPrice=%s",
             shown, tostring(sti), stName, num("getNumAnimals"), num("getAge"),
             tostring(cl.health), num("getSellPrice"))

        -- The base game's OWN per-animal info list. If this works, the Animals
        -- view's detail rows are nearly free: same shape as getConditionInfos,
        -- which this tab already renders.
        if shown == 1 then
            local infos = nil
            if p.getAnimalInfos ~= nil then
                local okI, t = pcall(p.getAnimalInfos, p, cl)
                if okI then infos = t end
            end
            if type(infos) ~= "table" and cl.addInfos ~= nil then
                infos = {}
                pcall(cl.addInfos, cl, infos)
            end
            if type(infos) == "table" then
                tout("    getAnimalInfos -> %d entr%s", #infos, (#infos == 1) and "y" or "ies")
                for i, e in ipairs(infos) do
                    if type(e) == "table" then
                        tout("      [%d] title=%s  value=%s  ratio=%s", i,
                             tostring(e.title), tostring(e.value), tostring(e.ratio))
                    else
                        tout("      [%d] %s", i, tostring(e))
                    end
                end
            else
                tout("    getAnimalInfos / addInfos produced nothing")
            end
        end
    end

    -- WHAT COULD BE BOUGHT INTO THIS BARN. This is the Trade view's source list,
    -- and the one thing that decides whether it can show offers and prices
    -- without opening the game's own screen.
    if asys ~= nil and asys.getSaleAnimalsByTypeIndex ~= nil and ati ~= nil then
        local okS, sale = pcall(asys.getSaleAnimalsByTypeIndex, asys, ati)
        if okS and type(sale) == "table" then
            local sn = countPairs(sale)
            tout("  getSaleAnimalsByTypeIndex(%s) -> %d offer(s)", tostring(ati), sn)
            local i = 0
            for _, item in pairs(sale) do
                i = i + 1
                if i > 5 then
                    tout("    ...(%d more)", sn - 5)
                    break
                end
                if type(item) == "table" then
                    if i == 1 then
                        local keys = {}
                        for k in pairs(item) do keys[#keys + 1] = tostring(k) end
                        table.sort(keys)
                        tout("    offer fields: %s", joinList(keys, 12))
                    end
                    tout("    offer[%d] subTypeIndex=%s age=%s numAnimals=%s price=%s",
                         i, tostring(item.subTypeIndex), tostring(item.age),
                         tostring(item.numAnimals), tostring(item.price or item.buyPrice))
                else
                    tout("    offer[%d] is a %s, not a table", i, type(item))
                end
            end
        else
            tout("  getSaleAnimalsByTypeIndex failed or did not return a table")
        end
    end
end

-- ---------------------------------------------------------------------------
function AnimalFoodProbe.runTradeProbe(fragment)
    AnimalFoodProbe.dumpTradeContext()
    AnimalFoodProbe.dumpTradeGlobals()

    local barns = findAnimalBarns(fragment)
    local suffix = ""
    if fragment ~= nil and fragment ~= "" then suffix = " matching '" .. fragment .. "'" end
    tout("")
    tout("BARNS: %d husbandr%s with an animals spec%s",
         #barns, (#barns == 1) and "y" or "ies", suffix)
    if #barns == 0 then
        tout("  none. An EMPTY list is evidence too: either this save has no animal")
        tout("  husbandry, or spec_husbandryAnimals is not the field to look under.")
    end

    -- The full inventory FIRST, before any detail. Three empty sheds in a row is
    -- otherwise indistinguishable from "this farm has no animals".
    for i, b in ipairs(barns) do
        tout("  %2d. %s  farm=%s  animals=%d", i, pad(b.name, 34),
             tostring(b.farm), b.count)
    end

    local limit = #barns
    if fragment == nil or fragment == "" then limit = math.min(#barns, 3) end
    for i = 1, limit do
        AnimalFoodProbe.dumpTradeBarn(barns[i].placeable, barns[i].name)
    end
    if limit < #barns then
        tout("")
        tout("(%d more barn(s) not shown: pass a name fragment to target one)", #barns - limit)
    end

    tout("")
    tout("READ-ONLY: nothing was bought, sold, moved or paid for.")
    tout("Next: arTradeOpen <fragment> to see which controller the game picks for a barn.")
    tout("================================================")
end

-- ---------------------------------------------------------------------------
-- The one side-effecting half, kept as its own command so it cannot fire by
-- accident. It opens the base game's OWN screen (the same call the animal
-- loading trigger makes, AnimalLoadingTrigger.lua:243) and reports which
-- controller class the game chose. That is what decides whether Animal Redux's
-- Trade view can be "rules plus a button" rather than a reimplemented
-- transaction.
--
-- setController is pcall'd and showGui runs ONLY if it succeeded: a half-set
-- controller followed by a shown screen is how you get a GUI throwing on every
-- frame (AR CLAUDE.md 2.3, and DR's addMenuPage learned it the hard way).
function AnimalFoodProbe.runTradeOpen(fragment, mode)
    local isDealer = true
    if mode ~= nil and string.lower(tostring(mode)) == "move" then isDealer = false end

    tout("================= arTradeOpen =================")

    if g_animalScreen == nil then
        tout("g_animalScreen is nil: cannot open. Nothing was changed.")
        return
    end
    if g_animalScreen.setController == nil then
        tout("g_animalScreen has no setController: cannot open. Nothing was changed.")
        return
    end

    local barns = findAnimalBarns(fragment)
    local suffix = ""
    if fragment ~= nil and fragment ~= "" then suffix = " for '" .. fragment .. "'" end
    tout("%d matching barn(s)%s", #barns, suffix)
    if #barns == 0 then
        tout("nothing to open. Pass a name fragment matching one of your barns.")
        return
    end

    local barn, name = barns[1].placeable, barns[1].name
    tout("opening for '%s' with trailer=nil, isDealer=%s", name, tostring(isDealer))
    tout("  (a nil trailer is the question: does the game pick a *Farm controller?)")

    local ok, err = pcall(function()
        g_animalScreen:setController(barn, nil, isDealer)
    end)
    if not ok then
        tout("setController THREW: %s", tostring(err))
        tout("The screen was NOT shown. Nothing is half-open.")
        return
    end

    local ctrl = g_animalScreen.controller
    tout("setController ok. controller = %s", tostring(ctrl))
    if type(ctrl) == "table" then
        local mt = getmetatable(ctrl)
        tout("  controller metatable: %s", tostring(mt))
        tout("  controller functions: %s", joinList(fnNamesOf(ctrl), 14))
        tout("  husbandry=%s trailer=%s isDealer=%s",
             tostring(ctrl.husbandry), tostring(ctrl.trailer), tostring(ctrl.isDealer))
        -- Which class is it? The FIRST version compared mt.__index against each
        -- global and reported "not identified" on a perfectly ordinary controller.
        -- That was the DR 6.12 shape again, and this probe had already printed the
        -- evidence three screens earlier: getmetatable -> table, __index -> nil. A
        -- protected metatable defeats identity comparison exactly as it defeats
        -- enumeration, so the test has to go through the class chain instead.
        local named = false
        if type(ctrl.isa) == "function" then
            for _, gname in ipairs(TRADE_GLOBALS) do
                local okG, g = pcall(function() return _G[gname] end)
                if okG and type(g) == "table" then
                    local okI, yes = pcall(ctrl.isa, ctrl, g)
                    if okI and yes == true then
                        tout("  -> isa(%s) = TRUE", gname)
                        named = true
                    end
                end
            end
            if not named then tout("  -> isa() said no to every known class") end
        else
            tout("  -> no isa() on the controller; cannot walk the class chain")
        end

        -- Fingerprint fallback: which class-distinguishing methods RESOLVE. This
        -- works whatever the metatable does, and it is what the Trade view would
        -- actually call, so it is the more useful answer of the two anyway.
        local cy, cn = resolvable(ctrl, {
            "applySource", "applyTarget", "applySourceBulk", "applyTargetBulk",
            "getSourceItems", "getTargetItems", "getSourcePrice", "getTargetPrice",
            "getSourceName", "getTargetName", "getSourceActionText", "getTargetActionText",
            "getMaxNumAnimals", "getSourceMaxNumAnimals", "getTargetMaxNumAnimals",
        })
        tout("  controller RESOLVES: %s", joinList(cy, 15))
        if #cn > 0 then tout("  controller lacks:    %s", joinList(cn, 15)) end
        if type(ctrl.getSourceName) == "function" then
            local okN, sn = pcall(ctrl.getSourceName, ctrl)
            local okT, tn = pcall(ctrl.getTargetName, ctrl)
            tout("  source='%s'  target='%s'  (which way round the screen is pointing)",
                 okN and tostring(sn) or "?", okT and tostring(tn) or "?")
        end
    end

    if g_gui ~= nil and g_gui.showGui ~= nil then
        local okS, errS = pcall(g_gui.showGui, g_gui, "AnimalScreen")
        if okS then
            tout("showGui('AnimalScreen') -> ok")
            tout("Press Back to close. Nothing has been bought or sold.")
        else
            tout("showGui('AnimalScreen') -> FAILED: %s", tostring(errS))
        end
    else
        tout("g_gui:showGui unavailable: controller was set but no screen shown.")
    end
    tout("==============================================")
end

function AnimalFoodProbe:consoleCommandTrade(fragment)
    local ok, err = pcall(AnimalFoodProbe.runTradeProbe, fragment)
    if not ok then return "arTradeProbe failed: " .. tostring(err) end
    return "arTradeProbe done -- see log.txt"
end

function AnimalFoodProbe:consoleCommandTradeOpen(fragment, mode)
    local ok, err = pcall(AnimalFoodProbe.runTradeOpen, fragment, mode)
    if not ok then return "arTradeOpen failed: " .. tostring(err) end
    return "arTradeOpen done -- see log.txt"
end

-- ============================================================================
-- arReproProbe   -- TEMPORARY DEV PROBE
--
-- TWO QUESTIONS LEFT OPEN BY §11:
--   1. How many offspring does cluster:updateReproduction() yield, and does it
--      scale with headcount? That figure is what the whole slot-economics rule
--      turns on, and the function is stripped from the SDK source.
--   2. The health term in sellPrice = curve(age) * (0.40 + 0.60 * health) was
--      solved from THREE points against TWO unknowns. One mid-health sample
--      closes it.
--
-- WHY THIS ONE IS DANGEROUS, AND WHAT IS DONE ABOUT IT.
-- updateReproduction() SPENDS THE GESTATION TIMER -- PlaceableHusbandryAnimals
-- :onPeriodChanged calls it and only THEN clamps the birth count to free slots,
-- which is exactly how a full pen loses both the calf and the months that made
-- it (§11.5). Calling it on a live cluster would destroy real breeding progress
-- on the player's farm.
--
-- So NOTHING here touches a live cluster. Every measurement runs on a CLONE
-- (cluster:clone(), confirmed to resolve in §10.5), and before a single clone is
-- used the probe PROVES the clone is independent: it snapshots the original's
-- fields, mutates the clone hard, re-reads the original and diffs. If ANY field
-- moved, the whole probe aborts and says so. A shallow clone sharing a table
-- would otherwise corrupt the herd silently, and the damage would not surface
-- until the next period change.
--
-- The sweeps are also RATIO-based where they can be. Sweeping health and
-- dividing by the price at health 100 measures the health term without needing
-- the price curve at all, so the result cannot be contaminated by a wrong curve.
-- Sweeping age at fixed health then measures the curve itself, which
-- independently cross-checks the XML read in §11.3.
--
-- Usage (needs game.xml development controls true):
--     arReproProbe                 : the biggest owned barn
--     arReproProbe <name fragment> : that barn
--
-- READ-ONLY with respect to the save. REMOVE with the other probes.
-- ============================================================================

local function rout(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[arRepro] " .. (ok and msg or tostring(fmt)))
end

-- Instance FIELDS, not methods. Enumeration works here even though it fails for
-- methods: the methods live behind the protected metatable (§10.5), the fields
-- sit on the object itself. This is what reveals the reproduction timer's name.
local function scalarFields(cl)
    local out = {}
    if type(cl) ~= "table" then return out end
    pcall(function()
        for k, v in pairs(cl) do
            local t = type(v)
            if type(k) == "string" and (t == "number" or t == "boolean" or t == "string") then
                out[k] = v
            end
        end
    end)
    return out
end

local function sortedKeys(t)
    local ks = {}
    for k in pairs(t) do ks[#ks + 1] = k end
    table.sort(ks)
    return ks
end

local function diffFields(before, after)
    local moved = {}
    for _, k in ipairs(sortedKeys(before)) do
        if after[k] ~= before[k] then
            moved[#moved + 1] = string.format("%s: %s -> %s", k,
                tostring(before[k]), tostring(after[k]))
        end
    end
    for _, k in ipairs(sortedKeys(after)) do
        if before[k] == nil then
            moved[#moved + 1] = string.format("%s: (absent) -> %s", k, tostring(after[k]))
        end
    end
    return moved
end

local function priceOf(cl)
    if cl == nil or cl.getSellPrice == nil then return nil end
    local ok, v = pcall(cl.getSellPrice, cl)
    if ok and type(v) == "number" then return v end
    return nil
end

-- ---------------------------------------------------------------------------
-- THE GATE. Everything below refuses to run unless this returns true.
--
-- It does not merely check that clone() returned something: it mutates the clone
-- and proves the ORIGINAL did not move. That is the only test that distinguishes
-- a real copy from a shallow one sharing sub-tables, and a shallow one would
-- corrupt the player's herd invisibly.
function AnimalFoodProbe.cloneIsSafe(cl)
    if cl == nil or cl.clone == nil then
        rout("  clone() is not available on this cluster -- ABORTING every sweep.")
        return false, nil
    end

    local before = scalarFields(cl)
    local okC, cp = pcall(cl.clone, cl)
    if not okC or type(cp) ~= "table" then
        rout("  clone() failed or returned %s -- ABORTING.", type(okC and cp or nil))
        return false, nil
    end
    if cp == cl then
        rout("  clone() returned THE SAME TABLE -- ABORTING (it is not a copy).")
        return false, nil
    end

    -- Mutate the clone as hard as anything below will.
    --
    -- THE CANARIES ARE DERIVED, NEVER CONSTANT. With fixed values this gate has a
    -- blind spot, found by tools/sellrules.lua against the twin of this function:
    -- a write-through clone leaves the ORIGINAL holding the canaries, so a SECOND
    -- call writes the same numbers, sees nothing move, and passes the very clone
    -- it just rejected. Offsetting from what the original holds now means the
    -- canary can never already be there.
    local CANARY_N = (cl.numAnimals or 0) + 1000
    local CANARY_H = (cl.health or 0) + 1000
    local CANARY_A = (cl.age or 0) + 1000
    pcall(function()
        cp.numAnimals = CANARY_N
        cp.health = CANARY_H
        cp.age = CANARY_A
    end)

    local took = (cp.numAnimals == CANARY_N) and (cp.health == CANARY_H) and (cp.age == CANARY_A)
    if not took then
        rout("  the clone did not accept a write (numAnimals=%s health=%s age=%s)",
             tostring(cp.numAnimals), tostring(cp.health), tostring(cp.age))
        rout("  ABORTING: cannot sweep what cannot be set.")
        return false, nil
    end

    local moved = diffFields(before, scalarFields(cl))
    if #moved > 0 then
        rout("  *** THE ORIGINAL CLUSTER MOVED WHEN THE CLONE WAS WRITTEN:")
        for _, m in ipairs(moved) do rout("        %s", m) end
        rout("  *** clone() is SHALLOW. ABORTING before anything is damaged.")
        -- Detecting it required making it happen, so put the herd back. The gate
        -- must not itself be what ages or re-prices a player's animals.
        local repaired = 0
        for k, v in pairs(before) do
            if cl[k] ~= v then
                local okR = pcall(function() cl[k] = v end)
                if okR and cl[k] == v then repaired = repaired + 1 end
            end
        end
        rout("  *** restored %d field(s) on the live cluster.", repaired)
        return false, nil
    end

    rout("  clone() verified independent: the clone took %d/%d writes and the", 3, 3)
    rout("  original did not move on any of %d scalar field(s).", #sortedKeys(before))
    return true, cp
end

-- A fresh clone per sample. updateReproduction() spends internal timer state, so
-- reusing one clone across samples would measure the timer, not the yield.
local function freshClone(cl)
    local ok, cp = pcall(cl.clone, cl)
    if ok and type(cp) == "table" and cp ~= cl then return cp end
    return nil
end

-- ---------------------------------------------------------------------------
-- The cluster's own fields. This is what names the reproduction timer, which is
-- the thing §11.5 could describe but not read.
function AnimalFoodProbe.dumpClusterFields(cl)
    local f = scalarFields(cl)
    local ks = sortedKeys(f)
    rout("  cluster fields (%d):", #ks)
    local line = ""
    for i, k in ipairs(ks) do
        line = line .. string.format("%s=%s  ", k, tostring(f[k]))
        if i % 4 == 0 then rout("    %s", line); line = "" end
    end
    if line ~= "" then rout("    %s", line) end
end

-- The subType's runtime config. §11.4 could only read the HORSE numbers out of
-- the XML (increase 10/h, decrease 25/h, threshold 0.45); every other type uses
-- engine defaults that are only visible here.
function AnimalFoodProbe.dumpSubTypeConfig(sti)
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil or asys.getSubTypeByIndex == nil or sti == nil then return end
    local okS, st = pcall(asys.getSubTypeByIndex, asys, sti)
    if not okS or type(st) ~= "table" then return end

    rout("  subType %s (index %s)", tostring(st.name), tostring(sti))
    rout("    health:  increase/h=%s  decrease/h=%s  threshold=%s",
         tostring(st.healthIncreaseHour), tostring(st.healthDecreaseHour),
         tostring(st.healthThresholdFactor))
    rout("    repro:   minAgeMonth=%s  durationMonth=%s  minHealth=%s",
         tostring(st.reproductionMinAgeMonth), tostring(st.reproductionDurationMonth),
         tostring(st.reproductionMinHealth))
    rout("    price:   buyPrice=%s  (a curve object, not a scalar, if this reads 'table')",
         tostring(st.buyPrice))
end

-- ---------------------------------------------------------------------------
-- HEALTH TERM, measured as a RATIO so it needs no price curve.
-- price(h) / price(100) should be (0.40 + 0.60h) / 1.00 exactly.
function AnimalFoodProbe.sweepHealth(cl)
    rout("")
    rout("HEALTH TERM  (ratio against health 100, so the price CURVE cancels out)")
    local ref = freshClone(cl)
    if ref == nil then rout("  no clone; skipped"); return end
    ref.health = 100
    local base = priceOf(ref)
    if base == nil or base <= 0 then
        rout("  price at health 100 is %s -- cannot form ratios; skipped", tostring(base))
        return
    end
    rout("  price at health 100 = %.4f   (age %s)", base, tostring(ref.age))
    rout("  %6s %14s %10s %10s %8s", "health", "price", "ratio", "predicted", "delta")
    local worst = 0
    for _, h in ipairs({ 0, 10, 25, 50, 75, 90, 100 }) do
        local c = freshClone(cl)
        if c ~= nil then
            c.health = h
            local p = priceOf(c)
            if p ~= nil then
                local ratio = p / base
                local pred  = 0.40 + 0.60 * (h / 100)
                local d     = ratio - pred
                if math.abs(d) > worst then worst = math.abs(d) end
                rout("  %6d %14.4f %10.4f %10.4f %8.4f", h, p, ratio, pred, d)
            end
        end
    end
    rout("  worst deviation from 0.40 + 0.60h: %.5f  -> %s", worst,
         worst < 0.0005 and "CONFIRMED" or "THE MODEL IS WRONG, read the ratios above")
end

-- AGE CURVE, measured at fixed health. Independently reproduces the sellPrice
-- keys read out of the SDK XML in §11.3 -- if these disagree, the XML is not
-- what the running game is using (a map or a mod may replace it).
function AnimalFoodProbe.sweepAge(cl)
    rout("")
    rout("AGE CURVE  (health pinned at 100, so this IS the raw sellPrice curve)")
    rout("  %6s %14s %12s", "age mo", "price", "d/month")
    local prev, prevAge = nil, nil
    for _, a in ipairs({ 0, 3, 6, 9, 12, 18, 24, 30, 36, 42, 48, 60, 72 }) do
        local c = freshClone(cl)
        if c ~= nil then
            c.health = 100
            c.age = a
            local p = priceOf(c)
            if p ~= nil then
                local slope = ""
                if prev ~= nil and a > prevAge then
                    slope = string.format("%+.1f", (p - prev) / (a - prevAge))
                end
                rout("  %6d %14.2f %12s", a, p, slope)
                prev, prevAge = p, a
            end
        end
    end
    rout("  a NEGATIVE d/month is the decline after peak -- expected for COW only (§11.3)")
end

-- ---------------------------------------------------------------------------
-- REPRODUCTION YIELD. The open question, and the one with a side effect.
--
-- Each sample uses its OWN fresh clone: updateReproduction() spends internal
-- timer state, so reusing one clone would measure the timer rather than the
-- yield. The clone's fields are dumped before and after the FIRST call so the
-- timer field identifies itself by being the thing that moved.
function AnimalFoodProbe.sweepReproduction(cl)
    rout("")
    rout("REPRODUCTION YIELD")
    if cl.updateReproduction == nil then
        rout("  updateReproduction is NOT on this cluster.")
        rout("  Expected under RealisticLivestock, which replaces reproduction (§10.5).")
        return
    end

    -- What does one call actually change? Name the timer.
    local c0 = freshClone(cl)
    if c0 == nil then rout("  no clone; skipped"); return end
    local b4 = scalarFields(c0)
    local okR, yield0 = pcall(c0.updateReproduction, c0)
    if not okR then
        rout("  updateReproduction THREW: %s", tostring(yield0))
        return
    end
    local moved = diffFields(b4, scalarFields(c0))
    rout("  one call on a clone of the real cluster (n=%s age=%s health=%s repro=%s) -> %s",
         tostring(b4.numAnimals), tostring(b4.age), tostring(b4.health),
         tostring(b4.reproduction), tostring(yield0))
    if (b4.numAnimals or 0) == 0 then
        rout("  NOTE clone() copies IDENTITY (subtype, age, health, reproduction) but")
        rout("  zeroes numAnimals, so this first call was bound to yield 0. The sweeps")
        rout("  below set the headcount explicitly.")
    end
    if #moved > 0 then
        rout("  it changed these fields (this NAMES the gestation timer):")
        for _, m in ipairs(moved) do rout("        %s", m) end
    else
        rout("  it changed NO scalar field -- the timer is not a scalar on the cluster.")
    end

    -- Does yield scale with headcount?
    rout("")
    rout("  vs HEADCOUNT (age and health held at the real cluster's values)")
    rout("  %10s %10s", "numAnimals", "yield")
    for _, n in ipairs({ 1, 5, 10, 25, 50, 100, 205, 500 }) do
        local c = freshClone(cl)
        if c ~= nil then
            c.numAnimals = n
            local ok, y = pcall(c.updateReproduction, c)
            rout("  %10d %10s", n, ok and tostring(y) or "threw")
        end
    end

    -- Does the 0.75 health gate actually bite? §11.4 reads minHealthFactor=0.75
    -- from the XML, but the GATE lives in this stripped function.
    rout("")
    rout("  vs HEALTH  (headcount pinned at 100; the XML says nothing breeds below 0.75)")
    rout("  %8s %10s", "health", "yield")
    for _, h in ipairs({ 0, 25, 50, 70, 74, 75, 76, 90, 100 }) do
        local c = freshClone(cl)
        if c ~= nil then
            c.numAnimals = 100
            c.health = h
            local ok, y = pcall(c.updateReproduction, c)
            rout("  %8d %10s", h, ok and tostring(y) or "threw")
        end
    end

    -- And the minimum breeding age.
    rout("")
    rout("  vs AGE  (headcount 100, health 100)")
    rout("  %8s %10s", "age mo", "yield")
    for _, a in ipairs({ 0, 3, 6, 8, 12, 18, 22, 24, 36, 48 }) do
        local c = freshClone(cl)
        if c ~= nil then
            c.numAnimals = 100
            c.health = 100
            c.age = a
            local ok, y = pcall(c.updateReproduction, c)
            rout("  %8d %10s", a, ok and tostring(y) or "threw")
        end
    end

    rout("")
    rout("  READ IT CAREFULLY: a column of zeros may mean the gate bit, OR that the")
    rout("  gestation timer on this cluster is simply not due. Compare against the")
    rout("  first single call above, and against a barn whose animals are older.")
end

-- ---------------------------------------------------------------------------
-- THE COUNTER, and the question the first run raised.
--
-- The first run named the gestation timer: the cluster carries `reproduction`,
-- and one call took it 50 -> 0 while yielding one offspring PER ANIMAL. With
-- durationMonth=2 for chickens the reading is that each period adds
-- 100/durationMonth, and at 100 the whole cluster births and resets.
--
-- But every clone inherits reproduction=50, so that sweep held the counter
-- CONSTANT and could not see whether yield depends on it. This sets it directly.
--
-- The second question matters more. When a gate bites -- health below 0.75, or
-- under age -- is the accumulated progress CONSUMED anyway? That is exactly the
-- shape of the full-pen bug in §11.5, where updateReproduction() spends the
-- timer and the clamp discards the result afterwards. If an underfed herd also
-- burns its counter, then poor feeding does not merely pause breeding, it
-- destroys the progress permanently, and that changes what a sell rule should
-- advise.
function AnimalFoodProbe.sweepReproCounter(cl)
    if cl == nil or cl.updateReproduction == nil then return end

    rout("")
    rout("GESTATION COUNTER  (n=100, health=100, age=12; only `reproduction` varies)")
    rout("  %8s %10s %14s", "repro in", "yield", "repro after")
    for _, r in ipairs({ 0, 25, 49, 50, 51, 75, 99, 100 }) do
        local c = freshClone(cl)
        if c ~= nil then
            c.numAnimals, c.health, c.age, c.reproduction = 100, 100, 12, r
            local ok, y = pcall(c.updateReproduction, c)
            rout("  %8d %10s %14s", r, ok and tostring(y) or "threw", tostring(c.reproduction))
        end
    end
    rout("  if yield is 100 only at the top of the range, the counter is progress toward")
    rout("  a birth; if it is 100 throughout, the counter gates nothing.")

    rout("")
    rout("IS PROGRESS BURNED WHEN A GATE BITES?  (repro in = 50 every time)")
    rout("  This is the §11.5 shape: does the call SPEND the timer even when it")
    rout("  yields nothing? If it does, underfeeding destroys progress permanently.")
    rout("  %-28s %8s %14s", "case", "yield", "repro after")
    local cases = {
        { "control: healthy, mature",   100, 100, 12 },
        { "health 50 (below the gate)", 100,  50, 12 },
        { "health 10 (your pastures)",  100,  10, 12 },
        { "age 3 (below minAge 6)",     100, 100,  3 },
        { "one animal only",              1, 100, 12 },
    }
    for _, cs in ipairs(cases) do
        local c = freshClone(cl)
        if c ~= nil then
            c.numAnimals, c.health, c.age, c.reproduction = cs[2], cs[3], cs[4], 50
            local ok, y = pcall(c.updateReproduction, c)
            rout("  %-28s %8s %14s", cs[1], ok and tostring(y) or "threw",
                 tostring(c.reproduction))
        end
    end
    rout("  'repro after' = 50 means the progress SURVIVED the refusal.")
    rout("  Anything lower means it was spent for nothing -- a second silent loss")
    rout("  beside the full-pen one, and a much better reason to fix the feeding.")
end

-- ---------------------------------------------------------------------------
function AnimalFoodProbe.runReproProbe(fragment)
    rout("================= arReproProbe =================")

    local rlOn, rlG, rlM = realisticLivestockActive()
    if rlOn or #rlM > 0 then
        rout("  *** RealisticLivestock IS ACTIVE (%s). It replaces the cluster class",
             joinList(rlM, 4))
        rout("  *** outright, so every figure below is RL's model, not the base game's.")
    else
        rout("  RealisticLivestock not detected: this is the BASE GAME.")
    end

    local barns = findAnimalBarns(fragment)
    if #barns == 0 then
        rout("  no husbandry matched. Nothing was touched.")
        return
    end

    -- findAnimalBarns already sorts owned-first then by headcount, so [1] is the
    -- most populated barn on the player's own farm (§10.8).
    local barn, name = barns[1].placeable, barns[1].name
    rout("  barn: %s  (farm=%s, %d animals)", name, tostring(barns[1].farm), barns[1].count)

    local clusters = nil
    if barn.getClusters ~= nil then
        local okC, c = pcall(barn.getClusters, barn)
        if okC then clusters = c end
    end
    if type(clusters) ~= "table" or countPairs(clusters) == 0 then
        rout("  it has no clusters. Pass a fragment naming a barn that holds animals.")
        return
    end

    local cl = nil
    for _, c in pairs(clusters) do cl = c; break end

    rout("")
    rout("SAFETY GATE  (nothing below runs unless clone() is proven independent)")
    local safe = AnimalFoodProbe.cloneIsSafe(cl)
    if not safe then
        rout("")
        rout("  ABORTED. No sweep was run and NO LIVE CLUSTER WAS TOUCHED.")
        rout("================================================")
        return
    end

    rout("")
    AnimalFoodProbe.dumpClusterFields(cl)
    rout("")
    AnimalFoodProbe.dumpSubTypeConfig(cl.subTypeIndex)

    AnimalFoodProbe.sweepHealth(cl)
    AnimalFoodProbe.sweepAge(cl)
    AnimalFoodProbe.sweepReproduction(cl)
    AnimalFoodProbe.sweepReproCounter(cl)

    -- Prove it again at the END. The gate tested one clone before the sweeps; this
    -- tests that ~40 clones and several hundred writes later the real cluster is
    -- still exactly as it was. A leak that only appears under repetition would
    -- otherwise pass the gate and still cost the player their herd.
    rout("")
    rout("FINAL CHECK  (the live cluster, after every sweep)")
    local now = scalarFields(cl)
    local ok = true
    for _, k in ipairs(sortedKeys(now)) do
        if k == "numAnimals" or k == "health" or k == "age" then
            rout("    %s = %s", k, tostring(now[k]))
        end
    end
    rout("    compare against the 'cluster fields' dump above: numAnimals, health and")
    rout("    age must be IDENTICAL. If any moved, a clone leaked and it is a bug in")
    rout("    THIS PROBE, not in the game.")
    if ok then rout("") end
    rout("  Nothing was bought, sold, bred or aged. The save is untouched.")
    rout("================================================")
end

function AnimalFoodProbe:consoleCommandRepro(fragment)
    local ok, err = pcall(AnimalFoodProbe.runReproProbe, fragment)
    if not ok then return "arReproProbe failed: " .. tostring(err) end
    return "arReproProbe done -- see log.txt"
end
