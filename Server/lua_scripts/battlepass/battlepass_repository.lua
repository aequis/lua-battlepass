--[[
    Battle Pass Repository

    Data access layer for all Battle Pass database operations.
    Singleton pattern ensures a single point of access for all queries.

    @module battlepass_repository
    @author Shonik
    @license MIT
]]

local Repository = Object:extend()

local Instance = nil

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================

function Repository:new()
    self._schema_verified = false
end

function Repository.GetInstance()
    if not Instance then
        Instance = Repository()
    end
    return Instance
end

-- ============================================================================
-- SCHEMA VERIFICATION
-- ============================================================================

function Repository:VerifyDatabaseSchema()
    local query = WorldDBQuery("SHOW TABLES LIKE 'battlepass_config'")
    self._schema_verified = query ~= nil
    return self._schema_verified
end

function Repository:IsSchemaValid()
    return self._schema_verified
end

-- ============================================================================
-- CONFIGURATION QUERIES
-- ============================================================================

function Repository:GetConfig()
    local result = {}
    local query = WorldDBQuery("SELECT config_key, config_value FROM battlepass_config")

    if query then
        repeat
            result[query:GetString(0)] = query:GetString(1)
        until not query:NextRow()
    end

    return result
end

function Repository:GetLevels()
    local result = {}
    local query = WorldDBQuery([[
        SELECT level, exp_required, reward_type, reward_id, reward_count,
               reward_name, reward_icon, description
        FROM battlepass_levels
        ORDER BY level ASC
    ]])

    if query then
        repeat
            local level = query:GetUInt32(0)
            result[level] = {
                level = level,
                exp_required = query:GetUInt32(1),
                reward_type = query:GetUInt32(2),
                reward_id = query:GetUInt32(3),
                reward_count = query:GetUInt32(4),
                reward_name = query:GetString(5),
                reward_icon = query:GetString(6),
                description = query:GetString(7)
            }
        until not query:NextRow()
    end

    return result
end

function Repository:GetRewardTypes()
    local result = {}
    local query = WorldDBQuery("SELECT type_id, type_name, handler_func, description FROM battlepass_reward_types")

    if query then
        repeat
            local typeId = query:GetUInt32(0)
            result[typeId] = {
                id = typeId,
                name = query:GetString(1),
                handler = query:GetString(2),
                description = query:GetString(3)
            }
        until not query:NextRow()
    end

    return result
end

function Repository:GetProgressSources()
    local result = {}
    local query = WorldDBQuery([[
        SELECT source_id, source_type, source_subtype, exp_value, multiplier,
               min_level, max_level, enabled, description
        FROM battlepass_progress_sources
        WHERE enabled = 1
    ]])

    if query then
        repeat
            local sourceType = query:GetString(1)
            local subtype = query:GetUInt32(2)

            local key = sourceType
            if subtype > 0 then
                key = sourceType .. ":" .. subtype
            end

            result[key] = {
                id = query:GetUInt32(0),
                source_type = sourceType,
                subtype = subtype,
                exp_value = query:GetInt32(3),
                multiplier = query:GetFloat(4),
                min_level = query:GetUInt32(5),
                max_level = query:GetUInt32(6),
                enabled = true,
                description = query:GetString(8)
            }
        until not query:NextRow()
    end

    return result
end

-- ============================================================================
-- PLAYER DATA QUERIES
-- ============================================================================

local function ParseClaimedLevels(str)
    local result = {}
    if str and str ~= "" then
        for level in str:gmatch("%d+") do
            result[tonumber(level)] = true
        end
    end
    return result
end

local function SerializeClaimedLevels(tbl)
    local levels = {}
    for level in pairs(tbl) do
        table.insert(levels, level)
    end
    table.sort(levels)
    return table.concat(levels, ",")
end

function Repository:GetPlayerProgress(guid)
    local query = CharDBQuery(string.format([[
        SELECT current_level, current_exp, total_exp, claimed_levels, last_daily_login
        FROM character_battlepass
        WHERE guid = %d
    ]], guid))

    if not query then
        return nil
    end

    return {
        current_level = query:GetUInt32(0),
        current_exp = query:GetUInt32(1),
        total_exp = query:GetUInt32(2),
        claimed_levels = ParseClaimedLevels(query:GetString(3)),
        last_daily_login = query:GetString(4)
    }
end

function Repository:CreatePlayerEntry(guid)
    CharDBExecute(string.format([[
        INSERT INTO character_battlepass (guid, current_level, current_exp, total_exp)
        VALUES (%d, 0, 0, 0)
        ON DUPLICATE KEY UPDATE guid = guid
    ]], guid))
end

function Repository:SavePlayerProgress(guid, level, exp, total_exp, claimed_levels)
    local claimedStr = SerializeClaimedLevels(claimed_levels)
    CharDBExecute(string.format([[
        UPDATE character_battlepass
        SET current_level = %d,
            current_exp = %d,
            total_exp = %d,
            claimed_levels = '%s'
        WHERE guid = %d
    ]], level, exp, total_exp, claimedStr, guid))
end

function Repository:UpdateDailyLogin(guid)
    CharDBExecute(string.format([[
        UPDATE character_battlepass
        SET last_daily_login = CURDATE()
        WHERE guid = %d
    ]], guid))
end

function Repository:ResetPlayer(guid)
    CharDBExecute(string.format([[
        UPDATE character_battlepass
        SET current_level = 0,
            current_exp = 0,
            total_exp = 0,
            claimed_levels = NULL,
            last_daily_login = NULL
        WHERE guid = %d
    ]], guid))
end

function Repository:SetPlayerLevel(guid, level)
    CharDBExecute(string.format([[
        UPDATE character_battlepass
        SET current_level = %d,
            current_exp = 0
        WHERE guid = %d
    ]], level, guid))
end

return Repository
