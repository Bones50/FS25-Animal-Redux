-- ============================================================================
-- AnimalHerdData.lua  (Animal Redux) -- the barn reader
--
-- MOVED OUT OF THE ORIGINAL PAGE, not copied, when a second tab wanted the same
-- picture of a barn -- its food factor, its groups, its herd. Animal Redux had
-- already been bitten once by keeping two copies of a display helper (DR 5.69,
-- which promoted setStorageBar out of a GUI file for exactly this reason, after
-- the duplicated version caused three regressions).
--
-- THE SECOND TAB IS NOW THE ONLY TAB (20.28) and this is still a MODULE rather
-- than a page method. That is what made the retirement a deletion instead of a
-- salvage: the data layer never lived in the page that was removed, so nothing
-- had to be rescued out of it.
--
-- Everything here is READ-ONLY on the game. AnimalFeedModel.measureFactor
-- snapshots and restores fillLevels on every path, so measuring a barn's factor
-- does not feed it.
-- ============================================================================

AnimalHerdData = {}

---Headcount-weighted herd health, 0..1. WEIGHTED, because a barn of 200 healthy
-- animals and 10 starving ones is not "half sick" -- and the breeding gate is
-- per CLUSTER, so an unweighted mean would misreport both.
function AnimalHerdData.herdHealthFactor(clusters)
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

local function l10n(key, fallback)
    if AnimalRedux ~= nil and AnimalRedux.l10n ~= nil then return AnimalRedux.l10n(key, fallback) end
    return fallback
end

local function ftName(ft)
    local m = g_fillTypeManager
    if m ~= nil and m.getFillTypeNameByIndex ~= nil then
        local ok, n = pcall(m.getFillTypeNameByIndex, m, ft)
        if ok and n ~= nil then return tostring(n) end
    end
    return "?"
end

function AnimalHerdData.readBarn(p)
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
                fts = g.fts,      -- the PRODUCTS that satisfy this group
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
            health = AnimalHerdData.herdHealthFactor(clusters)
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
             trough = trough,  -- ft -> litres, so a pane can go per PRODUCT
             -- SERIAL means ONE tier feeds the whole herd (a cow's TMR / Silage /
             -- Hay / Grass are alternatives); PARALLEL means every group
             -- contributes. Which it is decides what is actually being EATEN.
             serial = (model ~= nil and model.consumptionType == "SERIAL"),
             hasAnimals = hasAnimals, held = held, delivered = delivered,
             engine = engine, modelF = modelF, grazes = grazes, groups = groups,
             prod = prod, prodApplies = prodApplies, numAnimals = numAnimals,
             maxAnimals = maxAnimals, health = health, conditions = conditions }
end

-- ---------------------------------------------------------------------------
---Every husbandry THIS FARM manages, read and named. Moved here for the same
-- reason readBarn was: both tabs must list the same buildings, and two copies of
-- an enrolment rule is two chances to disagree about which barns exist.
--
-- Both tests are DR's own, so this shows exactly the set DR manages:
--   isAssetEnrolled  participation, and the Animal Husbandry class toggle
--   _farmCanUse      ownership, including the public-map-storage rule (DR 5.63)
-- Each fails OPEN if DR does not expose it, so a version mismatch shows too much
-- rather than an empty tab.
function AnimalHerdData.enumerate()
    local barns = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return barns end

    local SD = AnimalRedux ~= nil and AnimalRedux.DR or nil
    local myFarm = (SD ~= nil and SD._playerFarmId ~= nil) and SD._playerFarmId() or nil

    -- ONE ROW PER PLACEABLE. Guarding on identity rather than trusting the list:
    -- a building appearing twice would be a counting fault, and showing it twice
    -- is exactly what gets mistaken for the farm really having two of them.
    local seen = {}
    for _, p in ipairs(ps.placeables) do
        if p.spec_husbandryFood ~= nil and seen[p] == nil then
            local enrolled = SD == nil or SD.isAssetEnrolled == nil or SD.isAssetEnrolled(p)
            local usable   = myFarm == nil or SD == nil or SD._farmCanUse == nil
                             or SD._farmCanUse(p, myFarm)
            if enrolled and usable then
                seen[p] = true
                local b = AnimalHerdData.readBarn(p)
                if b ~= nil then barns[#barns + 1] = b end
            end
        end
    end

    -- DUPLICATE NAMES get a " (n)" suffix, DR's convention (5.7), numbered by
    -- uniqueId rather than list position so a building keeps its number as others
    -- are built or demolished around it.
    local byName = {}
    for _, b in ipairs(barns) do
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

    table.sort(barns, function(a, b) return a.name < b.name end)
    return barns
end

-- ---------------------------------------------------------------------------
---The picture the BUY / SELL screen shows for this breed at this age.
--
-- `animalSystem:getVisualByAge(subTypeIndex, age)` is what the base game itself
-- uses to pick an animal's appearance -- PlaceableHusbandryAnimals, Rideable and
-- LivestockTrailer all call it -- and the visual carries a `.store` item. So the
-- icon is AGE-AWARE for free: a calf and a cow are different pictures, which is
-- what makes it worth showing beside a group at all.
--
-- VERIFIED, NOT TRUSTED. Every candidate goes through DR's own
-- `iconFileUsable`, which checks the file exists AND rejects the base game's
-- blank placeholder tile - 5.71 measured four productions declaring
-- `store_empty.png` and rendering as a solid white square. A declared image is
-- not a present one.
---THE PICTURE OUT OF A VISUAL'S `store` TABLE, wherever that visual came from.
--
-- Split out because a visual is reachable two ways: the animal system resolves one
-- from a (subTypeIndex, age) pair, and a DEALER ITEM carries its own. Both end at the
-- same store table, so the key order and the usability check belong in ONE place --
-- otherwise the two lists agree about a picture only by coincidence.
--
-- 5.71 is why each candidate is verified rather than taken: four Montana productions
-- DECLARE the base game's blank placeholder tile and rendered as solid white squares.
function AnimalHerdData.iconFromStore(st)
    if type(st) ~= "table" then return nil end
    local SD = AnimalRedux ~= nil and AnimalRedux.DR or nil
    local usable = (SD ~= nil and SD.iconFileUsable) or function(f) return f ~= nil end
    for _, key in ipairs({ "imageFilename", "imageFilenameSmall", "iconFilename" }) do
        local f = st[key]
        if type(f) == "string" and f ~= "" then
            local okU, good = pcall(usable, f)
            if okU and good then return f end
        end
    end
    return nil
end

function AnimalHerdData.animalIconFile(subTypeIndex, ageMonths)
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil or asys.getVisualByAge == nil or subTypeIndex == nil then return nil end
    local ok, visual = pcall(asys.getVisualByAge, asys, subTypeIndex, ageMonths or 0)
    if not ok or type(visual) ~= "table" then return nil end
    return AnimalHerdData.iconFromStore(visual.store)
end

---The BUILDING picture, through DR's own ordered chain rather than a second copy
-- of it. 5.71: a DECLARED image is not a PRESENT one -- four Montana productions
-- name the base game's blank placeholder tile and rendered as solid white squares
-- -- so the resolver walks customImageFilename -> store image -> production point
-- -> product icon and verifies each with textureFileExists. Reusing it means this
-- list and DR's own building lists can never disagree about a barn's picture.
function AnimalHerdData.barnIconFile(p)
    local SD = AnimalRedux ~= nil and AnimalRedux.DR or nil
    if SD == nil or SD.assetIconFile == nil or p == nil then return nil end
    local ok, f = pcall(SD.assetIconFile, p)
    if ok and type(f) == "string" and f ~= "" then return f end
    return nil
end

---The HUD icon for a fill type, the same field DR reads for its own fill icons.
function AnimalHerdData.fillIconFile(ft)
    local m = g_fillTypeManager
    if m == nil or ft == nil or m.getFillTypeByIndex == nil then return nil end
    local ok, def = pcall(m.getFillTypeByIndex, m, ft)
    if not ok or type(def) ~= "table" then return nil end
    return def.hudOverlayFilename or def.hudOverlayFilenameSmall
end

-- ---------------------------------------------------------------------------
---The subtype record behind a cluster's INDEX.
--
-- `AnimalSellRules.assess` puts `subTypeIndex` on every cluster record and NOT
-- the subtype itself, so anything wanting the output curves has to resolve it.
-- Reading `c.subType` off that record silently yields nil, which is how the
-- production pane came up empty on every barn and L/DAY read a dash on every
-- group -- one cause, two symptoms, and neither of them errors.
function AnimalHerdData.subTypeOf(subTypeIndex)
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if asys == nil or asys.getSubTypeByIndex == nil or subTypeIndex == nil then return nil end
    local ok, st = pcall(asys.getSubTypeByIndex, asys, subTypeIndex)
    if ok and type(st) == "table" then return st end
    return nil
end

---The animal TYPE a barn holds (COW, SHEEP...), which is one level above the
-- subtype a cluster carries. `spec.animalTypeIndex` is set by the base game's own
-- load from `spec.animalType.typeIndex`, so it is the building's declaration
-- rather than anything inferred from what happens to be standing in it -- an
-- empty barn still knows what it is for.
---Returns index, display name -- or nil, nil where the spec does not answer.
function AnimalHerdData.animalTypeOf(p)
    local spec = p ~= nil and p.spec_husbandryAnimals or nil
    local idx = spec ~= nil and spec.animalTypeIndex or nil
    if idx == nil and spec ~= nil and type(spec.animalType) == "table" then
        idx = spec.animalType.typeIndex
    end
    if idx == nil then return nil, nil end

    -- The type's own name where the build exposes one; the barn's declared type
    -- table is tried first because it is already in hand.
    local nm = nil
    if type(spec.animalType) == "table" then
        nm = spec.animalType.name or spec.animalType.typeName
    end
    local asys = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if nm == nil and asys ~= nil and asys.getTypeByIndex ~= nil then
        local ok, t = pcall(asys.getTypeByIndex, asys, idx)
        if ok and type(t) == "table" then nm = t.name or t.typeName end
    end
    return idx, nm ~= nil and tostring(nm) or nil
end

-- ---------------------------------------------------------------------------
---What one animal of this subtype produces per DAY at this age, per output.
-- Reads the same declaration AnimalEconomics does, so the two cannot disagree
-- about a curve: 14.4 measured every output as age-curved, and matched the live
-- `spec.litersPerHour` on 17 rows of 17.
--
-- MILK AND EGGS ARE A CLIFF (nothing, then the full rate); MANURE, SLURRY AND
-- STRAW RAMP FROM BIRTH. So a young group reports a real, honest zero for milk
-- while still making manure -- which is the distinction no current screen draws.
local OUTPUTS = { { key = "milk", cliff = true }, { key = "pallets", cliff = true },
                  { key = "liquidManure" }, { key = "manure" } }

---`allowed` is an AnimalEconomics.producibleOutputKeys set, or nil to keep every
-- declared output. AN ANIMAL'S DECLARATION IS NOT A BUILDING'S CAPABILITY: a cow
-- declares output.liquidManure wherever it stands, but a barn with no
-- <liquidManure> block has no slurry spec and never makes a drop of it.
function AnimalHerdData.outputRates(subType, ageMonths, allowed)
    local out = {}
    if type(subType) ~= "table" or AnimalEconomics == nil then return out end
    local o = subType.output or {}
    for _, spec in ipairs(OUTPUTS) do
        local decl = o[spec.key]
        if allowed ~= nil and allowed[spec.key] ~= true then decl = nil end
        if decl ~= nil then
            local perDay = AnimalEconomics.perAnimalPerDay(decl, ageMonths or 0)
            if perDay ~= nil then
                -- MILK AND PALLETS name their fill type; MANURE, SLURRY AND STRAW
                -- do not -- their declaration IS the curve (15.6's two shapes), so
                -- curveOf returns nil for the type and the row rendered as "?".
                -- fillTypeForKey exists for exactly this and was simply not used.
                local _, ft = AnimalEconomics.curveOf(decl)
                if ft == nil and AnimalEconomics.fillTypeForKey ~= nil then
                    ft = AnimalEconomics.fillTypeForKey(spec.key)
                end
                out[#out + 1] = { key = spec.key, perDay = perDay, fillType = ft,
                                  cliff = spec.cliff == true }
            end
        end
    end
    return out
end

-- `AnimalHerdData.inputRates` LIVED HERE AND IS GONE. It listed everything in
-- subType.input, food included, and only avoided double-counting the ration
-- because `food` resolves no fill type and fell through a guard meant for
-- something else. AnimalEconomics.declaredInputRates replaces it and excludes food
-- BY NAME, which is the difference between an accident and a rule -- and it is the
-- same rate source the costing uses, so a table and a total cannot disagree.

---Litres per animal per day of ONE output key, or nil when it is not declared.
function AnimalHerdData.ratePerAnimal(subType, ageMonths, key, allowed)
    for _, r in ipairs(AnimalHerdData.outputRates(subType, ageMonths, allowed)) do
        if r.key == key then return r.perDay, r.fillType end
    end
    return nil, nil
end
