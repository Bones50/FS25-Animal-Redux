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

    local ctype, ctypeSource = readConsumptionType(food, groups)
    return {
        animalTypeIndex = animalTypeIndex,
        consumptionType = ctype,
        consumptionTypeSource = ctypeSource,
        groups = groups,
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

---The production factor a given trough would earn. Mirrors the measured rule.
-- Used for REPORTING and for offline reasoning; the authoritative answer always
-- comes from the engine (see measureFactor).
function AnimalFeedModel.factorOf(model, trough)
    local total = 0
    for _, litres in pairs(trough) do total = total + (litres or 0) end
    if total <= 0 then return 0 end

    if model.consumptionType == "SERIAL" then
        local best = 0
        for _, g in ipairs(model.groups) do
            if AnimalFeedModel.groupPresent(g, trough) and g.production > best then
                best = g.production
            end
        end
        return best
    end

    local sum = 0
    for _, g in ipairs(model.groups) do
        if AnimalFeedModel.groupPresent(g, trough) then sum = sum + g.production end
    end
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

---Current trough contents as fillType -> litres, plus the total.
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
                    local demand = math.max(1, math.min(100, pool / 10))

                    local nowMix, nowTotal = AnimalFeedModel.troughOf(p)
                    local nowF = select(1, AnimalFeedModel.measureFactor(p, ati, nowMix, demand))
                    out("  CURRENT  %s", mixText(nowMix))
                    out("           held %.0f L -> engine factor %s", nowTotal,
                        nowF ~= nil and string.format("%.4f", nowF) or "?")

                    local plan = AnimalFeedModel.plannedFill(model, pool)
                    local planF, _, err = AnimalFeedModel.measureFactor(p, ati, plan, demand)
                    out("  PLANNED  %s", mixText(plan))
                    out("           over %.0f L -> engine factor %s", pool,
                        planF ~= nil and string.format("%.4f", planF) or ("ERROR " .. tostring(err)))

                    -- THE CHECK: does the model agree with the engine?
                    local predicted = AnimalFeedModel.factorOf(model, plan)
                    if planF ~= nil then
                        local delta = math.abs(predicted - planF)
                        if delta <= 0.01 then
                            out("  MODEL AGREES with the engine (predicted %.4f)", predicted)
                        else
                            out("  *** MODEL DISAGREES: predicted %.4f, engine says %.4f ***",
                                predicted, planF)
                            out("  *** trust the engine. The model is wrong for this animal type. ***")
                        end
                        if nowF ~= nil and planF > nowF + 0.01 then
                            out("  would GAIN %.1f%% production here", (planF - nowF) * 100)
                        elseif nowF ~= nil and planF < nowF - 0.01 then
                            out("  would LOSE %.1f%% -- investigate before wiring this up",
                                (nowF - planF) * 100)
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
