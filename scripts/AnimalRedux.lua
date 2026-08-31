-- ============================================================================
-- AnimalRedux.lua  (Animal Redux)
--
-- Bootstrap and the single point where this mod reaches Distribution Redux.
--
-- HOW CROSS-MOD ACCESS WORKS, because it is not obvious and it is easy to get
-- wrong in a way that only fails on someone else's machine:
--
--   Every mod's Lua environment is published as a table in the SHARED global
--   environment, keyed by the mod's ZIP / FOLDER NAME. So Distribution Redux's
--   own globals are reachable from here as:
--
--       FS25_Distribution_Redux.SmartDistribution
--
--   This is the same mechanism Courseplay uses to reach AutoDrive
--   (Courseplay.lua: "self.autoDrive = FS25_AutoDrive and FS25_AutoDrive.AutoDrive").
--
-- TWO RULES FOLLOW FROM THAT, and both are load-bearing:
--
--   1. RESOLVE LATE, NEVER AT FILE SCOPE. Mod load order is not guaranteed, so
--      at chunk load DR's table may not exist yet. Courseplay resolves in
--      loadMap for exactly this reason; we resolve on
--      Mission00.loadMission00Finished, which is also where DR installs itself.
--
--   2. THE KEY IS THE FILE NAME, NOT THE MOD. If a player renames the DR zip,
--      the global moves with it. The direct lookup is tried first (the normal
--      case, one table read) and a scan of the active mods is the fallback.
--
-- This mod is a HARD DEPENDENCY on Distribution Redux: with DR absent it logs
-- once and disables itself rather than erroring per-frame.
-- ============================================================================

AnimalRedux = {}

AnimalRedux.MOD_NAME = g_currentModName or "FS25_Animal_Redux"
AnimalRedux.MOD_DIR  = g_currentModDirectory or ""
AnimalRedux.VERSION  = "0.0.0.1"

-- The mod we depend on, and the lowest API version we can work against. DR does
-- not publish an API yet, so DR_MIN_API is recorded and reported but not yet
-- enforced -- see AnimalRedux.checkApiVersion.
AnimalRedux.DR_MOD_NAME = "FS25_Distribution_Redux"
AnimalRedux.DR_MIN_API  = 1

AnimalRedux.debug = false

-- ---------------------------------------------------------------------------
-- LOCALISATION
--
-- Declared HERE, at the top, because other files call it during GUI setup and a
-- reference below its definition resolves to a nil global -- which `luac -p`
-- does NOT catch (it parses fine and throws only when reached, mid-populate,
-- showing as an empty page). Same trap DR hit twice (CLAUDE.md 5.44 / 5.57).
--
-- THE NAMESPACE ARGUMENT IS NOT OPTIONAL. Lua has no customEnvironment of its
-- own, so `g_i18n:getText(key)` without MOD_NAME misses into the BASE GAME's
-- table and silently falls back for ever -- which looks exactly like "l10n is
-- not working" with nothing in the log. XML is different: `$l10n_key` in
-- gui/*.xml resolves against this mod automatically, because the engine sets
-- customEnvironment from the file's own path.
--
-- EVERYTHING DEGRADES TO THE SHIPPED ENGLISH. A missing key, a partial
-- translation, an unparseable language file or an l10n system not yet up all
-- yield `fallback` -- never a raw key on screen. That is what makes accepting
-- partial community translations safe.
--
-- CONVENTIONS (see translations/translation_en.xml for the full list):
--   * every key is prefixed `ar_`
--   * NEVER translate an internal enum, a table key, or anything compared
--     against a literal. Translate only what is DISPLAYED. DR shipped a bug of
--     exactly this shape (role tags used as sort keys, CLAUDE.md 6.14).
--   * NEVER translate log output. A player pasting log.txt into a bug report
--     needs it in English, and so do we.
--   * build sentences with FORMAT STRINGS, never concatenation -- word order
--     differs by language.
--   * separate whole-sentence singular and plural keys; do not manufacture a
--     singular by trimming an "s".
function AnimalRedux.l10n(key, fallback)
    if key == nil then return fallback end
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n.getText ~= nil then
        local ok, has = pcall(g_i18n.hasText, g_i18n, key, AnimalRedux.MOD_NAME)
        if ok and has then
            local ok2, text = pcall(g_i18n.getText, g_i18n, key, AnimalRedux.MOD_NAME)
            -- "" is a real miss, not a translation choosing to say nothing.
            if ok2 and text ~= nil and text ~= "" then return text end
        end
    end
    return fallback
end

-- Resolved on mission load. nil until then, and nil for ever if DR is absent.
AnimalRedux.DR = nil            -- DR's SmartDistribution table
AnimalRedux.enabled = false

-- ---------------------------------------------------------------------------
function AnimalRedux.log(fmt, ...)
    if not AnimalRedux.debug then return end
    local ok, msg = pcall(string.format, fmt, ...)
    print("[AnimalRedux] " .. (ok and msg or tostring(fmt)))
end

-- Unconditional: a player cannot be talked through enabling a debug flag, so
-- anything that stops the mod working has to say so in a default log.
function AnimalRedux.warn(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[AnimalRedux] " .. (ok and msg or tostring(fmt)))
end

-- ---------------------------------------------------------------------------
-- The true global table. Referencing a mod's global by name directly (as
-- Courseplay does) works, but a lookup BY NAME needs the table itself.
local function globalEnv()
    local ok, env = pcall(getfenv, 0)
    if ok and type(env) == "table" then return env end
    return nil
end

-- Does this table look like Distribution Redux's environment?
local function looksLikeDR(env)
    return type(env) == "table"
       and type(env.SmartDistribution) == "table"
end

---Find DR's SmartDistribution table, or nil.
-- Direct lookup first (the normal case). If the player renamed the zip, fall
-- back to scanning the active mods for one whose environment carries
-- SmartDistribution -- the same list AutoDrive reads for its own name check.
function AnimalRedux.resolveDistributionRedux()
    local G = globalEnv()
    if G == nil then return nil, "could not reach the global environment" end

    local direct = G[AnimalRedux.DR_MOD_NAME]
    if looksLikeDR(direct) then
        return direct.SmartDistribution, AnimalRedux.DR_MOD_NAME, direct
    end

    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        local okMods, mods = pcall(g_modManager.getActiveMods, g_modManager)
        if okMods and type(mods) == "table" then
            for _, mod in pairs(mods) do
                local name = type(mod) == "table" and mod.modName or nil
                if type(name) == "string" and name ~= AnimalRedux.MOD_NAME then
                    local env = G[name]
                    if looksLikeDR(env) then
                        return env.SmartDistribution, name, env
                    end
                end
            end
        end
    end

    return nil, "not found"
end

---Report DR's API version. DR does not publish one yet; treat that as version 0
-- and let the caller decide, rather than refusing to load against it.
function AnimalRedux.checkApiVersion(SD)
    local api = SD ~= nil and SD.API or nil
    local version = (type(api) == "table" and tonumber(api.VERSION)) or 0
    return version, version >= AnimalRedux.DR_MIN_API
end

-- ---------------------------------------------------------------------------
---The feed planner Distribution Redux calls, once per husbandry per hourly pass.
--
-- Contract (DR API v1): return { [fillTypeIndex] = litres } to take over this
-- building's food pool for this pass, or NIL to decline and leave DR's own
-- best-quality-first logic in place.
--
-- IT MUST BE CHEAP AND IT MUST NOT THROW. DR pcalls it and strikes out a planner
-- that throws three times, which would silently hand every husbandry on the farm
-- back to DR for the rest of the session -- so anything unexpected DECLINES
-- rather than errors.
--
-- DECLINING IS THE SAFE ANSWER and is used wherever the model cannot speak with
-- authority: no food data, an animal type we could not read, or no group with a
-- product DR is willing to deliver. DR's own behaviour is correct for SERIAL
-- animals anyway, so a decline is never a regression.
function AnimalRedux.feedPlanner(placeable, allowedFillTypes, poolNeed)
    if AnimalFeedModel == nil or placeable == nil then return nil end
    local spec = placeable.spec_husbandryFood
    if spec == nil then return nil end

    local ati = AnimalFeedModel.animalTypeIndexOf(placeable)
    if ati == nil then return nil end

    -- Read LIVE every pass, never cached: Animalic (or a map) can replace the
    -- whole food definition, and caching would pin us to whatever was loaded
    -- first. The read is a couple of table walks over a handful of groups.
    local model = AnimalFeedModel.read(ati, spec.supportedFillTypes)
    if model == nil then return nil end

    local plan = AnimalFeedModel.planWithin(model, poolNeed, allowedFillTypes)
    if next(plan) == nil then return nil end
    return plan
end

-- ---------------------------------------------------------------------------
---The husbandry panel Distribution Redux draws between the INCOMING and OUTGOING
-- tables on its Animal Husbandry tab (DR API v4).
--
-- Contract: return { herd = {...}, value = {...}, feed = {...} } for this barn, or
-- NIL to leave the strip empty. DR validates every field and draws; this decides
-- nothing about layout and supplies no colours -- deliberately, because a provider
-- that could place elements could break DR's page for everyone.
--
-- IT MUST NOT THROW. DR pcalls it and strikes the provider out after three throws,
-- which would blank the panel for the rest of the session, so every read here is
-- guarded and anything unexpected simply omits that field.
--
-- IT IS A SUMMARY, NOT THE TAB. Per-animal detail (ages, next birth, per-cluster
-- value), the auto-sell rules and the full condition list stay on the Animals tab,
-- which is where a player goes to ACT. This is what they need at a glance while
-- looking at what the barn is being fed.
-- ---------------------------------------------------------------------------
-- THE TWO PANEL ADVICE LINES.
--
-- Requested 2026-08-31: one under the feed graphic ("Food factor at 100%, no action
-- required" / "Provide root crops to raise productivity") and one beside ANIMALS
-- x / x ("No action" / "Sell 4 to make room for new births").
--
-- THEY ARE SENT AS TEXT, not as a code, and that is the one place this provider
-- departs from the code-and-data rule the rest of the mod follows. The reason is
-- ownership: DR draws the panel but the advice is entirely OUR domain -- which food
-- groups an animal type has, what a full pen destroys -- and DR has no vocabulary
-- for either. `feed.activeTitle` set that precedent in v4: the provider names the
-- tier, DR prints it. What DR keeps is the LAYOUT and the palette, which is the
-- split that matters.
--
-- The TONE is a word, not a colour: DR owns the palette and maps it (5.81).

---Up to three product names for a group, so the advice can say WHAT to provide.
-- Three because the line is 480px at 11px and the group title and verb come first;
-- a pig's root-crop group alone lists five.
function AnimalRedux.groupProductNames(g, limit)
    local names, seen = {}, {}
    local m = g_fillTypeManager
    for _, ft in ipairs((g ~= nil and g.fts) or {}) do
        if #names >= (limit or 3) then break end
        local t = nil
        if m ~= nil and m.getFillTypeTitleByIndex ~= nil then
            local ok, v = pcall(m.getFillTypeTitleByIndex, m, ft)
            if ok and type(v) == "string" and v ~= "" then t = v end
        end
        if t ~= nil and not seen[t] then seen[t] = true; names[#names + 1] = t end
    end
    return names
end

---WHAT TO FEED THIS BARN NEXT.
--
-- SERIAL and PARALLEL need different advice because they are different mechanics
-- (3.5, measured). A COW's groups are quality TIERS and alternatives -- only the
-- best one PRESENT counts -- so the advice is "move up a tier". A PIG's are
-- PARALLEL and each contributes `production x met`, so the advice is "the group
-- you are missing most".
--
-- `groups` are the panel's own group records plus `fts`; `serial` and `factor` as
-- the panel computed them, so this cannot disagree with the bar above it.
---Returns { text, tone } or nil when there is nothing to say.
function AnimalRedux.feedAdvice(groups, serial, factor, grazes)
    if type(groups) ~= "table" or #groups == 0 or type(factor) ~= "number" then return nil end
    local L = AnimalRedux.l10n

    -- MET_TARGET, the same 99% the Overview paints green at: a rounding-level miss
    -- is not a call to action (5.7).
    if factor >= 0.99 then
        return { text = L("ar_adv_feed_ok", "Food factor 100% - no action needed"), tone = "good" }
    end

    local want = nil
    if serial then
        -- the best tier the barn could be on, and the best it IS on
        local best, active = nil, nil
        for _, g in ipairs(groups) do
            if best == nil or (g.share or 0) > (best.share or 0) then best = g end
            if (g.held or 0) > 0 and (active == nil or (g.share or 0) > (active.share or 0)) then
                active = g
            end
        end
        -- if a BETTER tier exists than the one feeding them, that is the advice;
        -- otherwise the tier they are on is simply short
        if best ~= nil and (active == nil or best ~= active) then want = best
        else want = active end
    else
        -- PARALLEL: the group whose absence costs the most factor. `share x (1 - met)`
        -- is literally the contribution being missed, so this names the biggest one
        -- rather than merely the emptiest.
        local worst, lost = nil, -1
        for _, g in ipairs(groups) do
            local miss = (g.share or 0) * (1 - (g.met or 0))
            if miss > lost + 1e-9 then worst, lost = g, miss end
        end
        if lost > 0 then want = worst end
    end

    if want == nil then
        if grazes then
            return { text = L("ar_adv_feed_grazing", "Grazing - the meadow is feeding them"),
                     tone = "good" }
        end
        return nil
    end

    local names = AnimalRedux.groupProductNames(want)
    local what = want.title or "?"
    if #names > 0 then
        what = string.format("%s (%s)", what, table.concat(names, ", "))
    end
    return { text = string.format(L("ar_adv_feed_provide", "Provide %s to raise productivity"), what),
             tone = "warn" }
end

---WHETHER TO SELL TO MAKE ROOM FOR BIRTHS.
--
-- 11.11 measured what a full pen costs: it destroys `numAnimals` offspring AND the
-- gestation that made them, permanently, every cycle. That is the single most
-- expensive thing a herd can be doing, and nothing else on this panel says it.
--
-- THE PLAN IS THE AUTHORITY, not a second calculation. If it wants a headroom sale
-- it says how many; if it has looked and declined, the pen is losing births and the
-- trade is not worth it, which is a different message and an honest one.
---Returns { text, tone } or nil.
function AnimalRedux.birthAdvice(a, plan)
    if type(a) ~= "table" then return nil end
    local L = AnimalRedux.l10n

    local n = 0
    for _, ln in ipairs((plan ~= nil and plan.lines) or {}) do
        if ln.reason == AnimalSellRules.REASON_HEADROOM then n = n + (ln.count or 0) end
    end
    if n > 0 then
        return { text = string.format(L("ar_adv_birth_sell", "Sell %d to free slots for births"), n),
                 tone = "warn" }
    end

    local lost = a.lost or 0
    if lost > 0 then
        -- the plan looked and declined: the slots are worth less than the animals
        -- that would have to go, so the honest advice is to build, not to sell
        return { text = string.format(L("ar_adv_birth_lost", "%d births lost - pen is full"), lost),
                 tone = "bad" }
    end

    local free = a.free or 0
    if free > 0 and (a.breeders or 0) > 0 then
        return { text = string.format(L("ar_adv_birth_room", "No action - %d slots for births"), free),
                 tone = "good" }
    end
    if (a.breeders or 0) == 0 then
        return { text = L("ar_adv_birth_none", "No action - nothing is breeding"), tone = "good" }
    end
    return { text = L("ar_adv_birth_ok", "No action"), tone = "good" }
end

-- ---------------------------------------------------------------------------
function AnimalRedux.husbandryPanel(placeable)
    if placeable == nil or AnimalFeedModel == nil then return nil end
    if placeable.spec_husbandryFood == nil then return nil end
    local out = {}

    -- ---- herd ---------------------------------------------------------------
    local clusters = nil
    if placeable.getClusters ~= nil then
        local ok, c = pcall(placeable.getClusters, placeable)
        if ok and type(c) == "table" then clusters = c end
    end
    local herd = {}
    local ati0 = AnimalFeedModel.animalTypeIndexOf(placeable)
    if placeable.getNumOfAnimals ~= nil then
        local ok, v = pcall(placeable.getNumOfAnimals, placeable); if ok then herd.count = v end
    end
    if placeable.getMaxNumOfAnimals ~= nil then
        local ok, v = pcall(placeable.getMaxNumOfAnimals, placeable); if ok then herd.max = v end
    end
    if clusters ~= nil and AnimalHerdData ~= nil and AnimalHerdData.herdHealthFactor ~= nil then
        -- animal-WEIGHTED mean, already 0..1; a cluster of 40 must not count the
        -- same as a cluster of 1
        --
        -- Asked of AnimalHerdData DIRECTLY. It used to go through a delegate on
        -- AnimalReduxPage that did nothing but forward here, which is what let the
        -- old page be retired without moving any logic -- but a GUI page was never
        -- the right thing for a data module to ask.
        local ok, h = pcall(AnimalHerdData.herdHealthFactor, clusters)
        if ok then herd.health = h end
    end
    -- PRODUCTIVITY, the base game's own headline: globalProductionFactor x
    -- productionFactor, exactly as PlaceableHusbandryAnimals:getConditionInfos
    -- computes it. NOT the food factor -- food is one input to it, so a barn can be
    -- perfectly fed and still sit at 15%, which is precisely the case this bar
    -- exists to show.
    if placeable.getGlobalProductionFactor ~= nil and placeable.getProductionFactor ~= nil then
        local okG, gf = pcall(placeable.getGlobalProductionFactor, placeable)
        local okP, pf = pcall(placeable.getProductionFactor, placeable)
        if okG and okP and type(gf) == "number" and type(pf) == "number" then
            herd.productivity = gf * pf
        end
    end
    -- the base game HIDES this for horses and pigs (they do not produce continuously),
    -- so it is flagged rather than presented as a confident zero
    if AnimalType ~= nil and ati0 ~= nil then
        herd.prodApplies = (ati0 ~= AnimalType.HORSE and ati0 ~= AnimalType.PIG)
    end
    out.herd = herd

    -- ---- value --------------------------------------------------------------
    -- CURRENT is what the herd would fetch right now; POTENTIAL is what the same
    -- animals would fetch at PEAK AGE and full health. Both terms are exact rather
    -- than modelled: sellPrice = curve(ageMonths) x (0.40 + 0.60 x health), measured
    -- to the cent on three animals at two health levels, and AnimalSellRules.priceCurve
    -- already samples each subtype's curve once and caches its peak.
    --
    -- getSellPrice is PER ANIMAL, so both terms multiply by the cluster count.
    if clusters ~= nil and #clusters > 0 then
        local cur, pot, pastPeak, sawCurve = 0, 0, false, false
        for _, cl in pairs(clusters) do
            local n = cl.numAnimals or 0
            if n > 0 then
                local each = nil
                if cl.getSellPrice ~= nil then
                    local ok, v = pcall(cl.getSellPrice, cl)
                    if ok and type(v) == "number" then each = v end
                end
                if each ~= nil then cur = cur + each * n end

                local curve = nil
                if AnimalSellRules ~= nil and AnimalSellRules.priceCurve ~= nil then
                    local ok, c = pcall(AnimalSellRules.priceCurve, cl)
                    if ok then curve = c end
                end
                if curve ~= nil and type(curve.peakPrice) == "number" then
                    pot = pot + curve.peakPrice * n
                    sawCurve = true
                    -- ONLY COWS DECLINE (measured), and the curve is asked rather than
                    -- the species so a modded animal answers for itself. Past peak the
                    -- value falls every month and holding gains nothing, which is a
                    -- different message from "feed them better".
                    if curve.declines and curve.peakAge ~= nil and (cl.age or 0) > curve.peakAge then
                        pastPeak = true
                    end
                elseif each ~= nil then
                    -- no curve for this subtype: fall back to the HEALTH ceiling alone,
                    -- so the bar still means something rather than the whole barn
                    -- dropping out because one cluster could not be sampled
                    local hf = 0.40 + 0.60 * ((cl.health or 0) / 100)
                    if hf > 0 then pot = pot + (each / hf) * n end
                end
            end
        end
        if cur > 0 or pot > 0 then
            out.value = { current = cur, potential = pot, pastPeak = pastPeak }
        end
        -- sawCurve is deliberately unused beyond documenting intent: a mixed barn where
        -- some subtypes sampled and others did not still reports a coherent total.
    end

    -- ---- feed ---------------------------------------------------------------
    -- HOISTED so the profit block below can reach them: the ration is the barn's
    -- largest running cost and it is resolved exactly once, here, rather than a
    -- second time from a second read of the trough.
    local feedModel, feedAvail, feedDemand = nil, nil, nil
    local ati = AnimalFeedModel.animalTypeIndexOf(placeable)
    if ati ~= nil then
        local spec = placeable.spec_husbandryFood
        local model = AnimalFeedModel.read(ati, spec.supportedFillTypes)
        if model ~= nil then
            local demand = AnimalFeedModel.demandPerHour(placeable)
            local everyFt = {}
            for _, g in ipairs(model.groups) do
                for _, ft in ipairs(g.fts) do everyFt[#everyFt + 1] = ft end
            end
            local trough = AnimalFeedModel.availableOf(placeable, everyFt)
            feedModel, feedAvail, feedDemand = model, trough, demand

            -- factorOf, NEVER measureFactor. measureFactor is a DESTRUCTIVE probe: it zeroes the
            -- barn's real spec.fillLevels, substitutes a mix, calls animalFoodSystem:consumeFood --
            -- which actually feeds the herd -- and then restores the levels. That is exactly right
            -- for a console probe run on demand, and exactly wrong on a menu populate that runs on
            -- every selection AND on the page's timed refresh: it would drive the engine's own
            -- consumption path several times a second for as long as the tab is open.
            --
            -- factorOf is pure arithmetic over the same trough and needs no such trick, and it is
            -- not a lesser answer: its best-first weighted average was measured against the engine
            -- with arFeedPartial and reproduces it (3.6), including the partial-forage case a
            -- max-of-tiers model gets wrong.
            local factor = nil
            if demand > 0 then
                local ok, f = pcall(AnimalFeedModel.factorOf, model, trough, demand)
                if ok and type(f) == "number" then factor = f end
            end

            local serial = model.consumptionType == "SERIAL"
            local eatSum = 0
            for _, g in ipairs(model.groups) do eatSum = eatSum + g.eat end

            local groups, active, activeShare = {}, nil, -1
            for i, g in ipairs(model.groups) do
                local held = 0
                for _, ft in ipairs(g.fts) do held = held + (trough[ft] or 0) end
                local need = 0
                if demand > 0 then
                    if serial then need = demand
                    elseif eatSum > 0 then need = demand * g.eat / eatSum end
                end
                local met = 1
                if need > 0 then met = math.min(1, held / need) end
                groups[#groups + 1] = {
                    -- `fts` is for feedAdvice, which needs the PRODUCTS to name them.
                    -- DR's sanitiser drops it, so the contract is unchanged.
                    title = g.title, share = g.production, met = met,
                    held = held, need = need, colourIndex = i, fts = g.fts,
                }
                -- SERIAL: the ACTIVE tier is the best one actually present, which is
                -- the single thing that sets the factor. Named on the panel so the
                -- bar says which tier you are on rather than only how high it is.
                if serial and held > 0 and g.production > activeShare then
                    active, activeShare = g.title, g.production
                end
            end

            out.feed = {
                factor = factor, serial = serial, activeTitle = active,
                -- WHAT TO FEED NEXT, from the same groups the bar above it draws,
                -- so the sentence and the bar cannot disagree about which tier is short
                advice = AnimalRedux.feedAdvice(groups, serial, factor,
                                                placeable.spec_husbandryMeadow ~= nil),
                -- a meadow feeds outside the trough, so every group can read 0 L while
                -- the factor is well above zero; DR says so on the panel rather than
                -- leaving the contradiction on screen
                grazes = placeable.spec_husbandryMeadow ~= nil,
                groups = groups,
            }
        end
    end

    -- ---- profit --------------------------------------------------------------
    -- WHAT THE BARN MAKES, per month:
    --     increase in animal value + outputs sold - inputs bought
    --
    -- EVERY TERM COMES FROM SOMEWHERE THAT ALREADY OWNS IT, and none is
    -- recomputed here. AnimalSellRules.assess supplies the per-cluster picture
    -- (output value, straw and water, the price-curve drift, the breeding gates
    -- and what a newborn is worth); AnimalEconomics.summarise weights it by
    -- HEADCOUNT; AnimalEconomics.feedCostPerHour prices the ration off the same
    -- tier rule this panel names its active group by. The composition is
    -- AnimalEconomics.barnProfit and nothing about it lives in this file.
    --
    -- WHY assess RATHER THAN THE VALUE LOOP ABOVE: births need the free-slot
    -- allocation that decides which calves a full pen destroys, and that rule
    -- belongs to the plan. Rebuilding it here to save one walk of the clusters is
    -- how the panel and the Animals tab come to disagree about the same barn.
    if AnimalSellRules ~= nil and AnimalSellRules.plan ~= nil
       and AnimalEconomics ~= nil and AnimalEconomics.barnProfit ~= nil then
        -- PLAN, NOT assess -- and it costs no more, because plan calls assess itself
        -- and hands it back. It is also what makes the birth advice below agree with
        -- the Animals tab instead of being a second opinion about one pen.
        local okA, pl = pcall(AnimalSellRules.plan, placeable)
        local a = (okA and type(pl) == "table") and pl.assess or nil
        if type(a) == "table" and type(a.clusters) == "table" then
            if out.herd ~= nil then out.herd.advice = AnimalRedux.birthAdvice(a, pl) end
            local okS, sum = pcall(AnimalEconomics.summarise, a.clusters)
            if okS and type(sum) == "table" then
                -- NIL, NOT ZERO, when the ration cannot be priced: a barn whose
                -- feed has no market value does not have a free one.
                local feedPerMonth = nil
                if feedModel ~= nil and AnimalEconomics.feedCostPerHour ~= nil then
                    local okF, fc = pcall(AnimalEconomics.feedCostPerHour,
                                          placeable, feedModel, feedAvail, feedDemand)
                    if okF and type(fc) == "table" and (fc.unpriced or 0) == 0 then
                        local days = AnimalEconomics.daysPerMonth()
                        feedPerMonth = fc.perHour * 24 * days
                    end
                end
                -- THE BEDDING AND WATER BILL IS THE BUILDING'S, NOT THE CLUSTERS'.
                -- It used to be rolled up per animal, which charged straw whether or
                -- not the barn held any -- and the inputs table beside this showed
                -- the same straw at zero, so one hour read -31 here and -24 there.
                -- Both now come from the same availability-gated function.
                local declPerMonth = nil
                if AnimalEconomics.declaredInputCostPerHour ~= nil then
                    local okD, dc = pcall(AnimalEconomics.declaredInputCostPerHour,
                                          placeable, a.clusters)
                    if okD and type(dc) == "table" and (dc.unpriced or 0) == 0 then
                        declPerMonth = dc.perHour * 24 * AnimalEconomics.daysPerMonth()
                    end
                end
                local okP, pr = pcall(AnimalEconomics.barnProfit, sum, feedPerMonth, declPerMonth)
                if okP and type(pr) == "table" then out.profit = pr end
            end
        end
    end

    if out.herd == nil and out.value == nil and out.feed == nil and out.profit == nil then
        return nil
    end
    return out
end

-- ---------------------------------------------------------------------------
function AnimalRedux.onMissionLoaded()
    local SD, whereOrWhy, env = AnimalRedux.resolveDistributionRedux()

    if SD == nil then
        AnimalRedux.warn("Distribution Redux was not found (%s). Animal Redux requires it and is DISABLED.",
            tostring(whereOrWhy))
        AnimalRedux.enabled = false
        return
    end

    AnimalRedux.DR = SD
    AnimalRedux.DR_ENV = env          -- DR's whole environment; the GUI page needs
                                      -- DistributionMenuPage, which is not on SmartDistribution
    AnimalRedux.enabled = true

    local apiVersion, apiOk = AnimalRedux.checkApiVersion(SD)
    AnimalRedux.warn("v%s linked to Distribution Redux (global '%s', API v%d%s)",
        AnimalRedux.VERSION, tostring(whereOrWhy), apiVersion,
        apiOk and "" or string.format("; this mod wants v%d+", AnimalRedux.DR_MIN_API))

    -- L10N SELF-TEST. There is no UI yet, so nothing else would reveal a broken
    -- translation chain until the first screen is built -- and by then the cause
    -- (file not packed, wrong filenamePrefix, missing namespace argument) is
    -- tangled up with whatever else that screen does. This resolves one known
    -- key and reports the answer, so the chain is proven end to end before it
    -- carries anything. Costs one table lookup at load.
    local probe = AnimalRedux.l10n("ar_l10n_selftest", "FALLBACK")
    if probe == "ok" then
        AnimalRedux.warn("l10n OK (translations/translation_en.xml resolved against '%s')",
            AnimalRedux.MOD_NAME)
    else
        AnimalRedux.warn("l10n NOT RESOLVING (got '%s'): every string will show its English "
            .. "fallback. Check that translations/ is in the deploy allowlist and that "
            .. "modDesc declares <l10n filenamePrefix=\"translations/translation\"/>.",
            tostring(probe))
    end

    -- TEMPORARY dev probe (arFoodProbe). Registration is separate from the link
    -- itself so a probe failure can never stop the mod loading. Console commands
    -- need game.xml <development><controls>true, so this is unreachable in a
    -- normal install; it still announces itself, because a probe nobody knows
    -- about is a probe nobody runs.
    if AnimalFoodProbe ~= nil and AnimalFoodProbe.register ~= nil then
        local okP, registered = pcall(AnimalFoodProbe.register)
        if okP and registered then
            AnimalRedux.warn("dev probes available: arFoodProbe, arFeedPartial, arTradeProbe, arReproProbe, arSellProbe")
        end
    end

    -- THE COMPREHENSIVE TRADE DUMP. Its own registration, not folded into
    -- AnimalFoodProbe, because it exists for one open question (the buy path) and
    -- should be removable the moment that question is closed.
    if AnimalTrade ~= nil and AnimalTrade.installConsole ~= nil then
        local okT, reg = pcall(AnimalTrade.installConsole)
        if okT and reg then AnimalRedux.warn("dev probe available: arTradeDump") end
    end

    -- The feed model's own verifier. Registered separately from the probe so
    -- either can be removed without disturbing the other.
    if AnimalFeedModel ~= nil and AnimalFeedModel.Console ~= nil then
        local okF, registered = pcall(AnimalFeedModel.Console.register)
        if okF and registered then
            AnimalRedux.warn("dev probe available: arFeedPlan [name fragment]")
        end
    end

    -- ---- FEED PLANNING -----------------------------------------------------
    -- Registered only when DR publishes an API we understand. Without it the mod
    -- still loads and the probes still work; DR simply keeps its own feed logic.
    if apiOk and SD.API ~= nil and SD.API.registerFeedPlanner ~= nil then
        local okR = pcall(SD.API.registerFeedPlanner, AnimalRedux.MOD_NAME, AnimalRedux.feedPlanner)
        AnimalRedux.feedPlanningActive = okR and true or false
        if okR then
            AnimalRedux.warn("feed planning ACTIVE (Distribution Redux API v%d)", apiVersion)
        else
            AnimalRedux.warn("feed planner could not be registered; DR keeps its own feed logic")
        end
    else
        AnimalRedux.feedPlanningActive = false
        AnimalRedux.warn("Distribution Redux exposes no feed API (needs v%d+, found v%d) -- "
            .. "feed planning is INACTIVE and DR keeps its own logic",
            AnimalRedux.DR_MIN_API, apiVersion)
    end

    -- ---- THE HUSBANDRY PANEL (DR API v4) ------------------------------------
    -- Registered separately from the feed planner and from the tab: each is an
    -- independent capability, and a DR that is too old for one may still take the
    -- others. Gated on the CALL existing rather than on the version number, so a
    -- DR that adds it in a later build still works without a bump here.
    if SD.API ~= nil and SD.API.registerHusbandryPanel ~= nil then
        local okP = pcall(SD.API.registerHusbandryPanel, AnimalRedux.MOD_NAME,
                          AnimalRedux.husbandryPanel)
        AnimalRedux.panelActive = okP and true or false
        if okP then
            AnimalRedux.warn("husbandry panel ACTIVE, embedded in the Animal Husbandry tab")
        else
            AnimalRedux.warn("husbandry panel could not be registered")
        end
    else
        AnimalRedux.panelActive = false
        AnimalRedux.warn("Distribution Redux has no husbandry panel API (needs v4+, found v%d)",
            apiVersion)
    end

    -- ---- THE TAB -------------------------------------------------------------
    -- Deferred to DR's menu-ready callback rather than added here, because DR
    -- builds its menu LATER in this very same hook: mods load alphabetically, so
    -- Animal Redux appended to loadMission00Finished first and runs first. At
    -- this moment SmartDistribution._menu does not exist yet.
    --
    -- THERE WERE TWO TABS UNTIL 2026-08-31. AnimalReduxPage ran beside this one
    -- deliberately -- "the comparison between them IS the acceptance test, so the
    -- old one has to keep working until it is deliberately removed" -- and it has
    -- now been removed on that basis, coverage checked column by column (20.28).
    if SD.API ~= nil and SD.API.onMenuReady ~= nil then
        SD.API.onMenuReady(AnimalRedux.MOD_NAME, function(menu)
            local ok, why = HerdInspectorPage.install(menu)
            if ok then
                AnimalRedux.warn("Herd Inspector tab added to the Distribution Redux menu")
            else
                AnimalRedux.warn("Herd Inspector tab NOT added: %s", tostring(why))
            end
        end)
    else
        AnimalRedux.warn("Distribution Redux has no menu API (needs v3+); no tab")
    end

    -- Features attach from here. Nothing yet -- this build only proves the link.
end

-- ---------------------------------------------------------------------------
local function install()
    if Mission00 == nil or Mission00.loadMission00Finished == nil then
        AnimalRedux.warn("Mission00.loadMission00Finished not found; cannot install.")
        return
    end
    Mission00.loadMission00Finished = Utils.appendedFunction(
        Mission00.loadMission00Finished,
        function() pcall(AnimalRedux.onMissionLoaded) end)
end

install()
