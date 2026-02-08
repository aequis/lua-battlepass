--[[
    Battle Pass Hook System

    Main entry point for the Battle Pass system.
    Manages all Eluna event hooks, CSMH communication,
    player lifecycle, progression, and chat commands.

    @module battlepass_hook
    @author Shonik
    @license MIT
]]

local BattlePass = require("battlepass_class")
local Config = require("battlepass_config")
local Repository = require("battlepass_repository")
local Reward = require("battlepass_reward")

-- ============================================================================
-- PLAYER CACHE
-- ============================================================================

local PlayerCache = {}

local function GetPlayerBP(player)
    local guid = player:GetGUIDLow()

    if PlayerCache[guid] then
        return PlayerCache[guid]
    end

    local bp = BattlePass(guid)
    bp:Load()

    PlayerCache[guid] = bp
    return bp
end

local function ClearPlayerBP(guid)
    PlayerCache[guid] = nil
end

local function SaveAllCached()
    for guid, bp in pairs(PlayerCache) do
        if bp:IsDirty() then
            bp:Save()
        end
    end
end

local function TableCount(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

-- ============================================================================
-- CSMH CONFIGURATION
-- ============================================================================

local CSMHConfig = {
    Prefix = "BattlePass",
    Functions = {
        [1] = "OnSyncRequest",
        [2] = "OnClaimRequest",
        [3] = "OnClaimAllRequest",
    }
}

-- ============================================================================
-- COMMUNICATION (Server -> Client)
-- ============================================================================

local function SendSync(player, bp)
    local config = Config.GetInstance()
    local configTable = {
        max_level = config:GetMaxLevel(),
        exp_per_level = config:GetNumber("exp_per_level", 1000),
        exp_scaling = config:GetNumber("exp_scaling", 1.0),
    }

    player:SendServerResponse(CSMHConfig.Prefix, 1,
        bp:GetLevel(),
        bp:GetExperience(),
        bp:GetExperienceForNextLevel(),
        bp:GetTotalExp(),
        config:GetMaxLevel(),
        bp:GetClaimedLevels(),
        configTable
    )
end

local function SendLevelDefinitions(player, bp)
    local config = Config.GetInstance()
    local maxLevel = config:GetMaxLevel()
    local levelsTable = {}

    for level = 1, maxLevel do
        local lvl = config:GetLevel(level)
        if lvl then
            local status = 0
            if lvl.level > bp:GetLevel() then
                status = 0
            elseif bp:IsLevelClaimed(lvl.level) then
                status = 2
            elseif Reward.PlayerOwnsReward(player, lvl) then
                status = 3
            else
                status = 1
            end
            table.insert(levelsTable, {
                level = lvl.level,
                name = lvl.reward_name or "Unknown",
                icon = lvl.reward_icon or "INV_Misc_QuestionMark",
                rewardType = lvl.reward_type,
                count = lvl.reward_count,
                status = status,
            })
        end
    end

    player:SendServerResponse(CSMHConfig.Prefix, 2, levelsTable)
end

local function SendProgressUpdate(player, bp, gainedExp, levelsGained)
    player:SendServerResponse(CSMHConfig.Prefix, 3,
        gainedExp,
        bp:GetLevel(),
        bp:GetExperience(),
        bp:GetExperienceForNextLevel(),
        levelsGained
    )
end

local function SendClaimConfirmation(player, level, success)
    success = success ~= false
    local message = success and "Reward claimed!" or "Failed to claim reward."

    local updatedLevels = {}
    if success then
        table.insert(updatedLevels, {
            level = level,
            status = 2,
        })
    end

    player:SendServerResponse(CSMHConfig.Prefix, 4,
        success,
        level,
        message,
        updatedLevels
    )
end

local function SendItemUse(player)
    player:SendServerResponse(CSMHConfig.Prefix, 6)
end

local function FullSync(player, bp)
    local config = Config.GetInstance()
    if not config:IsEnabled() then
        return
    end

    bp = bp or GetPlayerBP(player)
    SendLevelDefinitions(player, bp)
    SendSync(player, bp)
end

-- ============================================================================
-- CSMH HANDLERS (Client -> Server)
-- ============================================================================

function OnSyncRequest(player, _)
    if not player then
        return
    end

    FullSync(player)
end

function OnClaimRequest(player, args)
    if not player then
        return
    end

    local level = tonumber(args[1])
    if not level then
        return
    end

    local bp = GetPlayerBP(player)
    local success = Reward.Claim(player, bp, level)
    SendClaimConfirmation(player, level, success)
end

function OnClaimAllRequest(player, _)
    if not player then
        return
    end

    local bp = GetPlayerBP(player)
    Reward.ClaimAll(player, bp)
    FullSync(player, bp)
end

-- ============================================================================
-- PROGRESSION
-- ============================================================================

local function CanReceiveExp(player, sourceConfig)
    if not sourceConfig or not sourceConfig.enabled then
        return false
    end

    local playerLevel = player:GetLevel()

    if sourceConfig.min_level and playerLevel < sourceConfig.min_level then
        return false
    end

    if sourceConfig.max_level and sourceConfig.max_level > 0 and playerLevel > sourceConfig.max_level then
        return false
    end

    return true
end

local function CalculateExp(player, sourceType, subtype)
    local config = Config.GetInstance()
    local sourceConfig = config:GetSource(sourceType, subtype)

    if not CanReceiveExp(player, sourceConfig) then
        return 0
    end

    local baseExp = sourceConfig.exp_value or 0
    local multiplier = sourceConfig.multiplier or 1.0

    return math.floor(baseExp * multiplier)
end

local function AwardExp(player, bp, amount)
    if bp:IsMaxLevel() then
        return 0, 0
    end

    bp:AddExperience(amount)
    local levelsGained = bp:ProcessLevelUps()
    bp:Save()

    SendProgressUpdate(player, bp, amount, levelsGained)

    return amount, levelsGained
end

local function AwardFromSource(player, bp, sourceType, subtype)
    local exp = CalculateExp(player, sourceType, subtype)

    if exp > 0 then
        return AwardExp(player, bp, exp)
    end

    return 0, 0
end

-- ============================================================================
-- PLAYER LIFECYCLE HOOKS
-- ============================================================================

local function OnPlayerLogin(event, player)
    local config = Config.GetInstance()
    if not config:IsEnabled() then
        return
    end

    local bp = GetPlayerBP(player)

    if bp:IsDailyLoginAvailable() then
        local exp, _ = AwardFromSource(player, bp, "LOGIN_DAILY", 0)
        if exp > 0 then
            bp:UpdateDailyLogin()
        end
    end

    local unclaimed = bp:CountUnclaimedRewards()
    if unclaimed > 0 then
        player:SendBroadcastMessage(string.format(
            "|cffff8000[Battle Pass]|r You have %d unclaimed reward(s)! Use |cff00ff00.bp|r",
            unclaimed))
    end
end

local function OnPlayerLogout(event, player)
    local config = Config.GetInstance()
    if not config:IsEnabled() then
        return
    end

    local guid = player:GetGUIDLow()
    local bp = PlayerCache[guid]

    if bp and bp:IsDirty() then
        bp:Save()
    end

    ClearPlayerBP(guid)
end

-- ============================================================================
-- EXPERIENCE EVENT HOOKS
-- ============================================================================

local function OnCreatureKill(event, player, creature)
    local config = Config.GetInstance()
    if not config:IsEnabled() then
        return
    end

    local bp = GetPlayerBP(player)
    local creatureId = creature:GetEntry()
    local rank = creature:GetRank()

    local sourceType = "KILL_CREATURE"
    if rank >= 3 then
        sourceType = "KILL_BOSS"
    elseif rank >= 1 then
        sourceType = "KILL_ELITE"
    end

    local exp = CalculateExp(player, sourceType, creatureId)
    if exp == 0 then
        exp = CalculateExp(player, sourceType, 0)
    end

    if exp > 0 then
        AwardExp(player, bp, exp)
    end
end

local function OnQuestComplete(event, player, quest)
    local config = Config.GetInstance()
    if not config:IsEnabled() then
        return
    end

    local bp = GetPlayerBP(player)
    local questId = quest:GetId()
    local isDaily = quest:IsDailyQuest()
    local sourceType = isDaily and "COMPLETE_DAILY" or "COMPLETE_QUEST"

    local exp = CalculateExp(player, sourceType, questId)
    if exp == 0 then
        exp = CalculateExp(player, sourceType, 0)
    end

    if exp > 0 then
        AwardExp(player, bp, exp)
    end
end

local function OnPlayerLevelChange(event, player, oldLevel)
    local config = Config.GetInstance()
    if not config:IsEnabled() then
        return
    end

    local newLevel = player:GetLevel()
    if newLevel > oldLevel then
        local bp = GetPlayerBP(player)
        AwardFromSource(player, bp, "PLAYER_LEVELUP", 0)
    end
end

local function OnHonorableKill(event, player, victim)
    local config = Config.GetInstance()
    if not config:IsEnabled() then
        return
    end

    if not victim or not victim:IsPlayer() then
        return
    end

    local bp = GetPlayerBP(player)
    AwardFromSource(player, bp, "HONOR_KILL", 0)
end

local function OnBattlegroundEnd(event, bg, bgId, instanceId, winner)
    local config = Config.GetInstance()
    if not config:IsEnabled() then
        return
    end

    local players = bg:GetPlayers()
    if not players then
        return
    end

    for _, player in pairs(players) do
        if player and player:IsInWorld() then
            local team = player:GetTeam()
            local isWinner = (winner == team)
            local sourceType = isWinner and "WIN_BATTLEGROUND" or "LOSE_BATTLEGROUND"
            local bp = GetPlayerBP(player)
            AwardFromSource(player, bp, sourceType, bgId)
        end
    end
end

-- ============================================================================
-- SERVER LIFECYCLE HOOKS
-- ============================================================================

local function OnWorldInitialize(event)
    Config.GetInstance()
end

local function OnServerShutdown(event)
    SaveAllCached()
end

local function OnLuaStateOpen(event)
    local players = GetPlayersInWorld()
    if not players then
        return
    end

    for _, player in pairs(players) do
        OnPlayerLogin(3, player)
    end
end

local function OnLuaStateClose(event)
    local players = GetPlayersInWorld()
    if not players then
        return
    end

    for _, player in pairs(players) do
        OnPlayerLogout(4, player)
    end
end

-- ============================================================================
-- PLAYER COMMANDS (.bp)
-- ============================================================================

local ADMIN_GM_RANK = 2

local function CommandStatus(player)
    local bp = GetPlayerBP(player)
    local config = Config.GetInstance()
    local maxLevel = config:GetMaxLevel()

    player:SendBroadcastMessage("|cff00ff00========== Battle Pass ==========|r")
    player:SendBroadcastMessage(string.format("Level: |cffffd700%d|r / %d",
        bp:GetLevel(), maxLevel))

    if bp:IsMaxLevel() then
        player:SendBroadcastMessage("Experience: |cff00ff00MAX LEVEL|r")
    else
        player:SendBroadcastMessage(string.format("Experience: |cffffd700%d|r / %d (%d%%)",
            bp:GetExperience(), bp:GetExperienceForNextLevel(), bp:GetExperienceProgress()))
    end

    player:SendBroadcastMessage(string.format("Total XP: |cff888888%d|r", bp:GetTotalExp()))

    local unclaimed = bp:CountUnclaimedRewards()
    if unclaimed > 0 then
        player:SendBroadcastMessage(string.format(
            "|cffff8000Available rewards: %d|r", unclaimed))
    end

    player:SendBroadcastMessage("|cff00ff00==================================|r")
end

local function CommandRewards(player)
    local bp = GetPlayerBP(player)
    local rewards = bp:GetAvailableRewards()

    if #rewards == 0 then
        player:SendBroadcastMessage("|cff00ff00[Battle Pass]|r No rewards available.")
        return
    end

    player:SendBroadcastMessage("|cff00ff00===== Available Rewards =====|r")

    for _, reward in ipairs(rewards) do
        player:SendBroadcastMessage("  " .. Reward.FormatDescription(reward))
    end

    player:SendBroadcastMessage("|cff888888Use .bp claim <level> to claim|r")
    player:SendBroadcastMessage("|cff00ff00==================================|r")
end

local function CommandClaim(player, level)
    if not level then
        player:SendBroadcastMessage("|cffff0000[Battle Pass]|r Usage: .bp claim <level>")
        return
    end

    local bp = GetPlayerBP(player)
    local success = Reward.Claim(player, bp, level)
    SendClaimConfirmation(player, level, success)
end

local function CommandClaimAll(player)
    local bp = GetPlayerBP(player)
    local unclaimed = bp:CountUnclaimedRewards()

    if unclaimed == 0 then
        player:SendBroadcastMessage("|cff00ff00[Battle Pass]|r No rewards to claim.")
        return
    end

    Reward.ClaimAll(player, bp)
    FullSync(player, bp)
end

local function CommandPreview(player, startLevel)
    local bp = GetPlayerBP(player)
    local config = Config.GetInstance()
    local maxLevel = config:GetMaxLevel()

    startLevel = startLevel or (bp:GetLevel() + 1)
    local endLevel = math.min(startLevel + 4, maxLevel)

    player:SendBroadcastMessage(string.format(
        "|cff00ff00===== Preview Levels %d-%d =====|r", startLevel, endLevel))

    for level = startLevel, endLevel do
        local levelData = config:GetLevel(level)
        if levelData then
            local status_str = ""

            if level <= bp:GetLevel() then
                if bp:IsLevelClaimed(level) then
                    status_str = " |cff00ff00[Claimed]|r"
                else
                    status_str = " |cffff8000[Available]|r"
                end
            else
                local expRequired = bp:GetExperienceForNextLevel()
                status_str = string.format(" |cff888888(%d XP)|r", levelData.exp_required or expRequired)
            end

            player:SendBroadcastMessage(string.format("  Lvl %d: |cffffd700%s|r%s",
                level, levelData.reward_name, status_str))
        end
    end

    if endLevel < maxLevel then
        player:SendBroadcastMessage(string.format(
            "|cff888888Use .bp preview %d for more|r", endLevel + 1))
    end

    player:SendBroadcastMessage("|cff00ff00==================================|r")
end

local function CommandHelp(player)
    player:SendBroadcastMessage("|cff00ff00===== Battle Pass - Help =====|r")
    player:SendBroadcastMessage("  |cffffd700.bp|r - Show your progression")
    player:SendBroadcastMessage("  |cffffd700.bp rewards|r - List available rewards")
    player:SendBroadcastMessage("  |cffffd700.bp claim <level>|r - Claim a reward")
    player:SendBroadcastMessage("  |cffffd700.bp claimall|r - Claim all rewards")
    player:SendBroadcastMessage("  |cffffd700.bp preview [level]|r - Preview upcoming levels")
    player:SendBroadcastMessage("|cff00ff00==============================|r")
end

-- ============================================================================
-- ADMIN COMMANDS (.bpadmin)
-- ============================================================================

local function AdminAddExp(admin, targetName, amount)
    local target = targetName and GetPlayerByName(targetName) or admin

    if not target then
        admin:SendBroadcastMessage("|cffff0000[BP Admin]|r Player not found: " .. tostring(targetName))
        return
    end

    local bp = GetPlayerBP(target)
    AwardExp(target, bp, amount)

    admin:SendBroadcastMessage(string.format(
        "|cff00ff00[BP Admin]|r Added %d XP to %s", amount, target:GetName()))
end

local function AdminSetLevel(admin, targetName, level)
    local target = targetName and GetPlayerByName(targetName) or admin

    if not target then
        admin:SendBroadcastMessage("|cffff0000[BP Admin]|r Player not found: " .. tostring(targetName))
        return
    end

    local bp = GetPlayerBP(target)
    bp:SetLevel(level):SetExperience(0):Save()

    local repo = Repository.GetInstance()
    repo:SetPlayerLevel(target:GetGUIDLow(), level)

    admin:SendBroadcastMessage(string.format(
        "|cff00ff00[BP Admin]|r Set %s level to %d", target:GetName(), level))

    if target ~= admin then
        target:SendBroadcastMessage(string.format(
            "|cffff8000[Battle Pass]|r Your level has been set to %d by an admin.", level))
    end

    FullSync(target, bp)
end

local function AdminReset(admin, targetName)
    local target = targetName and GetPlayerByName(targetName) or admin

    if not target then
        admin:SendBroadcastMessage("|cffff0000[BP Admin]|r Player not found: " .. tostring(targetName))
        return
    end

    local bp = GetPlayerBP(target)
    bp:Reset():Save()

    admin:SendBroadcastMessage(string.format(
        "|cff00ff00[BP Admin]|r Battle Pass reset for %s", target:GetName()))

    if target ~= admin then
        target:SendBroadcastMessage("|cffff8000[Battle Pass]|r Your Battle Pass has been reset by an admin.")
    end

    FullSync(target, bp)
end

local function AdminUnclaim(admin, targetName, level)
    local target = targetName and GetPlayerByName(targetName) or admin
    if not target then
        admin:SendBroadcastMessage("|cffff0000[BP Admin]|r Player not found: " .. tostring(targetName))
        return
    end

    local bp = GetPlayerBP(target)
    if not bp:IsLevelClaimed(level) then
        admin:SendBroadcastMessage(string.format(
            "|cffff0000[BP Admin]|r %s has not claimed level %d", target:GetName(), level))
        return
    end

    bp:UnclaimLevel(level):Save()
    admin:SendBroadcastMessage(string.format(
        "|cff00ff00[BP Admin]|r Level %d unclaimed for %s", level, target:GetName()))

    if target ~= admin then
        target:SendBroadcastMessage(string.format(
            "|cffff8000[Battle Pass]|r Level %d has been unclaimed by an admin.", level))
    end
    FullSync(target, bp)
end

local function AdminReload(admin)
    local config = Config.GetInstance()
    config:Reload()

    admin:SendBroadcastMessage("|cff00ff00[BP Admin]|r Battle Pass configuration reloaded.")
end

local function AdminStats(admin)
    local config = Config.GetInstance()
    local cachedPlayers = TableCount(PlayerCache)
    local levels = TableCount(config:GetLevels())
    local sources = TableCount(config:GetSources())

    admin:SendBroadcastMessage("|cff00ff00===== Battle Pass Stats =====|r")
    admin:SendBroadcastMessage(string.format("  Tables Exist: %s",
        config:TablesExist() and "Yes" or "No"))
    admin:SendBroadcastMessage(string.format("  Enabled: %s",
        config:IsEnabled() and "Yes" or "No"))
    admin:SendBroadcastMessage(string.format("  Max Level: %d", config:GetMaxLevel()))
    admin:SendBroadcastMessage(string.format("  Levels Defined: %d", levels))
    admin:SendBroadcastMessage(string.format("  Progress Sources: %d", sources))
    admin:SendBroadcastMessage(string.format("  Cached Players: %d", cachedPlayers))
    admin:SendBroadcastMessage("|cff00ff00==============================|r")
end

local function AdminHelp(admin)
    admin:SendBroadcastMessage("|cff00ff00===== BP Admin - Help =====|r")
    admin:SendBroadcastMessage("  |cffffd700.bpadmin addxp <amount> [player]|r")
    admin:SendBroadcastMessage("  |cffffd700.bpadmin setlevel <level> [player]|r")
    admin:SendBroadcastMessage("  |cffffd700.bpadmin unclaim <level> [player]|r")
    admin:SendBroadcastMessage("  |cffffd700.bpadmin reset [player]|r")
    admin:SendBroadcastMessage("  |cffffd700.bpadmin reload|r - Reload config")
    admin:SendBroadcastMessage("  |cffffd700.bpadmin stats|r - System stats")
    admin:SendBroadcastMessage("|cff00ff00============================|r")
end

-- ============================================================================
-- COMMAND ROUTER
-- ============================================================================

local function HandleBPCommand(player, command)
    local config = Config.GetInstance()

    if not config:IsEnabled() then
        player:SendBroadcastMessage("|cffff0000[Battle Pass]|r System is disabled.")
        return
    end

    local args = {}
    for arg in command:gmatch("%S+") do
        table.insert(args, arg)
    end

    if #args == 0 then
        CommandStatus(player)
        return
    end

    local subCmd = args[1]:lower()

    if subCmd == "status" or subCmd == "s" then
        CommandStatus(player)
    elseif subCmd == "rewards" or subCmd == "r" then
        CommandRewards(player)
    elseif subCmd == "claim" or subCmd == "c" then
        CommandClaim(player, tonumber(args[2]))
    elseif subCmd == "claimall" or subCmd == "ca" then
        CommandClaimAll(player)
    elseif subCmd == "preview" or subCmd == "p" then
        CommandPreview(player, tonumber(args[2]))
    elseif subCmd == "help" or subCmd == "h" or subCmd == "?" then
        CommandHelp(player)
    else
        player:SendBroadcastMessage("|cffff0000[Battle Pass]|r Unknown command. Use |cff00ff00.bp help|r")
    end
end

local function HandleBPAdminCommand(player, command)
    if player:GetGMRank() < ADMIN_GM_RANK then
        player:SendBroadcastMessage("|cffff0000[BP Admin]|r Permission denied.")
        return
    end

    local args = {}
    for arg in command:gmatch("%S+") do
        table.insert(args, arg)
    end

    if #args == 0 then
        AdminHelp(player)
        return
    end

    local subCmd = args[1]:lower()

    if subCmd == "addxp" or subCmd == "ax" then
        local amount = tonumber(args[2])
        if not amount then
            player:SendBroadcastMessage("|cffff0000[BP Admin]|r Usage: .bpadmin addxp <amount> [player]")
        else
            AdminAddExp(player, args[3], amount)
        end
    elseif subCmd == "setlevel" or subCmd == "sl" then
        local level = tonumber(args[2])
        if not level then
            player:SendBroadcastMessage("|cffff0000[BP Admin]|r Usage: .bpadmin setlevel <level> [player]")
        else
            AdminSetLevel(player, args[3], level)
        end
    elseif subCmd == "unclaim" or subCmd == "uc" then
        local level = tonumber(args[2])
        if not level then
            player:SendBroadcastMessage("|cffff0000[BP Admin]|r Usage: .bpadmin unclaim <level> [player]")
        else
            AdminUnclaim(player, args[3], level)
        end
    elseif subCmd == "reset" then
        AdminReset(player, args[2])
    elseif subCmd == "reload" or subCmd == "rl" then
        AdminReload(player)
    elseif subCmd == "stats" then
        AdminStats(player)
    elseif subCmd == "help" or subCmd == "h" or subCmd == "?" then
        AdminHelp(player)
    else
        player:SendBroadcastMessage("|cffff0000[BP Admin]|r Unknown command. Use |cff00ff00.bpadmin help|r")
    end
end

local function OnCommand(event, player, command)
    if not command or not player then
        return
    end

    local cmd = command:lower()

    if cmd == "bp" or cmd:match("^bp ") or cmd == "battlepass" or cmd:match("^battlepass ") then
        local args = cmd:gsub("^bp%s*", ""):gsub("^battlepass%s*", "")
        local success, err = pcall(HandleBPCommand, player, args)
        if not success then
            player:SendBroadcastMessage("|cffff0000[Battle Pass]|r Error: " .. tostring(err))
        end
        return false
    end

    if cmd == "bpadmin" or cmd:match("^bpadmin ") then
        local args = cmd:gsub("^bpadmin%s*", "")
        local success, err = pcall(HandleBPAdminCommand, player, args)
        if not success then
            player:SendBroadcastMessage("|cffff0000[BP Admin]|r Error: " .. tostring(err))
        end
        return false
    end
end

-- ============================================================================
-- EVENT REGISTRATION
-- ============================================================================

-- Player Events
RegisterPlayerEvent(3, OnPlayerLogin)       -- PLAYER_EVENT_ON_LOGIN
RegisterPlayerEvent(4, OnPlayerLogout)      -- PLAYER_EVENT_ON_LOGOUT
RegisterPlayerEvent(6, OnHonorableKill)     -- PLAYER_EVENT_ON_KILL_PLAYER
RegisterPlayerEvent(7, OnCreatureKill)      -- PLAYER_EVENT_ON_KILL_CREATURE
RegisterPlayerEvent(13, OnPlayerLevelChange) -- PLAYER_EVENT_ON_LEVEL_CHANGE
RegisterPlayerEvent(42, OnCommand)          -- PLAYER_EVENT_ON_COMMAND
RegisterPlayerEvent(54, OnQuestComplete)    -- PLAYER_EVENT_ON_QUEST_COMPLETE

-- Server Events
RegisterServerEvent(14, OnWorldInitialize)  -- WORLD_EVENT_ON_STARTUP
RegisterServerEvent(15, OnServerShutdown)   -- WORLD_EVENT_ON_SHUTDOWN
RegisterServerEvent(16, OnLuaStateClose)    -- SERVER_EVENT_ON_LUA_STATE_CLOSE
RegisterServerEvent(33, OnLuaStateOpen)     -- SERVER_EVENT_ON_LUA_STATE_OPEN

-- Battleground Events
RegisterBGEvent(2, OnBattlegroundEnd)       -- BG_EVENT_ON_END

-- CSMH Client Request Handlers
RegisterClientRequests(CSMHConfig)
