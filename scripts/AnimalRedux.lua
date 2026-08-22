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
            AnimalRedux.warn("dev probes available: arFoodProbe [name] [litres], arFeedPartial [name]")
        end
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

    -- ---- THE ANIMALS TAB ----------------------------------------------------
    -- Deferred to DR's menu-ready callback rather than added here, because DR
    -- builds its menu LATER in this very same hook: mods load alphabetically, so
    -- Animal Redux appended to loadMission00Finished first and runs first. At
    -- this moment SmartDistribution._menu does not exist yet.
    if SD.API ~= nil and SD.API.onMenuReady ~= nil then
        SD.API.onMenuReady(AnimalRedux.MOD_NAME, function(menu)
            local okT, why = AnimalReduxPage.install(menu)
            if okT then
                AnimalRedux.warn("Animals tab added to the Distribution Redux menu")
            else
                AnimalRedux.warn("Animals tab NOT added: %s", tostring(why))
            end
        end)
    else
        AnimalRedux.warn("Distribution Redux has no menu API (needs v3+); no Animals tab")
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
