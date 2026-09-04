-- ============================================================================
-- AnimalSettings.lua  (Animal Redux)
--
-- Animal Redux's own settings, shown as a TAB on Distribution Redux's Settings
-- page.
--
-- DR OWNS THE LAYOUT, THIS FILE OWNS THE DATA -- the same split the husbandry
-- panel already uses (DR 5.81 / 5.84). DR hands us nothing but a call: we return
-- a table of definitions and DR renders them into its own hand-tiled rows. AR
-- never places an element on DR's page, which is what keeps a page whose geometry
-- is measured to the pixel safe from us.
--
-- THE TAB EXISTS ONLY WHILE THIS MOD DOES. DR declares no AR tab: it is
-- registered from here at mission load, so a player who removes Animal Redux sees
-- DR's settings page exactly as it was, with one tab. That is the "if AR is not
-- installed that page should not be there" requirement, satisfied by construction
-- rather than by a check.
--
-- THREE SETTINGS, and each one turns a whole feature off rather than tuning it:
--
--   trading     manual Buy / Sell. Off removes the footer button.
--   autoTrader  standing buy and sell orders. Off removes the footer button AND
--               CLEARS EVERY ORDER -- see the confirmation below, which is not
--               optional.
--   debug       AR's diagnostic log lines. Off is the default and is what a
--               player should be running.
--
-- STORED AS AN INDEX, NEVER A LABEL, because the label is display text that a
-- translation moves and the index is what survives a save. DR's own settings have
-- carried the index for the same reason, and it is what its API asks for.
--
-- SAVEGAME SCOPED, through AnimalPersist, beside buySchedules / sellOrders /
-- herdPolicy. Two of the three are world state that the server owns, so the
-- savegame is the right home for them; `debug` is arguably a per-machine
-- preference and is kept here anyway rather than inventing a second storage layer
-- for one flag.
--
-- MULTIPLAYER, stated rather than discovered later: AR has no settings event, so
-- a CLIENT changing one of these does not reach the server. The server's values
-- are what the pass acts on. Known gap, not a silent one.
-- ============================================================================

AnimalSettings = {}

AnimalSettings.MOD_NAME = "FS25_Animal_Redux"

local function l10n(key, fallback)
    if AnimalRedux ~= nil and AnimalRedux.l10n ~= nil then return AnimalRedux.l10n(key, fallback) end
    return fallback
end

local function warn(fmt, ...)
    if AnimalRedux ~= nil and AnimalRedux.warn ~= nil then return AnimalRedux.warn(fmt, ...) end
    local ok, msg = pcall(string.format, fmt, ...)
    print("[AnimalRedux] " .. (ok and msg or tostring(fmt)))
end

---Progress, not failure. Gated on the Debug setting so a normal session's log
-- carries only what went wrong (AnimalSettings, the "debug" row).
local function dbg(fmt, ...)
    if AnimalRedux ~= nil and AnimalRedux.log ~= nil then return AnimalRedux.log(fmt, ...) end
end

-- ---------------------------------------------------------------------------
-- THE DEFINITIONS.
--
-- `values` is the ordered list of stored values; the INDEX into it is what is
-- persisted and what DR's selector carries. A boolean setting is therefore
-- { false, true } and index 2 means on.
--
-- Order here is the order of the rows on screen: the two that change what the
-- player can do first, the diagnostic one last.
AnimalSettings.ORDER = { "trading", "autoTrader", "herdAdviser", "advancedFeeder", "debug" }

AnimalSettings.DEFS = {
    trading = {
        values  = { false, true },
        default = 2,
        title   = "ar_set_trading",
        tooltip = "ar_set_trading_tt",
        strings = { "ar_set_off", "ar_set_on" },
    },
    autoTrader = {
        -- DEFAULT OFF, 2026-09-04, author: *"I am still working on it, we will
        -- reactivate later once we have autotrader working correctly."* A feature
        -- that is not finished should not be running on a farm by default.
        --
        -- THIS CHANGED THE ANSWER FOR EXISTING SAVES TOO, not just new ones, and
        -- that had to be made safe before flipping it: a save carries a stored
        -- value only if it was saved SINCE the settings existed, so every save
        -- older than today adopts the new default. Both of the author's saves hold
        -- a buy schedule, so those orders became dormant AND unreachable -- and
        -- until this flip nothing gated the RUNNER, so they would have gone on
        -- spending money on the hour with no button to reach them. runDue is now
        -- gated (AnimalBuySchedule), which makes the off state honest.
        --
        -- NOTHING IS DELETED BY ADOPTING THE DEFAULT. loadSection applies values
        -- silently, so the orders are preserved and dormant; switching the setting
        -- back on restores them intact. Deletion only ever happens through the
        -- confirmation, on an explicit change by the player.
        values  = { false, true },
        default = 1,
        title   = "ar_set_autoTrader",
        tooltip = "ar_set_autoTrader_tt",
        strings = { "ar_set_off", "ar_set_on" },
    },
    herdAdviser = {
        values  = { false, true },
        default = 2,
        title   = "ar_set_herdAdviser",
        tooltip = "ar_set_herdAdviser_tt",
        strings = { "ar_set_off", "ar_set_on" },
    },
    advancedFeeder = {
        values  = { false, true },
        default = 2,
        title   = "ar_set_advancedFeeder",
        tooltip = "ar_set_advancedFeeder_tt",
        strings = { "ar_set_off", "ar_set_on" },
    },
    debug = {
        values  = { false, true },
        default = 1,
        title   = "ar_set_debug",
        tooltip = "ar_set_debug_tt",
        strings = { "ar_set_off", "ar_set_on" },
    },
}

---Current index per setting id. Seeded from the defaults so every reader has an
-- answer before a savegame has been loaded, which matters because the GUI can be
-- opened on a mission that failed to load our file.
AnimalSettings.state = {}
for _, id in ipairs(AnimalSettings.ORDER) do
    AnimalSettings.state[id] = AnimalSettings.DEFS[id].default
end

-- ---------------------------------------------------------------------------
---The stored VALUE of a setting (not its index).
function AnimalSettings.get(id)
    local def = AnimalSettings.DEFS[id]
    if def == nil then return nil end
    local i = AnimalSettings.state[id] or def.default
    return def.values[i]
end

---The 1-based index, which is what DR's selector wants.
function AnimalSettings.index(id)
    local def = AnimalSettings.DEFS[id]
    if def == nil then return 1 end
    return AnimalSettings.state[id] or def.default
end

---Set by index. Returns true if the value actually moved, so a caller can skip
-- the side effects of a no-op click.
--
-- `silent` skips the side effects entirely and is for the LOADER: applying a
-- saved value must not raise a confirmation dialog or clear anything.
function AnimalSettings.setIndex(id, i, silent)
    local def = AnimalSettings.DEFS[id]
    if def == nil then return false end
    if type(i) ~= "number" then return false end
    i = math.floor(i)
    if i < 1 or i > #def.values then return false end
    local was = AnimalSettings.state[id]
    AnimalSettings.state[id] = i
    if was == i then return false end
    if not silent then AnimalSettings.onChanged(id, def.values[i], was or def.default) end
    return true
end

-- ---------------------------------------------------------------------------
-- THE THREE READERS. Everything that gates on a setting asks through one of
-- these rather than reading `state` directly, so the storage shape stays private.

-- EVERY ONE OF THESE FAILS OPEN except debug: `~= false` means an unknown id or a
-- half-loaded state leaves the feature ON, which is the behaviour before the
-- setting existed. Debug is the exception and tests `== true`, because the safe
-- direction there is QUIET -- an unreadable state must not start writing to the
-- log. Written as an explicit comparison rather than a truth test, because these
-- hold real values and this codebase has been bitten twice by `0`/`false`
-- collapsing in a boolean position (DR 5.44 / 5.46c).
function AnimalSettings.tradingEnabled()        return AnimalSettings.get("trading")        ~= false end
function AnimalSettings.autoTraderEnabled()     return AnimalSettings.get("autoTrader")     ~= false end
function AnimalSettings.herdAdviserEnabled()    return AnimalSettings.get("herdAdviser")    ~= false end
function AnimalSettings.advancedFeederEnabled() return AnimalSettings.get("advancedFeeder") ~= false end
function AnimalSettings.debugEnabled()          return AnimalSettings.get("debug")          == true  end

-- ---------------------------------------------------------------------------
---How many standing orders would be destroyed by switching the auto trader off.
-- Counted rather than assumed, because the confirmation has to NAME them: "this
-- will delete things" is not a question a player can answer.
-- THE TWO LISTS ARE NOT NAMED ALIKE, and assuming they were is a bug this nearly
-- shipped with: the buy side is AnimalBuySchedule.SCHEDULES and the sell side is
-- AnimalSellSchedule.ORDERS. Reading `.orders` on both would have counted zero
-- buy schedules and then "cleared" them by creating an unused field, leaving
-- every standing buy order running while the confirmation said they were gone.
function AnimalSettings.orderCounts()
    local buys, sells = 0, 0
    if AnimalBuySchedule ~= nil and type(AnimalBuySchedule.schedules) == "table" then
        buys = #AnimalBuySchedule.schedules
    end
    if AnimalSellSchedule ~= nil and type(AnimalSellSchedule.orders) == "table" then
        sells = #AnimalSellSchedule.orders
    end
    return buys, sells
end

---Delete every standing order, both directions. Returns what went.
--
-- THE LISTS ARE REPLACED, NOT EMPTIED IN PLACE. Anything holding a reference to
-- the old table -- an open dialog mid-populate -- then keeps a consistent view of
-- what it was already showing rather than having rows vanish underneath it.
function AnimalSettings.clearAllOrders()
    local buys, sells = AnimalSettings.orderCounts()
    if AnimalBuySchedule ~= nil then AnimalBuySchedule.schedules = {} end
    if AnimalSellSchedule ~= nil then AnimalSellSchedule.orders = {} end
    warn("auto trader OFF: cleared %d buy schedule(s) and %d sell order(s)", buys, sells)
    return buys, sells
end

-- ---------------------------------------------------------------------------
-- THE CONFIRMATION.
--
-- Switching the auto trader off DELETES persisted orders and there is no undo
-- path, so a mis-click on a settings arrow must not be able to do it. That is the
-- one-way data loss DR deleted enforceValidModes over (DR 5.48): world state is
-- transient, a player's instruction is not.
--
-- THE DIALOG SHAPE IS EMPIRICAL, NOT READ. `Gui:showYesNoDialog` does not appear
-- anywhere in the readable SDK source -- the GUI layer is largely stripped, so an
-- absence there proves nothing (8.1) -- and this is the sequence AutoDrive ships
-- and runs, which is the same standard of evidence DR used to settle the
-- TextInput element (5.70).
--
-- IT FAILS SAFE. If the dialog cannot be raised for any reason the setting is put
-- BACK and nothing is cleared: never destroy on the assumption that a question
-- was asked.
local function confirmClear(onYes, onNo)
    local buys, sells = AnimalSettings.orderCounts()
    if buys + sells == 0 then onYes(); return true end       -- nothing to lose, nothing to ask

    if g_gui == nil or g_gui.showDialog == nil then onNo(); return false end
    local ok = pcall(function()
        local dlg = g_gui:showDialog("YesNoDialog")
        if dlg == nil or dlg.target == nil then error("no YesNoDialog", 0) end
        local t = dlg.target
        if t.setTitle ~= nil then
            t:setTitle(l10n("ar_set_clearTitle", "Turn the Auto Trader off?"))
        end
        -- THE COUNTS ARE THE POINT OF THE QUESTION, so the sentence is checked
        -- before it is shown. A translation that drops the two %d placeholders
        -- would otherwise silently reduce this to "there is no undo" -- true, and
        -- useless, because the player would not know what they were about to
        -- lose. If the format does not carry both, the shipped English does.
        -- (DR 5.60 guards a money setting the same way, for the same reason.)
        local EN   = "This deletes %d buy schedule(s) and %d sell order(s). There is no undo."
        local fmt  = l10n("ar_set_clearText", EN)
        local _, n = tostring(fmt):gsub("%%d", "")
        if n < 2 then fmt = EN end
        local okF, text = pcall(string.format, fmt, buys, sells)
        if not okF then text = string.format(EN, buys, sells) end
        if t.dialogTextElement ~= nil and t.dialogTextElement.setText ~= nil then
            t.dialogTextElement:setText(text)
        elseif t.setText ~= nil then
            t:setText(text)
        end
        if t.setCallback == nil then error("YesNoDialog has no setCallback", 0) end
        t:setCallback(function(_, yes)
            if yes then onYes() else onNo() end
        end, AnimalSettings)
    end)
    if not ok then
        warn("could not raise the confirmation dialog; the auto trader was left ON "
             .. "and no orders were cleared")
        onNo()
    end
    return ok
end

-- ---------------------------------------------------------------------------
---A setting moved. Everything that has to happen as a consequence happens here,
-- so there is one place to read rather than a side effect per caller.
function AnimalSettings.onChanged(id, value, previousIndex)
    if id == "debug" then
        -- The only setting that takes effect on the spot and needs nothing else.
        if AnimalRedux ~= nil then AnimalRedux.debug = (value == true) end
        warn("debug logging %s", value and "ON" or "OFF")

    elseif id == "trading" then
        AnimalSettings.refreshFooter()
        warn("manual Buy / Sell %s", value and "ON" or "OFF")

    elseif id == "herdAdviser" then
        -- The panel lines need no push: AnimalRedux.husbandryPanel simply stops
        -- filling them and DR blanks the text on the next draw. The Animals tab's
        -- RECOMMENDATION column is a COLUMN and has to be shown or hidden, which
        -- is a view decision, so the page is asked to re-apply it.
        AnimalSettings.refreshViews()
        warn("Herd Adviser %s", value and "ON" or "OFF")

    elseif id == "advancedFeeder" then
        -- Nothing to push at all. The planner declines from its first line and DR
        -- falls back to its own feed logic on the next hourly pass, byte for byte
        -- (DR's own contract: a nil plan is identical to no planner registered).
        warn("Advanced Animal Feeder %s -- Distribution Redux %s", value and "ON" or "OFF",
             value and "takes our feed plan" or "uses its own feed logic")

    elseif id == "autoTrader" then
        if value == false then
            -- ASK FIRST. The state has already moved to Off at this point, so the
            -- No branch has to put it back -- and DR re-reads every row after a
            -- set, which is what makes the selector snap back on screen.
            confirmClear(
                function()
                    AnimalSettings.clearAllOrders()
                    AnimalSettings.refreshFooter()
                    AnimalSettings.refreshPage()
                end,
                function()
                    -- PUT IT BACK EXACTLY WHERE IT WAS, from the remembered index
                    -- rather than by hunting for the "on" value: the restore must
                    -- not depend on what the values happen to be.
                    AnimalSettings.state[id] = previousIndex
                    AnimalSettings.refreshPage()
                    warn("auto trader left ON; no orders were cleared")
                end)
        else
            AnimalSettings.refreshFooter()
            warn("auto trader ON")
        end
    end
end

---Ask the Herd Inspector to rebuild its footer, if it is built. Guarded on the
-- page existing: the settings page can be opened before the herd tab ever has
-- been.
function AnimalSettings.refreshFooter()
    if HerdInspectorPage == nil or HerdInspectorPage.refreshButtons == nil then return end
    pcall(HerdInspectorPage.refreshButtons)
end

---Ask the Herd Inspector to re-apply its view, if it is built. A setting that
-- shows or hides a COLUMN changes the shape of a table, which is a view decision
-- and not something a repopulate can express.
function AnimalSettings.refreshViews()
    if HerdInspectorPage == nil or HerdInspectorPage.refreshView == nil then return end
    pcall(HerdInspectorPage.refreshView)
end

---Redraw DR's settings rows, for a change that happened AFTER the click returned
-- (the confirmation dialog answers later, so DR's own re-read has already run by
-- then and would still show the un-answered value).
function AnimalSettings.refreshPage()
    local SD = AnimalRedux ~= nil and AnimalRedux.DR or nil
    if SD == nil then return end
    if SD.refreshSettingsRows ~= nil then pcall(SD.refreshSettingsRows) end
end

-- ---------------------------------------------------------------------------
---The rows DR draws. A FUNCTION rather than a table, so the labels are resolved
-- when the page opens rather than at load: l10n is not necessarily up when this
-- chunk runs, and a title captured too early would be the English fallback for
-- the rest of the session.
function AnimalSettings.rows()
    local rows = {}
    for _, id in ipairs(AnimalSettings.ORDER) do
        local def = AnimalSettings.DEFS[id]
        local strings = {}
        for i, key in ipairs(def.strings) do
            strings[i] = l10n(key, i == 1 and "Off" or "On")
        end
        rows[#rows + 1] = {
            id      = id,
            title   = l10n(def.title, id),
            tooltip = l10n(def.tooltip, nil),
            strings = strings,
            get     = function() return AnimalSettings.index(id) end,
            set     = function(i) AnimalSettings.setIndex(id, i) end,
        }
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- PERSISTENCE. One flat element per setting, keyed by NAME rather than by
-- position, so adding or reordering a setting cannot silently re-point a stored
-- value at a different one.
--
-- THE VALUE STORED IS THE INDEX. A translation moves a label; nothing moves an
-- index but us.
-- THE HANDLE IS A NUMBER, NOT AN OBJECT. AnimalPersist opens the file with
-- loadXMLFile, which returns an integer handle, so these are the FREE FUNCTIONS
-- setXMLInt(xml, key, v) / getXMLString(xml, key) -- never xml:setInt(...).
-- Writing it the method way threw `attempt to index number with 'getString'` on
-- the first load, and every other section in this mod already does it this way.
local function saveSection(xml, key)
    local i = 0
    for _, id in ipairs(AnimalSettings.ORDER) do
        local k = string.format("%s.setting(%d)", key, i)
        setXMLString(xml, k .. "#id", id)
        setXMLInt(xml, k .. "#index", AnimalSettings.index(id))
        i = i + 1
    end
end

local function loadSection(xml, key)
    local i = 0
    while true do
        local k = string.format("%s.setting(%d)", key, i)
        local id = getXMLString(xml, k .. "#id")
        if id == nil then break end
        local idx = getXMLInt(xml, k .. "#index")
        -- SILENT: applying a saved value must not raise the confirmation dialog
        -- or clear anybody's orders. It is a restore, not a decision.
        if idx ~= nil then AnimalSettings.setIndex(id, idx, true) end
        i = i + 1
    end
    -- Applied AFTER the whole section is read, so a half-read file cannot leave
    -- the debug flag half-applied.
    if AnimalRedux ~= nil then AnimalRedux.debug = AnimalSettings.debugEnabled() end
    if i > 0 then dbg("%d setting(s) restored", i) end
end

if AnimalPersist ~= nil and AnimalPersist.register ~= nil then
    AnimalPersist.register("settings", saveSection, loadSection)
end

-- ---------------------------------------------------------------------------
---Register the tab on DR's settings page. Called from AnimalRedux's mission-load
-- hook, once DR has been resolved.
--
-- GATED ON THE CALL EXISTING, not on a version number, so a DR that gains this in
-- a later build works without a bump here -- the rule the husbandry panel already
-- follows. A DR too old simply has no AR settings tab, and every setting keeps
-- its default, which is every feature ON except debug.
function AnimalSettings.install(SD)
    if SD == nil or SD.API == nil or SD.API.registerSettingsTab == nil then
        warn("Distribution Redux has no settings tab API (needs v8+); AR settings are not shown")
        return false
    end
    local ok, res = pcall(SD.API.registerSettingsTab, AnimalSettings.MOD_NAME,
                          l10n("ar_set_tab", "ANIMAL REDUX"), AnimalSettings.rows)
    if ok and res then
        warn("settings tab added to the Distribution Redux settings page")
        return true
    end
    warn("settings tab NOT added: %s", tostring(res))
    return false
end
