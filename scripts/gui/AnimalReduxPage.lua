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
            -- averaged per CLUSTER, which is how the base game's info box does it
            local sum = 0
            for _, c in ipairs(clusters) do sum = sum + (c.health or 0) end
            health = sum / #clusters
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
-- FRAME
-- ---------------------------------------------------------------------------
function AnimalReduxPage:onGuiSetupFinished()
    AnimalReduxPage:superClass().onGuiSetupFinished(self)
    for _, id in ipairs({ "barnList", "groupList", "conditionList" }) do
        local list = self[id]
        if list ~= nil then
            list:setDataSource(self)
            list:setDelegate(self)
        end
    end
end

function AnimalReduxPage:onFrameOpen()
    AnimalReduxPage:superClass().onFrameOpen(self)
    -- DR's base page re-populates these on its own paced tick, so the figures
    -- stay live without this page running a timer of its own.
    self._realtimeLists = { "barnList", "groupList", "conditionList" }
    self:rebuild()
    if self.barnList ~= nil then self.barnList:reloadData() end
    if self.groupList ~= nil then self.groupList:reloadData() end
    if self.conditionList ~= nil then self.conditionList:reloadData() end
    self:updateSummary()
end

-- ---- SmoothList delegate (two lists, told apart by identity) ---------------
function AnimalReduxPage:getNumberOfItemsInSection(list, section)
    if list == self.barnList then return #(self.barns or {}) end
    if list == self.conditionList then return #(self.conds or {}) end
    return #(self.rows or {})
end

function AnimalReduxPage:populateCellForItemInSection(list, section, index, cell)
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
    local ok = SD.API.addMenuPage(menu, page, nil, "gui.icon_ingameMenu_animals",
                                  l10n("ar_tab_animals", "Animal Redux"),
                                  function() return true end,
                                  { SD.API.menuBackButton(menu) })
    if not ok then return false, "addMenuPage refused" end

    AnimalReduxPage._page = page
    return true
end
