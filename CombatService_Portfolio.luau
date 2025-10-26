--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local HealthService = require(ServerScriptService.Server.HealthService)
local Signal = require(ReplicatedStorage.Shared.Signal)

local CombatService = {}

local HIT_DETECTION_RANGE = 10
local ATTACK_COOLDOWN = 1
local HIT_DEBOUNCE_TIME = 0.5

CombatService.PlayerHit = Signal.new()

local lastAttackTime: {[Player]: number} = {}
local hitDebounce: {[string]: number} = {}

local function canAttack(player: Player): boolean
	local lastAttack = lastAttackTime[player] or 0
	return tick() - lastAttack >= ATTACK_COOLDOWN
end

local function getToolDamage(tool: Tool): number
	local damage = tool:GetAttribute("Damage")
	return damage or 10
end

--[[
	Validates if a target can be attacked by checking:
	- Enemy vs Player distinction
	- Humanoid existence and health status
	- Self-attack prevention
	
	Returns: isValid, targetPlayer (if player), isEnemy
]]
local function isValidTarget(attacker: Player, targetCharacter: Model): (boolean, Player?, boolean)
	local isEnemy = targetCharacter:GetAttribute("IsEnemy") == true
	
	if isEnemy then
		local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			return false, nil, false
		end
		return true, nil, true
	end
	
	local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
	if targetPlayer == attacker then
		return false, nil, false
	end
	
	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false, nil, false
	end
	
	-- double check with health service since humanoid health can desync
	if targetPlayer and HealthService.IsDead(targetPlayer) then
		return false, nil, false
	end
	
	return true, targetPlayer, false
end

--[[
	Prevents the same target from being hit multiple times in quick succession
	Uses a composite key of attacker + victim to track individual hit pairs
]]
local function checkHitDebounce(attacker: Player, victim: Player): boolean
	local key = `{attacker.UserId}_{victim and victim.UserId or "npc"}`
	local lastHit = hitDebounce[key] or 0
	
	if tick() - lastHit < HIT_DEBOUNCE_TIME then
		return false
	end
	
	hitDebounce[key] = tick()
	return true
end

--[[
	Performs a single raycast from the character's forward direction
	More precise but can miss targets at edges of weapon swing
	Good for spears, swords with thrust attacks
]]
function CombatService.RaycastHit(attacker: Player, tool: Tool): {Model}
	local character = attacker.Character
	if not character then
		return {}
	end
	
	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart") :: Part?
	if not humanoidRootPart then
		return {}
	end
	
	local origin = humanoidRootPart.Position
	local direction = humanoidRootPart.CFrame.LookVector * HIT_DETECTION_RANGE
	
	local raycastParams = RaycastParams.new()
	raycastParams.FilterDescendantsInstances = {character}
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	
	local result = workspace:Raycast(origin, direction, raycastParams)
	
	if result and result.Instance then
		local hitCharacter = result.Instance:FindFirstAncestorOfClass("Model")
		if hitCharacter then
			return {hitCharacter}
		end
	end
	
	return {}
end

--[[
	Creates a 3D region in front of the attacker to detect hits
	Better for wide swinging weapons like axes and hammers
	Returns all unique characters found in the region
]]
function CombatService.RegionHit(attacker: Player, tool: Tool): {Model}
	local character = attacker.Character
	if not character then
		return {}
	end
	
	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart") :: Part?
	if not humanoidRootPart then
		return {}
	end
	
	-- region positioned in front of character
	local cf = humanoidRootPart.CFrame
	local size = Vector3.new(4, 6, HIT_DETECTION_RANGE)
	local offset = cf.LookVector * (HIT_DETECTION_RANGE / 2)
	local position = humanoidRootPart.Position + offset
	
	local region = Region3.new(position - size/2, position + size/2)
	region = region:ExpandToGrid(4)
	
	local parts = workspace:FindPartsInRegion3(region, character, 100)
	
	-- deduplicate characters since we get individual parts
	local hitCharacters: {Model} = {}
	local addedCharacters: {[Model]: boolean} = {}
	
	for _, part in parts do
		local hitCharacter = part:FindFirstAncestorOfClass("Model")
		if hitCharacter and not addedCharacters[hitCharacter] then
			local humanoid = hitCharacter:FindFirstChildOfClass("Humanoid")
			if humanoid then
				addedCharacters[hitCharacter] = true
				table.insert(hitCharacters, hitCharacter)
			end
		end
	end
	
	return hitCharacters
end

--[[
	Main attack handler that processes damage, applies stat multipliers,
	and routes damage to either enemies or players
	Uses region detection by default for better game feel
]]
function CombatService.HandleAttack(attacker: Player, tool: Tool)
	if not canAttack(attacker) then
		return
	end
	
	lastAttackTime[attacker] = tick()
	
	local baseDamage = getToolDamage(tool)
	
	-- apply strength stat scaling
	local StatsService = require(script.Parent.StatsService)
	local damageMultiplier = StatsService.GetDamageMultiplier(attacker)
	local finalDamage = math.floor(baseDamage * damageMultiplier)
	
	local hitCharacters = CombatService.RegionHit(attacker, tool)
	
	for _, hitCharacter in hitCharacters do
		local isValid, victim, isEnemyTarget = isValidTarget(attacker, hitCharacter)
		
		if isValid then
			if isEnemyTarget then
				local EnemyService = require(script.Parent.EnemyService)
				EnemyService.DamageEnemy(hitCharacter, finalDamage, attacker)
			else
				-- prevent spam hitting same player
				if victim and not checkHitDebounce(attacker, victim) then
					continue
				end
				
				if victim then
					local success = HealthService.DealDamage(victim, finalDamage, attacker)
					if success then
						CombatService.PlayerHit:Fire(attacker, victim, finalDamage, tool)
					end
				end
			end
		end
	end
end

function CombatService.InitializePlayer(player: Player)
	lastAttackTime[player] = 0
end

function CombatService.CleanupPlayer(player: Player)
	lastAttackTime[player] = nil
	
	-- clean up all debounce entries involving this player
	local prefix = `{player.UserId}_`
	for key in hitDebounce do
		if key:sub(1, #prefix) == prefix then
			hitDebounce[key] = nil
		end
	end
end

return CombatService

