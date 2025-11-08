--!strict

--[[
	Enemy AI system with pathfinding and obstacle avoidance
	
	Enemies use a state machine to control behavior
	When chasing they detect obstacles with raycasting
	and choose strategies based on obstacle size
]]

local PathfindingService = game:GetService("PathfindingService") -- used for complex pathfinding but we use custom movement here
local RunService = game:GetService("RunService") -- needed for heartbeat connection to run ai updates

local EnemyAI = {}

-- state machine to control enemy behavior
local AIState = {
	Idle = "Idle", -- enemy waiting at spawn
	Chasing = "Chasing", -- enemy pursuing player
	Attacking = "Attacking", -- enemy in range and attacking
	Returning = "Returning", -- enemy going back to spawn
}

-- stores all data needed for individual enemy ai
export type EnemyAIData = {
	enemy: Model, -- reference to the enemy model
	config: any, -- enemy config from enemytypes
	currentState: string, -- current state from aistate enum
	target: Player?, -- player being chased or attacked
	spawnPosition: Vector3, -- where enemy spawns and returns to
	lastAttackTime: number, -- tick timestamp of last attack
	path: Path?, -- pathfinding path object if using pathfinding
	pathUpdateTime: number, -- when path was last recalculated
	lastPosition: Vector3?, -- position from previous frame for stuck detection
	stuckTime: number, -- timestamp when stuck detection started
	lastJumpTime: number, -- timestamp of last jump to prevent spam
	failedPathAttempts: number, -- counts failed pathfinding attempts
	wallFollowDirection: number?, -- 1 or negative 1 for left or right wall follow
	lastDetectionTime: number, -- when obstacle was detected for strategy commitment
	currentStrategy: string?, -- jump or goaround strategy
	lastDistanceToPlayer: number?, -- previous distance to check if getting closer
	healthConnection: RBXScriptConnection?, -- connection to health changed event
	aiConnection: RBXScriptConnection?, -- connection to heartbeat for ai loop
}

local activeAIs: {[Model]: EnemyAIData} = {} -- dictionary of all active enemy ai instances

--[[
	Searches for the nearest alive player within detection range
	
	Used by idle enemies to find initial targets and by returning
	enemies to check if any players are still nearby
]]
local function findNearestPlayer(position: Vector3, range: number): Player?
	local nearestPlayer: Player? = nil
	local nearestDistance = range
	
	for _, player in game:GetService("Players"):GetPlayers() do
		if player.Character then
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			local hrp = player.Character:FindFirstChild("HumanoidRootPart") :: Part?
			
			if humanoid and hrp and humanoid.Health > 0 then
				local distance = (hrp.Position - position).Magnitude
				if distance < nearestDistance then
					nearestPlayer = player
					nearestDistance = distance
				end
			end
		end
	end
	
	return nearestPlayer
end

--[[
	Checks if enemy can see target without obstacles blocking view
	
	Used by wall follow strategy to detect when enemy cleared the
	obstacle and can resume direct chase
]]
local function hasLineOfSight(
	fromPosition: Vector3, -- enemy position
	toPosition: Vector3, -- target position
	ignoreModel: Model -- enemy model to ignore in raycast
): boolean
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {ignoreModel}
	
	local direction = (toPosition - fromPosition)
	local ray = workspace:Raycast(fromPosition, direction, rayParams)
	
	return ray == nil or ray.Instance:IsA("Terrain") == false
end

--[[
	Compares current position to previous position to detect if enemy
	is stuck
	
	Prevents enemies from getting permanently stuck on geometry by
	triggering obstacle avoidance when movement stops
]]
local function isEnemyStuck(aiData: EnemyAIData, currentPosition: Vector3): boolean
	local currentTime = tick()
	
	if not aiData.lastPosition then
		aiData.lastPosition = currentPosition
		aiData.stuckTime = currentTime
		return false
	end
	
	local distance = (currentPosition - aiData.lastPosition).Magnitude
	
	if distance < 1 then
		if (currentTime - aiData.stuckTime) > 2 then
			return true
		end
	else
		aiData.lastPosition = currentPosition
		aiData.stuckTime = currentTime
	end
	
	return false
end

--[[
	Handles advanced movement with obstacle detection and avoidance
	
	Enemies commit to strategies for several seconds to prevent
	constantly switching between jump and wall follow which looks
	unnatural and wastes performance on recalculations
	
	Uses raycasting to detect obstacles ahead then chooses strategy
	based on obstacle height, jump for low obstacles or wall follow
	for tall ones
]]
local function moveToTarget(aiData: EnemyAIData, targetPosition: Vector3)
	local enemy = aiData.enemy
	local humanoid = enemy:FindFirstChildOfClass("Humanoid")
	local hrp = enemy:FindFirstChild("HumanoidRootPart") :: Part?
	
	if not humanoid or not hrp then
		return
	end
	
	local currentPosition = hrp.Position
	local currentTime = tick()
	local direction = (targetPosition - currentPosition)
	local distanceToPlayer = direction.Magnitude
	direction = direction.Unit
	
	if not aiData.lastPosition then
		aiData.lastPosition = currentPosition
		aiData.lastDistanceToPlayer = distanceToPlayer
	end
	
	local commitTime = 5
	if aiData.currentStrategy == "goaround" then
		commitTime = 20
	end
	
	local isCommitted = aiData.currentStrategy
		and (currentTime - aiData.lastDetectionTime) < commitTime
	
	if isCommitted then
		if aiData.currentStrategy == "jump" then
			humanoid:MoveTo(targetPosition)
			if (currentTime - aiData.lastJumpTime) > 1.2 then
				humanoid.Jump = true
				aiData.lastJumpTime = currentTime
			end
			
		elseif aiData.currentStrategy == "goaround" then
			local perpendicular = Vector3.new(-direction.Z, 0, direction.X)
			perpendicular = perpendicular * aiData.wallFollowDirection
			local targetSidePosition = currentPosition + perpendicular * 15
			humanoid:MoveTo(targetSidePosition)
			
			if hasLineOfSight(currentPosition, targetPosition, enemy) then
				aiData.currentStrategy = nil
				aiData.lastPosition = currentPosition
			end
		end
		
		return
	end
	
	local timeSinceCheck = currentTime - aiData.stuckTime
	
	if timeSinceCheck > 0.5 then
		local moved = (currentPosition - aiData.lastPosition).Magnitude
		local distanceChange = aiData.lastDistanceToPlayer - distanceToPlayer
		
		aiData.lastPosition = currentPosition
		aiData.lastDistanceToPlayer = distanceToPlayer
		aiData.stuckTime = currentTime
		
		if moved < 1 or distanceChange < 0.5 then
			local rayParams = RaycastParams.new()
			rayParams.FilterDescendantsInstances = {enemy}
			
			local ray = workspace:Raycast(
				currentPosition + Vector3.new(0, 2, 0),
				direction * 6,
				rayParams
			)
			
			if ray and ray.Instance then
				local obstacle = ray.Instance
				local obstacleSize = obstacle.Size
				local obstacleHeight = obstacleSize.Y
				local obstacleWidth = math.max(obstacleSize.X, obstacleSize.Z)
				
				if obstacleHeight < 5 then
					aiData.currentStrategy = "jump"
					aiData.lastDetectionTime = currentTime
					aiData.lastJumpTime = currentTime
					humanoid.Jump = true
					humanoid:MoveTo(targetPosition)
					
				else
					local perpLeft = Vector3.new(-direction.Z, 0, direction.X)
					local perpRight = Vector3.new(direction.Z, 0, -direction.X)
					
					local leftPoint = currentPosition
						+ perpLeft * (obstacleWidth / 2 + 3)
					local rightPoint = currentPosition
						+ perpRight * (obstacleWidth / 2 + 3)
					
					local leftDist = (targetPosition - leftPoint).Magnitude
					local rightDist = (targetPosition - rightPoint).Magnitude
					
					aiData.wallFollowDirection = if leftDist < rightDist
						then 1
						else -1
					
					aiData.currentStrategy = "goaround"
					aiData.lastDetectionTime = currentTime
				end
			else
				if (currentTime - aiData.lastJumpTime) > 2 then
					humanoid.Jump = true
					aiData.lastJumpTime = currentTime
				end
			end
		end
	end
	
	humanoid:MoveTo(targetPosition)
end

--[[
	Executes state machine logic for enemy behavior
	
	Runs periodically via heartbeat connection to update enemy state
	and handle transitions between idle, chasing, attacking and
	returning based on player proximity and health
]]
local function updateAI(aiData: EnemyAIData)
	local enemy = aiData.enemy
	local config = aiData.config
	local humanoid = enemy:FindFirstChildOfClass("Humanoid")
	local hrp = enemy:FindFirstChild("HumanoidRootPart") :: Part?
	
	if not humanoid or not hrp or humanoid.Health <= 0 then
		return
	end
	
	humanoid.WalkSpeed = config.speed
	
	local currentPosition = hrp.Position
	
	if aiData.currentState == AIState.Idle then
		local nearestPlayer = findNearestPlayer(
			currentPosition,
			config.chaseRange
		)
		
		if nearestPlayer then
			aiData.target = nearestPlayer
			aiData.currentState = AIState.Chasing
		end
		
	elseif aiData.currentState == AIState.Chasing then
		if not aiData.target or not aiData.target.Character then
			aiData.target = nil
			aiData.currentState = AIState.Idle
			return
		end
		
		local targetHumanoid = aiData.target.Character:FindFirstChildOfClass(
			"Humanoid"
		)
		if not targetHumanoid or targetHumanoid.Health <= 0 then
			aiData.target = nil
			aiData.currentState = AIState.Idle
			return
		end
		
		local targetHrp = aiData.target.Character:FindFirstChild(
			"HumanoidRootPart"
		) :: Part?
		if not targetHrp then
			aiData.target = nil
			aiData.currentState = AIState.Idle
			return
		end
		
		local targetPosition = targetHrp.Position
		local distance = (targetPosition - currentPosition).Magnitude
		
		if distance <= config.attackRange then
			aiData.currentState = AIState.Attacking
			humanoid:MoveTo(currentPosition)
		elseif distance > config.chaseRange * 1.5 then
			aiData.target = nil
			aiData.currentState = AIState.Returning
		else
			moveToTarget(aiData, targetPosition)
		end
		
	elseif aiData.currentState == AIState.Attacking then
		if not aiData.target or not aiData.target.Character then
			aiData.target = nil
			aiData.currentState = AIState.Idle
			return
		end
		
		local targetHumanoid = aiData.target.Character:FindFirstChildOfClass(
			"Humanoid"
		)
		if not targetHumanoid or targetHumanoid.Health <= 0 then
			aiData.target = nil
			aiData.currentState = AIState.Idle
			return
		end
		
		local targetHrp = aiData.target.Character:FindFirstChild(
			"HumanoidRootPart"
		) :: Part?
		if not targetHrp then
			aiData.target = nil
			aiData.currentState = AIState.Idle
			return
		end
		
		local targetPosition = targetHrp.Position
		local distance = (targetPosition - currentPosition).Magnitude
		
		hrp.CFrame = CFrame.new(
			currentPosition,
			Vector3.new(targetPosition.X, currentPosition.Y, targetPosition.Z)
		)
		
		if distance > config.attackRange * 1.2 then
			aiData.currentState = AIState.Chasing
		else
			local currentTime = tick()
			if (currentTime - aiData.lastAttackTime) >= config.attackCooldown then
				aiData.lastAttackTime = currentTime
				
				enemy:SetAttribute("AttackTarget", aiData.target.Name)
			end
		end
		
	elseif aiData.currentState == AIState.Returning then
		local distance = (aiData.spawnPosition - currentPosition).Magnitude
		
		if distance < 5 then
			aiData.currentState = AIState.Idle
			humanoid:MoveTo(currentPosition)
		else
			moveToTarget(aiData, aiData.spawnPosition)
		end
	end
end

--[[
	Initializes AI system for a newly spawned enemy
	
	Creates AI data structure with all necessary state tracking and
	connects to heartbeat for periodic updates, prevents duplicate AI
	by checking if enemy already has active AI
]]
function EnemyAI.StartAI(enemy: Model, config: any, spawnPosition: Vector3)
	if activeAIs[enemy] then
		warn(`ai already active for {enemy.Name}`)
		return
	end
	
	-- initialize ai data with default values
	local aiData: EnemyAIData = {
		enemy = enemy,
		config = config,
		currentState = AIState.Idle,
		target = nil,
		spawnPosition = spawnPosition,
		lastAttackTime = 0,
		path = nil,
		pathUpdateTime = 0,
		lastPosition = nil,
		stuckTime = 0,
		lastJumpTime = 0,
		failedPathAttempts = 0,
		wallFollowDirection = nil,
		lastDetectionTime = 0,
		currentStrategy = nil,
		lastDistanceToPlayer = nil,
		healthConnection = nil,
		aiConnection = nil,
	}
	
	activeAIs[enemy] = aiData
	
	-- connect to heartbeat to run ai updates
	aiData.aiConnection = RunService.Heartbeat:Connect(function()
		if tick() % 0.1 < 0.016 then
			updateAI(aiData)
		end
	end)
end

--[[
	Stops AI system for an enemy and cleans up connections
	
	Called when enemy dies or is removed to prevent memory leaks from
	dangling connections
]]
function EnemyAI.StopAI(enemy: Model)
	local aiData = activeAIs[enemy]
	if not aiData then
		return
	end
	
	if aiData.aiConnection then
		aiData.aiConnection:Disconnect()
	end
	
	activeAIs[enemy] = nil
end

--[[
	Resets enemy to spawn position and clears combat state
	
	Used when enemy needs to be reset without destroying and
	recreating the entire AI system
]]
function EnemyAI.ResetAI(enemy: Model)
	local aiData = activeAIs[enemy]
	if not aiData then
		return
	end
	
	aiData.target = nil
	aiData.currentState = AIState.Idle
	aiData.lastAttackTime = 0
	aiData.currentStrategy = nil
	aiData.wallFollowDirection = nil
	
	local hrp = enemy:FindFirstChild("HumanoidRootPart") :: Part?
	if hrp then
		hrp.CFrame = CFrame.new(aiData.spawnPosition)
	end
end

--[[
	Retrieves AI data structure for debugging or external control
	
	Allows other systems to check enemy state or modify behavior
	without direct access to internal activeAIs table
]]
function EnemyAI.GetAIData(enemy: Model): EnemyAIData?
	return activeAIs[enemy]
end

--[[
	Stops all active enemy AI systems for server shutdown
	
	Prevents errors from AI trying to update after game resources are
	cleaned up
]]
function EnemyAI.CleanupAll()
	for enemy, aiData in activeAIs do
		EnemyAI.StopAI(enemy)
	end
end

return EnemyAI
