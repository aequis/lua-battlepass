--[[
    Battle Pass Class

    Represents a player's Battle Pass progression.
    Manages level, experience, claimed rewards, and persistence.

    Uses method chaining on setters and automatic recalculation
    of experience thresholds on level changes.

    @class BattlePass
    @author Shonik
    @license MIT
]]

local Repository = require("battlepass_repository")
local Config = require("battlepass_config")

local BattlePass = Object:extend()

-- ============================================================================
-- PRIVATE FUNCTIONS
-- ============================================================================

local function CalculateExpForLevel(level, config)
    local levelData = config:GetLevel(level)
    if levelData and levelData.exp_required > 0 then
        return levelData.exp_required
    end

    local baseExp = config:GetNumber("exp_per_level", 1000)
    local scaling = config:GetNumber("exp_scaling", 1.1)

    return math.floor(baseExp * math.pow(scaling, level - 1))
end

-- ============================================================================
-- CONSTRUCTOR
-- ============================================================================

function BattlePass:new(player_guid)
    local config = Config.GetInstance()

    self.guid = player_guid
    self.level = 0
    self.exp = {
        current = 0,
        max = CalculateExpForLevel(1, config)
    }
    self.total_exp = 0
    self.claimed_levels = {}
    self.daily_login = nil
    self._dirty = false
end

-- ============================================================================
-- DATABASE OPERATIONS
-- ============================================================================

function BattlePass:Load()
    local repo = Repository.GetInstance()
    local config = Config.GetInstance()
    local data = repo:GetPlayerProgress(self.guid)

    if not data then
        repo:CreatePlayerEntry(self.guid)
        self._dirty = false
        return self
    end

    self.level = data.current_level
    self.exp.current = data.current_exp
    self.exp.max = CalculateExpForLevel(self.level + 1, config)
    self.total_exp = data.total_exp
    self.claimed_levels = data.claimed_levels or {}
    self.daily_login = data.last_daily_login
    self._dirty = false

    return self
end

function BattlePass:Save()
    if not self._dirty then
        return self
    end

    local repo = Repository.GetInstance()

    repo:SavePlayerProgress(self.guid, self.level, self.exp.current, self.total_exp, self.claimed_levels)
    self._dirty = false

    return self
end

-- ============================================================================
-- LEVEL ACCESSORS
-- ============================================================================

function BattlePass:GetLevel()
    return self.level
end

function BattlePass:SetLevel(level)
    if not level or level < 0 then
        return self
    end

    local config = Config.GetInstance()
    local maxLevel = config:GetMaxLevel()

    if level > maxLevel then
        level = maxLevel
    end

    self.level = level
    self.exp.max = CalculateExpForLevel(level + 1, config)
    self._dirty = true

    return self
end

function BattlePass:AddLevel(n)
    n = n or 1
    if n <= 0 then
        return self
    end
    return self:SetLevel(self.level + n)
end

function BattlePass:IsMaxLevel()
    local config = Config.GetInstance()
    return self.level >= config:GetMaxLevel()
end

-- ============================================================================
-- EXPERIENCE ACCESSORS
-- ============================================================================

function BattlePass:GetExperience()
    return self.exp.current
end

function BattlePass:SetExperience(experience)
    if not experience or experience < 0 then
        experience = 0
    end

    self.exp.current = experience
    self._dirty = true

    return self
end

function BattlePass:AddExperience(amount)
    if not amount or amount <= 0 then
        return self
    end

    self.exp.current = self.exp.current + amount
    self.total_exp = self.total_exp + amount
    self._dirty = true

    return self
end

function BattlePass:GetExperienceForNextLevel()
    return self.exp.max
end

function BattlePass:GetExperienceProgress()
    if self.exp.max == 0 then
        return 0
    end
    return math.floor((self.exp.current / self.exp.max) * 100)
end

function BattlePass:GetTotalExp()
    return self.total_exp
end

-- ============================================================================
-- LEVEL-UP PROCESSING
-- ============================================================================

function BattlePass:ProcessLevelUps()
    local config = Config.GetInstance()
    local maxLevel = config:GetMaxLevel()
    local levelsGained = 0

    while self.level < maxLevel do
        local expRequired = CalculateExpForLevel(self.level + 1, config)

        if self.exp.current >= expRequired then
            self.exp.current = self.exp.current - expRequired
            self.level = self.level + 1
            levelsGained = levelsGained + 1
        else
            break
        end
    end

    if levelsGained > 0 then
        self.exp.max = CalculateExpForLevel(self.level + 1, config)
        self._dirty = true
    end

    return levelsGained
end

-- ============================================================================
-- CLAIMED LEVELS
-- ============================================================================

function BattlePass:IsLevelClaimed(level)
    return self.claimed_levels[level] == true
end

function BattlePass:GetClaimedLevels()
    return self.claimed_levels
end

function BattlePass:ClaimLevel(level)
    self.claimed_levels[level] = true
    self._dirty = true
    return self
end

function BattlePass:UnclaimLevel(level)
    self.claimed_levels[level] = nil
    self._dirty = true
    return self
end

function BattlePass:CountUnclaimedRewards()
    local config = Config.GetInstance()
    local count = 0
    for lvl = 1, self.level do
        if config:GetLevel(lvl) and not self.claimed_levels[lvl] then
            count = count + 1
        end
    end
    return count
end

function BattlePass:GetAvailableRewards()
    local config = Config.GetInstance()
    local rewards = {}
    for lvl = 1, self.level do
        local levelData = config:GetLevel(lvl)
        if levelData and not self.claimed_levels[lvl] then
            table.insert(rewards, levelData)
        end
    end
    return rewards
end

-- ============================================================================
-- DAILY LOGIN
-- ============================================================================

function BattlePass:GetDailyLogin()
    return self.daily_login
end

function BattlePass:IsDailyLoginAvailable()
    if not self.daily_login or self.daily_login == "" then
        return true
    end

    local today = os.date("%Y-%m-%d")
    return self.daily_login ~= today
end

function BattlePass:UpdateDailyLogin()
    self.daily_login = os.date("%Y-%m-%d")

    local repo = Repository.GetInstance()
    repo:UpdateDailyLogin(self.guid)

    return self
end

-- ============================================================================
-- DIRTY STATE
-- ============================================================================

function BattlePass:IsDirty()
    return self._dirty
end

function BattlePass:MarkDirty()
    self._dirty = true
    return self
end

function BattlePass:MarkClean()
    self._dirty = false
    return self
end

function BattlePass:Reset()
    local config = Config.GetInstance()
    self.level = 0
    self.exp.current = 0
    self.exp.max = CalculateExpForLevel(1, config)
    self.total_exp = 0
    self.claimed_levels = {}
    self.daily_login = nil
    self._dirty = true
    return self
end

-- ============================================================================
-- UTILITY
-- ============================================================================

function BattlePass:GetGUID()
    return self.guid
end

function BattlePass:GetState()
    return {
        guid = self.guid,
        level = self.level,
        experience = self.exp.current,
        experience_max = self.exp.max,
        total_exp = self.total_exp,
        claimed_levels = self.claimed_levels,
        unclaimed_count = self:CountUnclaimedRewards()
    }
end

return BattlePass
