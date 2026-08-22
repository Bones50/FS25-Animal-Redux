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

    local trough, held = AnimalFeedModel.troughOf(p)
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
            local need = (hasAnimals and eatSum > 0) and (demand * g.eat / eatSum) or 0
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

    local SD = AnimalRedux ~= nil and AnimalRedux.DR or nil
    local uid = (SD ~= nil and SD.assetUid ~= nil) and SD.assetUid(p) or tostring(p)

    return { placeable = p, uid = uid, name = name, model = model, demand = demand,
             hasAnimals = hasAnimals, held = held, engine = engine, modelF = modelF,
             groups = groups }
end

function AnimalReduxPage:rebuild()
    self.barns = {}
    local ps = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    if ps == nil then return end
    local seen = {}
    for _, p in ipairs(ps.placeables) do
        -- ONE ROW PER PLACEABLE. Guarding on identity rather than trusting the
        -- list: a building appearing twice here would be a counting fault, and
        -- silently showing it twice is exactly the sort of thing that gets
        -- mistaken for the farm really having two of them.
        if p.spec_husbandryFood ~= nil and seen[p] == nil then
            seen[p] = true
            local b = readBarn(p)
            if b ~= nil then self.barns[#self.barns + 1] = b end
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
        b.demand, vol(b.held),
        b.engine or 0, b.modelF or 0,
        (b.engine ~= nil and b.modelF ~= nil and math.abs(b.engine - b.modelF) > 0.02)
            and l10n("ar_sum_disagree", "   <<< MODEL DISAGREES") or ""))
end

-- ---------------------------------------------------------------------------
-- FRAME
-- ---------------------------------------------------------------------------
function AnimalReduxPage:onGuiSetupFinished()
    AnimalReduxPage:superClass().onGuiSetupFinished(self)
    for _, id in ipairs({ "barnList", "groupList" }) do
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
    self._realtimeLists = { "barnList", "groupList" }
    self:rebuild()
    if self.barnList ~= nil then self.barnList:reloadData() end
    if self.groupList ~= nil then self.groupList:reloadData() end
    self:updateSummary()
end

-- ---- SmoothList delegate (two lists, told apart by identity) ---------------
function AnimalReduxPage:getNumberOfItemsInSection(list, section)
    if list == self.barnList then return #(self.barns or {}) end
    return #(self.rows or {})
end

function AnimalReduxPage:populateCellForItemInSection(list, section, index, cell)
    if list == self.barnList then
        local b = (self.barns or {})[index]
        if b == nil then return end
        local nameCell = cell:getAttribute("barnName")
        if nameCell ~= nil then nameCell:setText(b.name) end
        local fCell = cell:getAttribute("barnFactor")
        if fCell ~= nil then
            if not b.hasAnimals then
                fCell:setText("-")
                setColour(fCell, 1)
            else
                fCell:setText(string.format("%.2f", b.engine or 0))
                setColour(fCell, b.engine or 0)
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
    if self.groupList ~= nil then self.groupList:reloadData() end
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
