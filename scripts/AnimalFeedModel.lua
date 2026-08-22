-- ============================================================================
-- AnimalFeedModel.lua  (Animal Redux)
--
-- What a husbandry trough SHOULD hold, and why.
--
-- THE RULE, measured rather than read. AnimalFoodSystem is absent from the
-- shipped SDK source, so `consumeFood` -- which scales a husbandry's production
-- by how well its trough matches the declared food groups -- had to be measured
-- in game with arFoodProbe. What it does:
--
--   PARALLEL animals (pig, horse, chicken): factor = the SUM of the production
--       weights of the groups PRESENT. A missing group costs exactly its weight
--       and CANNOT be compensated with more of another food. Measured: a pig
--       trough of pure maize scores 0.50, a correct blend scores 1.00.
--   SERIAL animals (cow): the groups are ALTERNATIVES -- quality tiers. The
--       factor is the BEST single present group. Measured: forage 1.00,
--       silage 0.80, grass 0.40. Best-first is CORRECT here, and a blanket
--       "always mix" would be a new bug pointing the other way.
--
-- THE SPLIT USES eatWeight, NOT productionWeight, and this is the subtle part.
-- They are separate declared vectors and they disagree: a horse eats hay about
-- three times faster than oats while oats contribute more production. Fill by
-- productionWeight and the trough scores a perfect 1.0 on the hour it is filled
-- and then STARVES the fastest-draining group -- measured in the harness at
-- ~53 h against 100 h. Filling by eatWeight makes every group run out together,
-- so the factor holds until the whole trough does.
-- (Pig's two vectors happen to be identical, so pigs alone cannot show this.)
--
-- EVERYTHING IS READ LIVE, AND THAT IS A HARD REQUIREMENT, not tidiness:
--   * FS25_Animalic replaces the ENTIRE food definition at load
--     (AnimalFoodSystem.loadMapData), and a map may do the same. So the groups,
--     the weights and the consumption type are read from animalFoodSystem every
--     time and NEVER hardcoded. Do not cache them across a mission load.
--   * RealisticLivestock no-ops the base per-cluster demand calculation and
--     computes `spec_husbandryFood.litersPerHour` per INDIVIDUAL animal instead.
--     It writes the same field, so READ THAT FIELD and never recompute demand
--     from clusters -- recomputing would be silently wrong under RL and would
--     ignore RL's own foodScale setting.
--
-- Verified offline by tools/feedmix.lua (52 checks), whose section 1 proves this
-- rule reproduces every in-game sample before anything is built on it.
-- ============================================================================

AnimalFeedModel = {}

-- Weight vectors summing to about this much mean COMPONENTS rather than
-- ALTERNATIVES. Only used when the runtime object does not expose
-- `consumptionType` -- see readConsumptionType.
local SUM_IS_RATIO_TOL = 0.05

-- ---------------------------------------------------------------------------
local function foodSystem()
    return g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil
end

---The animal type index a husbandry feeds, or nil.
function AnimalFeedModel.animalTypeIndexOf(placeable)
    if placeable == nil then return nil end
    local spec = placeable.spec_husbandryFood
    local ati = spec ~= nil and spec.animalTypeIndex or nil
    if ati == nil and placeable.getAnimalTypeIndex ~= nil then
        local ok, a = pcall(placeable.getAnimalTypeIndex, placeable)
        if ok then ati = a end
    end
    return ati
end

---SERIAL or PARALLEL, and where the answer came from.
-- `consumptionType` is a DECLARED attribute in animalFood.xml, but whether it
-- survives onto the runtime object is not something the SDK source can settle
-- (AnimalFoodSystem is stripped). So: prefer the declared field, and fall back
-- to the arithmetic that the declared field is really a shorthand for -- weights
-- summing to 1 mean components, summing to more mean alternatives. The fallback
-- reproduces every animal type measured in game, so a miss here is not fatal.
local function readConsumptionType(food, groups)
    local declared = food ~= nil and food.consumptionType or nil
    if type(declared) == "string" and declared ~= "" then
        return string.upper(declared), "declared"
    end
    local sum = 0
    for _, g in ipairs(groups) do sum = sum + g.production end
    if sum > 1.0 + SUM_IS_RATIO_TOL then
        return "SERIAL", "inferred from weights summing to " .. string.format("%.2f", sum)
    end
    return "PARALLEL", "inferred from weights summing to " .. string.format("%.2f", sum)
end

---Read the live food model for an animal type.
-- Returns model, nil  |  nil, reason
function AnimalFeedModel.read(animalTypeIndex, supportedFillTypes)
    if animalTypeIndex == nil then return nil, "no animalTypeIndex" end
    local afs = foodSystem()
    if afs == nil or afs.getAnimalFood == nil then return nil, "no animalFoodSystem" end

    local okF, food = pcall(afs.getAnimalFood, afs, animalTypeIndex)
    if not okF or food == nil or food.groups == nil then
        return nil, "getAnimalFood returned nothing"
    end

    local groups, sawEatWeight = {}, false
    for _, grp in pairs(food.groups) do
        local fts, rep = {}, nil
        for _, ft in pairs(grp.fillTypes or {}) do
            fts[#fts + 1] = ft
            -- A group is represented by a fill type the BUILDING actually
            -- supports. Within a group the members are interchangeable for the
            -- factor (measured: SORGHUM == MAIZE == 0.50), so any supported one
            -- will do and the choice is free to be made on availability later.
            if rep == nil and (supportedFillTypes == nil or supportedFillTypes[ft] ~= nil) then
                rep = ft
            end
        end
        local production = grp.productionWeight or 0
        local eat = grp.eatWeight
        if eat ~= nil then sawEatWeight = true else eat = production end
        groups[#groups + 1] = {
            title = tostring(grp.title or "?"),
            production = production,
            eat = eat,
            fts = fts,
            rep = rep,
        }
    end
    if #groups == 0 then return nil, "animal food declares no groups" end

    table.sort(groups, function(a, b) return a.production > b.production end)

    -- MIXTURES (complete rations, e.g. PIGFOOD). These belong to NO group, which
    -- is why the model ignored them at first -- and that was a regression waiting
    -- to happen: `addFood` DECOMPOSES a mixture into its ingredients by weight
    -- (PlaceableHusbandryFood.lua:546), so one delivery satisfies every group in
    -- the recipe's ratio. A farm whose protein all goes INTO making pigfood has no
    -- loose soybean, so a plan naming soybean scores 0.80 where DR's own logic
    -- would have used the pigfood and scored 1.00.
    local mixtures = {}
    if afs.getMixturesByAnimalTypeIndex ~= nil then
        local okM, mix = pcall(afs.getMixturesByAnimalTypeIndex, afs, animalTypeIndex)
        if okM and type(mix) == "table" then
            for _, ft in ipairs(mix) do
                if supportedFillTypes == nil or supportedFillTypes[ft] ~= nil then
                    mixtures[#mixtures + 1] = ft
                end
            end
        end
    end

    local ctype, ctypeSource = readConsumptionType(food, groups)
    return {
        animalTypeIndex = animalTypeIndex,
        consumptionType = ctype,
        consumptionTypeSource = ctypeSource,
        groups = groups,
        mixtures = mixtures,
        hasEatWeight = sawEatWeight,
    }
end

-- ---------------------------------------------------------------------------
---Is any fill type of this group in the trough?
function AnimalFeedModel.groupPresent(group, trough)
    for _, ft in ipairs(group.fts) do
        if (trough[ft] or 0) > 0 then return true end
    end
    return false
end

---The production factor a given trough would earn. The authoritative answer always
-- comes from the engine (measureFactor); this is for reporting and offline reasoning.
--
-- THE FACTOR IS QUANTITY-SENSITIVE, not merely presence-based, and that was a
-- late and expensive correction. Measured on a horse barn: adding ONE litre of
-- carrot against a 4.8 L/h need moved the factor by +0.0129, not by carrot's full
-- +0.0476 weight. A group contributes in proportion to how much of its hourly
-- need is stocked:
--
--     factor = SUM over groups of  production x min(1, held / (demand x eatShare))
--
-- Every earlier measurement had each group stocked far past its need, so the
-- min() term was always 1 and the simpler "sum of the weights of the groups
-- present" looked right. It is the fully-stocked special case.
--
-- `demand` is OPTIONAL. Omit it for the fully-stocked question ("if every group
-- were adequately stocked, what would this score?"), which is what the plan is
-- built to achieve and what the offline harness reasons about. Pass the barn's
-- real litersPerHour to ask what a PARTICULAR trough scores right now.
--
-- APPROXIMATE while quantity-limited: it reproduced 0.5355 against a measured
-- 0.5417, so the real curve is not quite linear. arFeedPartial maps it properly.
function AnimalFeedModel.factorOf(model, trough, demand)
    local total = 0
    for _, litres in pairs(trough) do total = total + (litres or 0) end
    if total <= 0 then return 0 end

    -- how much of each group is present, as a fraction of what it needs
    local eatSum = 0
    if demand ~= nil and demand > 0 then
        for _, g in ipairs(model.groups) do eatSum = eatSum + g.eat end
    end
    local function served(g)
        local held = 0
        for _, ft in ipairs(g.fts) do held = held + (trough[ft] or 0) end
        if held <= 0 then return 0 end
        if demand == nil or demand <= 0 then return 1 end
        -- SERIAL groups are ALTERNATIVES: the herd eats ONE tier at the full rate,
        -- so each tier's requirement is the whole demand. Splitting it by eat share
        -- (right for PARALLEL components) understated a cow tier's need fourfold.
        local need
        if model.consumptionType == "SERIAL" then
            need = demand
        else
            if eatSum <= 0 then return 1 end
            need = demand * g.eat / eatSum
        end
        if need <= 0 then return 1 end
        return math.min(1, held / need)
    end

    if model.consumptionType == "SERIAL" then
        -- BEST-FIRST WEIGHTED AVERAGE, not the best tier's weight. Measured with
        -- arFeedPartial: sweeping a cow's forage while the other tiers stayed full
        -- gave 0.8000 / 0.8125 / 0.8250 / 0.8500 / 0.9000. A max-of-tiers model
        -- predicts a flat 0.80 throughout and is simply wrong.
        --
        -- What the herd actually does is eat as much of the best tier as exists
        -- and then fall to the next, so the factor is what it ATE, weighted:
        --     factor = SUM (litres taken from tier / demand) x tier production
        -- At 25% forage that is 0.25 x 1.0 + 0.75 x 0.8 = 0.85, exact.
        --
        -- Consequence worth knowing: PARTIAL forage is worth having. A cow on
        -- silage plus a quarter of its forage scores 0.85, not 0.80 -- which is
        -- why the plan offers every tier and lets DR's quality-then-distance sort
        -- take the best available first.
        if demand == nil or demand <= 0 then
            -- the fully-stocked question: the best present tier covers everything
            local best = 0
            for _, g in ipairs(model.groups) do
                if AnimalFeedModel.groupPresent(g, trough) and g.production > best then
                    best = g.production
                end
            end
            return best
        end
        -- model.groups is sorted by production DESC in read(), so this walks the
        -- tiers in the order the animals eat them.
        local remaining, f = demand, 0
        for _, g in ipairs(model.groups) do
            local held = 0
            for _, ft in ipairs(g.fts) do held = held + (trough[ft] or 0) end
            local take = math.min(held, remaining)
            if take > 0 then
                f = f + (take / demand) * g.production
                remaining = remaining - take
            end
            if remaining <= 0 then break end
        end
        return math.min(1.0, f)
    end

    local sum = 0
    for _, g in ipairs(model.groups) do sum = sum + g.production * served(g) end
    return math.min(1.0, sum)
end

---What the trough SHOULD hold, as fillType -> litres, for a pool of `litres`.
-- SERIAL   -> all of it in the best group (what DR already does, and correct).
-- PARALLEL -> split by eatWeight so every group empties together.
function AnimalFeedModel.plannedFill(model, litres)
    local out = {}
    if model == nil or litres == nil or litres <= 0 then return out end

    if model.consumptionType == "SERIAL" then
        for _, g in ipairs(model.groups) do        -- sorted by production DESC
            if g.rep ~= nil then out[g.rep] = litres; return out end
        end
        return out
    end

    local sum = 0
    for _, g in ipairs(model.groups) do
        if g.rep ~= nil then sum = sum + g.eat end
    end
    if sum <= 0 then return out end
    for _, g in ipairs(model.groups) do
        if g.rep ~= nil then out[g.rep] = litres * g.eat / sum end
    end
    return out
end

---The plan, restricted to fill types Distribution Redux will actually accept.
--
-- DR hands the planner a narrower list than the building supports: blocked
-- products, globally excluded types and water are already gone. Planning against
-- the wider set would name a product DR then drops, and that group would end up
-- with NOTHING -- costing its whole production weight for no visible reason. So
-- representatives are chosen from `allowed` only.
--
-- A group with no allowed member cannot be filled at all, and its weight is lost
-- whatever we do. The pool is therefore RENORMALISED across the groups that CAN
-- be filled, rather than reserving space for one that can never arrive: the
-- factor is capped either way, but this at least keeps the trough full and the
-- remaining groups running for as long as possible.
-- EVERY allowed member of a group is offered, not just the first one.
--
-- This was the bug that made a pigsty sit at 0.30 while its silos held sorghum
-- and canola: the plan named one REPRESENTATIVE per group, chosen from the
-- ALLOWED list -- which only means "the barn accepts it and the player has not
-- blocked it", and says nothing about whether the farm holds a single litre. With
-- no maize and no soybean, two groups were planned against products that did not
-- exist while their alternates were never asked for.
--
-- A planner cannot see the farm's stock. DR can, at slot-build time, and DR's own
-- feed logic was always stock-aware. So the plan states the GROUP's need and
-- lists every member that could satisfy it; DR gathers candidates across all of
-- them and draws from whatever is actually there, nearest first. Within a group
-- the members are interchangeable for the production factor (measured: SORGHUM
-- scores exactly as MAIZE), so this cannot cost anything.
--
-- Returns the API v2 array form:  { { fillTypes = {...}, litres = n }, ... }
function AnimalFeedModel.planWithin(model, litres, allowed)
    local out = {}
    if model == nil or litres == nil or litres <= 0 or allowed == nil then return out end

    local ok = {}
    for _, ft in ipairs(allowed) do ok[ft] = true end

    -- A COMPLETE RATION IS AN ALTERNATIVE TO EVERY GROUP, and that is exactly how
    -- it is offered: appended to each entry's fillTypes rather than handled as a
    -- special case.
    --
    -- It works because DR's foodQualityMap already ranks a mixture at 1.0, ABOVE
    -- every group weight, so buildSlotCandidates sorts it first in every request
    -- that lists it. If the farm has pigfood, DR sources pigfood for each group's
    -- share; every litre decomposes into the full recipe ratio, so the pool ends
    -- up correctly mixed from one product. If pigfood runs out, each request falls
    -- back to that group's own crops. If there is none at all, nothing changes.
    --
    -- No sourcing query needed: DR already answers "which of these can I get" at
    -- slot-build time, which is the whole point of the alternatives form.
    local rations = {}
    for _, ft in ipairs(model.mixtures or {}) do
        if ok[ft] then rations[#rations + 1] = ft end
    end

    local usable, sum = {}, 0
    for _, g in ipairs(model.groups) do
        local members = {}
        for _, ft in ipairs(g.fts) do
            if ok[ft] then members[#members + 1] = ft end
        end
        -- offered even when the group itself has no allowed member: a complete
        -- ration can satisfy a group whose own crops are blocked or absent
        for _, ft in ipairs(rations) do members[#members + 1] = ft end
        if #members > 0 then
            usable[#usable + 1] = { members = members, eat = g.eat, production = g.production }
            sum = sum + g.eat
        end
    end
    if #usable == 0 then return out end

    if model.consumptionType == "SERIAL" then
        -- ONE request, with EVERY tier offered as an alternative.
        --
        -- Naming only the best tier repeated the pigsty bug one level up: with TMR
        -- stopped, the plan asked for FORAGE, the farm had none, DR emitted no slot
        -- and delivered nothing -- while silage and hay sat in the silos unasked
        -- for and the cows fell back to grazing the meadow. "Best" had been chosen
        -- from what the barn ACCEPTS, not from what the farm HAS.
        --
        -- Listing every tier does not lose the quality preference, because DR
        -- already applies it: buildSlotCandidates sorts candidates by the food
        -- quality map (productionWeight) and only then by distance. So DR takes
        -- the best tier it can actually source and falls back when that runs
        -- short -- which is exactly what its own best-first logic always did well,
        -- and the reason SERIAL animals never needed fixing in the first place.
        local all = {}
        for _, u in ipairs(usable) do
            for _, ft in ipairs(u.members) do all[#all + 1] = ft end
        end
        out[1] = { fillTypes = all, litres = litres }
        return out
    end

    if sum <= 0 then return out end
    for _, u in ipairs(usable) do
        out[#out + 1] = { fillTypes = u.members, litres = litres * u.eat / sum }
    end
    return out
end

---One concrete fill type per entry, for measuring or displaying a plan.
-- Members of a group are interchangeable for the factor, so the first is
-- representative; what DR actually delivers depends on stock.
function AnimalFeedModel.entriesToMix(entries)
    local mix = {}
    for _, e in ipairs(entries or {}) do
        local ft = e.fillTypes ~= nil and e.fillTypes[1] or nil
        if ft ~= nil then mix[ft] = (mix[ft] or 0) + e.litres end
    end
    return mix
end

-- ---------------------------------------------------------------------------
---Ask the ENGINE what a trough scores, rather than trusting the model.
--
-- Safe to call freely: `consumeFood` does NOT remove food -- it fills the
-- `consumedFood` table and returns the factor, and PlaceableHusbandryFood's
-- updateFeeding applies the removal afterwards. We never apply it. The barn's
-- own fillLevels are snapshotted and restored on EVERY path, including a throw.
-- Returns factor, consumedTable | nil, nil, errText
function AnimalFeedModel.measureFactor(placeable, animalTypeIndex, mix, demand)
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    if spec == nil or spec.fillLevels == nil then return nil, nil, "no fillLevels" end
    local afs = foodSystem()
    if afs == nil or afs.consumeFood == nil then return nil, nil, "no consumeFood" end

    local snap = {}
    for ft, lvl in pairs(spec.fillLevels) do snap[ft] = lvl end

    for ft in pairs(spec.fillLevels) do spec.fillLevels[ft] = 0 end
    for ft, litres in pairs(mix) do spec.fillLevels[ft] = litres end

    local consumed = {}
    local ok, factorOrErr = pcall(afs.consumeFood, afs, animalTypeIndex, demand, placeable, consumed)

    for ft in pairs(spec.fillLevels) do spec.fillLevels[ft] = nil end
    for ft, lvl in pairs(snap) do spec.fillLevels[ft] = lvl end

    if not ok then return nil, nil, tostring(factorOrErr) end
    return factorOrErr, consumed, nil
end

-- ---------------------------------------------------------------------------
---The barn's live demand, in litres per hour.
-- READ, never recomputed: RealisticLivestock replaces the base per-cluster
-- calculation with a per-animal one but writes this same field, so reading it
-- is correct under both and recomputing would be wrong under RL.
function AnimalFeedModel.demandPerHour(placeable)
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    if spec == nil then return 0 end
    local lph = spec.litersPerHour
    if type(lph) ~= "number" then return 0 end
    return lph
end

---What the animals can actually EAT, as fillType -> litres, plus the total.
--
-- THE AUTHORITATIVE READ, and it is not the trough. `spec_husbandryFood
-- .fillLevels` is only what has been tipped in; PlaceableHusbandryMeadow
-- overrides `getAvailableFood` so a grazing barn has food that never appears
-- there. Measured with arAvailFood: a cow barn holding only DRYGRASS and SILAGE
-- reported 828 L of GRASS_WINDROW, and a sheep barn holding 283 L of hay reported
-- 1,197 L of grass. That pasture grass is why a cow with an empty trough still
-- scored 0.40.
--
-- SHAPE, measured rather than guessed (both implementations are stripped):
--   getAvailableFood()    -> nil    -- the no-argument form does not work
--   getAvailableFood(ft)  -> number -- litres, trough PLUS meadow
-- `getFoodInfos()` gives the same picture per GROUP and lists the meadow as its
-- own pseudo-entry ("Meadow (100%)", `ignoreCapacity = true`), which is the
-- better source if a group-level total is ever wanted.
--
-- Falls back to fillLevels when the method is absent, so nothing depends on it.
function AnimalFeedModel.availableOf(placeable, fillTypes)
    local out, total = {}, 0
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    if spec == nil then return out, 0 end

    if placeable.getAvailableFood ~= nil and fillTypes ~= nil then
        for _, ft in ipairs(fillTypes) do
            if out[ft] == nil then
                local ok, litres = pcall(placeable.getAvailableFood, placeable, ft)
                if ok and type(litres) == "number" and litres > 0 then
                    out[ft] = litres
                    total = total + litres
                end
            end
        end
        return out, total
    end

    return AnimalFeedModel.troughOf(placeable)
end

---Current TROUGH contents as fillType -> litres, plus the total. This is what has
-- been delivered, and deliberately EXCLUDES grazing -- use availableOf for what
-- the animals can actually eat.
function AnimalFeedModel.troughOf(placeable)
    local out, total = {}, 0
    local spec = placeable ~= nil and placeable.spec_husbandryFood or nil
    if spec == nil or spec.fillLevels == nil then return out, 0 end
    for ft, lvl in pairs(spec.fillLevels) do
        if (lvl or 0) > 0 then out[ft] = lvl; total = total + lvl end
    end
    return out, total
end

-- ============================================================================
-- arFeedPlan -- dev verification for the model above.
--
-- For every animal type on the farm it prints, side by side:
--   * where the data came from (declared consumptionType or inferred; is
--     eatWeight actually exposed at runtime?)
--   * the CURRENT trough and the factor the ENGINE gives it
--   * the PLANNED trough and the factor the ENGINE gives that
--   * whether the model's own prediction AGREES with the engine
--
-- That last line is the point. Everything else is reporting; this is the model
-- being marked against the thing it claims to describe, on the player's real
-- farm rather than in a harness. A disagreement means the model is wrong for
-- that animal type -- most likely a modded one -- and should be trusted over
-- any amount of offline reasoning.
--
-- Needs game.xml <development><controls>true.
-- ============================================================================
AnimalFeedModel.Console = {}

local function out(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[arFeedPlan] " .. (ok and msg or tostring(fmt)))
end

local function ftName(ft)
    local m = g_fillTypeManager
    if m ~= nil and m.getFillTypeNameByIndex ~= nil then
        local ok, n = pcall(m.getFillTypeNameByIndex, m, ft)
        if ok and n ~= nil then return tostring(n) end
    end
    return "ft" .. tostring(ft)
end

local function mixText(mix)
    local parts = {}
    for ft, litres in pairs(mix) do
        if (litres or 0) > 0 then
            parts[#parts + 1] = string.format("%s %.0f", ftName(ft), litres)
        end
    end
    if #parts == 0 then return "(empty)" end
    table.sort(parts)
    return table.concat(parts, ", ")
end

function AnimalFeedModel.Console.run(fragment)
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then out("no placeableSystem"); return end

    local seen, n = {}, 0
    for _, p in ipairs(ps.placeables) do
        if p.spec_husbandryFood ~= nil then
            local name = "?"
            local okN, nm = pcall(function() return p:getName() end)
            if okN and nm ~= nil then name = tostring(nm) end

            local matches = fragment == nil or fragment == ""
                or string.find(string.lower(name), string.lower(fragment), 1, true) ~= nil
            local ati = AnimalFeedModel.animalTypeIndexOf(p)
            local key = ati or name

            if matches and seen[key] == nil then
                seen[key] = true
                n = n + 1
                local spec = p.spec_husbandryFood
                local model, why = AnimalFeedModel.read(ati, spec.supportedFillTypes)

                out("=================================================================")
                out("%s   (animalTypeIndex=%s)", name, tostring(ati))
                if model == nil then
                    out("  NO MODEL: %s", tostring(why))
                else
                    out("  consumptionType : %s   (%s)", model.consumptionType,
                        model.consumptionTypeSource)
                    out("  eatWeight at runtime: %s", model.hasEatWeight and "YES, using it"
                        or "NO -- falling back to productionWeight, so the DEPLETION split "
                        .. "cannot be applied for this animal")
                    out("  demand          : %.2f L/h (read live, RL-safe)",
                        AnimalFeedModel.demandPerHour(p))
                    for _, g in ipairs(model.groups) do
                        out("    %-20s production=%.3f eat=%.3f rep=%s",
                            g.title, g.production, g.eat,
                            g.rep ~= nil and ftName(g.rep) or "NONE SUPPORTED HERE")
                    end

                    local capacity = spec.capacity or 0
                    local pool = capacity > 0 and capacity or 10000

                    -- THE BARN'S REAL DEMAND, not a synthetic one. The first version
                    -- used min(100, capacity/10), which tested a horse barn at 100 L/h
                    -- against its real 27 -- roughly four times its appetite. That made
                    -- a perfectly adequate two-hour buffer read as starved (0.5417 when
                    -- the truth was ~0.99) and sent us chasing a fault that did not
                    -- exist. Only fall back when the barn has no animals to feed.
                    local demand = AnimalFeedModel.demandPerHour(p)
                    local realDemand = demand > 0
                    if not realDemand then demand = 100 end

                    local nowMix, nowTotal = AnimalFeedModel.troughOf(p)
                    local nowF = select(1, AnimalFeedModel.measureFactor(p, ati, nowMix, demand))
                    out("  CURRENT  %s", mixText(nowMix))
                    out("           held %.0f L -> engine factor %s   (at %.2f L/h%s)",
                        nowTotal, nowF ~= nil and string.format("%.4f", nowF) or "?",
                        demand, realDemand and "" or ", SYNTHETIC: this barn has no animals")

                    -- CHECK THE MODEL AGAINST THE TROUGH THAT ACTUALLY EXISTS, not only
                    -- against the plan. The plan is always fully stocked, so it can only
                    -- ever exercise the easy case -- and the model was wrong about
                    -- partially-stocked troughs by 44 points while cheerfully printing
                    -- "MODEL AGREES" above the row that disproved it.
                    if nowF ~= nil and nowTotal > 0 then
                        local predNow = AnimalFeedModel.factorOf(model, nowMix, demand)
                        if math.abs(predNow - nowF) <= 0.02 then
                            out("           model agrees on the CURRENT trough (predicted %.4f)", predNow)
                        else
                            out("           *** model DISAGREES on the CURRENT trough: predicted %.4f, "
                                .. "engine %.4f ***", predNow, nowF)
                        end
                    end

                    -- THE COUNTERFACTUAL. Comparing the plan against whatever
                    -- happens to be in the trough is worthless when the trough
                    -- is empty -- it reports a 100% gain that only means "feed
                    -- your animals". The comparison that matters is against
                    -- what Distribution Redux does TODAY: everything into the
                    -- single highest production weight. Measured through the
                    -- engine, same as the plan, so it holds whatever the state
                    -- of the farm.
                    local drMix = {}
                    for _, g in ipairs(model.groups) do          -- sorted production DESC
                        if g.rep ~= nil then drMix[g.rep] = pool; break end
                    end
                    local drF = select(1, AnimalFeedModel.measureFactor(p, ati, drMix, demand))
                    out("  DR TODAY %s   (best-first)", mixText(drMix))
                    out("           over %.0f L -> engine factor %s", pool,
                        drF ~= nil and string.format("%.4f", drF) or "?")

                    -- The plan as the API actually receives it: one entry per group,
                    -- listing every member the barn accepts. Shown that way too, since
                    -- "MAIZE or SORGHUM" is the thing that fixes a stranded group and
                    -- printing only the first member would hide the whole point.
                    local allowed = {}
                    for ft in pairs(spec.supportedFillTypes or {}) do allowed[#allowed + 1] = ft end
                    local entries = AnimalFeedModel.planWithin(model, pool, allowed)

                    for _, e in ipairs(entries) do
                        local names = {}
                        for _, ft in ipairs(e.fillTypes) do names[#names + 1] = ftName(ft) end
                        out("  PLANNED  %8.0f L of  %s", e.litres, table.concat(names, " or "))
                    end
                    if #entries == 0 then out("  PLANNED  (nothing -- planner would decline)") end

                    local planMix = AnimalFeedModel.entriesToMix(entries)
                    local planF, _, err = AnimalFeedModel.measureFactor(p, ati, planMix, demand)
                    out("           over %.0f L -> engine factor %s", pool,
                        planF ~= nil and string.format("%.4f", planF) or ("ERROR " .. tostring(err)))

                    -- THE CHECK: does the model agree with the engine? The plan stocks
                    -- every group past its need, so this is the fully-stocked question
                    -- and takes no demand argument. The partially-stocked case is
                    -- checked separately, on the CURRENT trough above.
                    local predicted = AnimalFeedModel.factorOf(model, planMix)
                    if planF ~= nil then
                        local delta = math.abs(predicted - planF)
                        if delta <= 0.01 then
                            out("  MODEL AGREES with the engine (predicted %.4f)", predicted)
                        else
                            out("  *** MODEL DISAGREES: predicted %.4f, engine says %.4f ***",
                                predicted, planF)
                            out("  *** trust the engine. The model is wrong for this animal type. ***")
                        end
                        -- The verdict is model vs DR TODAY. Never model vs the
                        -- current trough: an empty barn makes any plan look like
                        -- a 100% win, which is an artefact of the barn being
                        -- empty and says nothing about the model.
                        if drF ~= nil then
                            if planF > drF + 0.005 then
                                out("  VERDICT  model beats DR today: %.4f vs %.4f  (+%.1f%% production)",
                                    planF, drF, (planF / math.max(drF, 0.0001) - 1) * 100)
                            elseif planF < drF - 0.005 then
                                out("  VERDICT  model is WORSE than DR today: %.4f vs %.4f "
                                    .. "-- do NOT wire this up", planF, drF)
                            else
                                out("  VERDICT  no change (%.4f) -- DR is already correct for this animal",
                                    planF)
                            end
                        end
                        if nowTotal <= 0 then
                            out("  (the trough is EMPTY, so the CURRENT row is not a comparison)")
                        end
                    end
                end
            end
        end
    end
    out("=================================================================")
    out("%d animal type(s) reported.", n)
end

function AnimalFeedModel.Console.register()
    if addConsoleCommand == nil then return false end
    if AnimalFeedModel.Console._registered then return true end
    addConsoleCommand("arFeedPlan", "Compare the current trough with the Animal Redux feed model",
        "consoleCommand", AnimalFeedModel.Console)
    AnimalFeedModel.Console._registered = true
    return true
end

function AnimalFeedModel.Console:consoleCommand(fragment)
    local ok, err = pcall(AnimalFeedModel.Console.run, fragment)
    if not ok then return "arFeedPlan failed: " .. tostring(err) end
    return "arFeedPlan done -- see log.txt"
end
