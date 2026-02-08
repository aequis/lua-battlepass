--[[
    Battle Pass Rewards

    Handles reward distribution for all types: items, gold, titles, spells, currency.
    Provides a dispatch table mapping reward type IDs to handler functions.

    @module battlepass_reward
    @author Shonik
    @license MIT
]]

local Config = require("battlepass_config")

local Reward = Object:extend()

-- ============================================================================
-- REWARD HANDLERS
-- ============================================================================

function Reward.GrantItem(player, rewardData)
    local itemId = rewardData.reward_id
    local count = rewardData.reward_count or 1

    local itemTemplate = GetItemTemplate(itemId)
    if not itemTemplate then
        return false
    end

    local existingCount = player:GetItemCount(itemId)
    if existingCount > 0 then
        local query = WorldDBQuery(string.format(
            "SELECT maxcount FROM item_template WHERE entry = %d", itemId))

        if query then
            local maxCount = query:GetInt32(0)
            if maxCount == 1 then
                return false
            end
            if maxCount > 0 and (existingCount + count) > maxCount then
                return false
            end
        end
    end

    if not player:AddItem(itemId, count) then
        return false
    end

    return true
end

function Reward.GrantGold(player, rewardData)
    local copper = rewardData.reward_count or 0
    player:ModifyMoney(copper)
    return true
end

function Reward.GrantTitle(player, rewardData)
    local titleId = rewardData.reward_id

    if player:HasTitle(titleId) then
        return false
    end

    player:SetKnownTitle(titleId)
    return true
end

function Reward.GrantSpell(player, rewardData)
    local spellId = rewardData.reward_id

    if player:HasSpell(spellId) then
        return false
    end

    player:LearnSpell(spellId)
    return true
end

function Reward.GrantCurrency(player, rewardData)
    return Reward.GrantItem(player, rewardData)
end

-- ============================================================================
-- DISPATCH TABLE
-- ============================================================================

Reward.HANDLERS = {
    [1] = Reward.GrantItem,
    [2] = Reward.GrantGold,
    [3] = Reward.GrantTitle,
    [4] = Reward.GrantSpell,
    [5] = Reward.GrantCurrency,
}

-- ============================================================================
-- MAIN INTERFACE
-- ============================================================================

function Reward.Claim(player, battlepass, level)
    local config = Config.GetInstance()
    if not config:IsEnabled() then return false end

    local levelData = config:GetLevel(level)
    if not levelData or battlepass:GetLevel() < level or battlepass:IsLevelClaimed(level) then
        return false
    end

    local handler = Reward.HANDLERS[levelData.reward_type]
    if not handler then return false end

    local success = handler(player, levelData)
    if success or Reward.PlayerOwnsReward(player, levelData) then
        battlepass:ClaimLevel(level):Save()
        return true
    end
    return false
end

function Reward.ClaimAll(player, battlepass)
    local config = Config.GetInstance()
    for lvl = 1, battlepass:GetLevel() do
        if not battlepass:IsLevelClaimed(lvl) then
            local levelData = config:GetLevel(lvl)
            if levelData then
                local handler = Reward.HANDLERS[levelData.reward_type]
                if handler and (handler(player, levelData) or Reward.PlayerOwnsReward(player, levelData)) then
                    battlepass:ClaimLevel(lvl)
                end
            end
        end
    end
    battlepass:Save()
end

-- ============================================================================
-- UTILITY
-- ============================================================================

function Reward.PlayerOwnsReward(player, levelData)
    local rewardType = levelData.reward_type
    local rewardId = levelData.reward_id

    if rewardType == 1 or rewardType == 5 then
        local itemCount = player:GetItemCount(rewardId)
        if itemCount > 0 then
            local query = WorldDBQuery(string.format(
                "SELECT maxcount FROM item_template WHERE entry = %d", rewardId))
            if query then
                local maxCount = query:GetInt32(0)
                if maxCount == 1 then
                    return true
                end
            end
        end
        return false
    elseif rewardType == 2 then
        return false
    elseif rewardType == 3 then
        return player:HasTitle(rewardId)
    elseif rewardType == 4 then
        return player:HasSpell(rewardId)
    end

    return false
end

function Reward.FormatDescription(levelData)
    local config = Config.GetInstance()
    local typeName = config:GetRewardTypeName(levelData.reward_type)

    local desc = string.format("Level %d: |cffffd700%s|r",
        levelData.level, levelData.reward_name)

    if levelData.description and levelData.description ~= "" then
        desc = desc .. " - " .. levelData.description
    end

    return desc
end

return Reward
