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
        return direct.SmartDistribution, AnimalRedux.DR_MOD_NAME
    end

    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        local okMods, mods = pcall(g_modManager.getActiveMods, g_modManager)
        if okMods and type(mods) == "table" then
            for _, mod in pairs(mods) do
                local name = type(mod) == "table" and mod.modName or nil
                if type(name) == "string" and name ~= AnimalRedux.MOD_NAME then
                    local env = G[name]
                    if looksLikeDR(env) then
                        return env.SmartDistribution, name
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
function AnimalRedux.onMissionLoaded()
    local SD, whereOrWhy = AnimalRedux.resolveDistributionRedux()

    if SD == nil then
        AnimalRedux.warn("Distribution Redux was not found (%s). Animal Redux requires it and is DISABLED.",
            tostring(whereOrWhy))
        AnimalRedux.enabled = false
        return
    end

    AnimalRedux.DR = SD
    AnimalRedux.enabled = true

    local apiVersion, apiOk = AnimalRedux.checkApiVersion(SD)
    AnimalRedux.warn("v%s linked to Distribution Redux (global '%s', API v%d%s)",
        AnimalRedux.VERSION, tostring(whereOrWhy), apiVersion,
        apiOk and "" or string.format("; this mod wants v%d+", AnimalRedux.DR_MIN_API))

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
