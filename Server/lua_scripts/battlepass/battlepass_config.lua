--[[
    Battle Pass Configuration

    Singleton service that loads and caches all Battle Pass configuration
    data from the database. Provides typed accessors for all settings.

    @module battlepass_config
    @author Shonik
    @license MIT
]]

local Repository = require("battlepass_repository")

local Config = Object:extend()

local Instance = nil

-- ============================================================================
-- DEFAULTS
-- ============================================================================

local DEFAULT_CONFIG = {
    enabled = "0",
    max_level = "100",
    exp_per_level = "1000",
    exp_scaling = "1.1",
}

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================

function Config:new()
    local repo = Repository.GetInstance()

    self._config = {}
    self._levels = {}
    self._sources = {}
    self._reward_types = {}
    self._tables_exist = false

    self._tables_exist = repo:VerifyDatabaseSchema()

    if not self._tables_exist then
        print("[BattlePass] Database tables not found. System DISABLED.")
        print("[BattlePass] Import SQL files from data/sql/custom/")
        for key, value in pairs(DEFAULT_CONFIG) do
            self._config[key] = value
        end
        return
    end

    self:_LoadAll(repo)
end

function Config.GetInstance()
    if not Instance then
        Instance = Config()
    end
    return Instance
end

-- ============================================================================
-- PRIVATE LOADING
-- ============================================================================

function Config:_LoadAll(repo)
    repo = repo or Repository.GetInstance()

    self._config = repo:GetConfig()
    self._levels = repo:GetLevels()
    self._sources = repo:GetProgressSources()
    self._reward_types = repo:GetRewardTypes()

    -- Apply defaults for missing keys
    for key, value in pairs(DEFAULT_CONFIG) do
        if self._config[key] == nil then
            self._config[key] = value
        end
    end
end

-- ============================================================================
-- CONFIG ACCESSORS
-- ============================================================================

function Config:GetByField(key, default)
    if self._config[key] ~= nil then
        return self._config[key]
    end
    return default or DEFAULT_CONFIG[key] or ""
end

function Config:GetNumber(key, default)
    local value = self:GetByField(key, tostring(default))
    return tonumber(value) or default
end

function Config:GetBool(key, default)
    local value = self:GetByField(key, default and "1" or "0")
    return value == "1" or value == "true"
end

function Config:IsEnabled()
    if not self._tables_exist then
        return false
    end
    return self:GetBool("enabled", true)
end

function Config:TablesExist()
    return self._tables_exist
end

-- ============================================================================
-- LEVEL ACCESSORS
-- ============================================================================

function Config:GetLevel(level)
    return self._levels[level]
end

function Config:GetLevels()
    return self._levels
end

function Config:GetMaxLevel()
    return self:GetNumber("max_level", 100)
end

-- ============================================================================
-- SOURCE ACCESSORS
-- ============================================================================

function Config:GetSource(sourceType, subtype)
    subtype = subtype or 0

    if subtype > 0 then
        local specificKey = sourceType .. ":" .. subtype
        if self._sources[specificKey] then
            return self._sources[specificKey]
        end
    end

    return self._sources[sourceType]
end

function Config:GetSources()
    return self._sources
end

-- ============================================================================
-- REWARD TYPE ACCESSORS
-- ============================================================================

function Config:GetRewardType(typeId)
    return self._reward_types[typeId]
end

function Config:GetRewardTypes()
    return self._reward_types
end

function Config:GetRewardTypeName(typeId)
    local typeInfo = self._reward_types[typeId]
    if typeInfo then
        return typeInfo.name
    end
    return "unknown"
end

-- ============================================================================
-- RELOAD
-- ============================================================================

function Config:Reload()
    local repo = Repository.GetInstance()
    self._tables_exist = repo:VerifyDatabaseSchema()

    if not self._tables_exist then
        return
    end

    self:_LoadAll(repo)
end

return Config
