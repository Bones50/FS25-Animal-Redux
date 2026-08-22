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
            local need = demand * g.eat / eatSum
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
    AnimalFoodProbe._registered = true
    return true
end

function AnimalFoodProbe:consoleCommand(fragment, demand)
    local ok, err = pcall(AnimalFoodProbe.run, fragment, demand)
    if not ok then return "arFoodProbe failed: " .. tostring(err) end
    return "arFoodProbe done -- see log.txt"
end
