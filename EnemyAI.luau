--!strict

-- enemy ai system with pathfinding and obstacle avoidance
-- enemies can jump over small obstacles or walk around big walls

local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

local EnemyAI = {}

local AIState = {
	Idle = "Idle",
	Chasing = "Chasing",
	Attacking = "Attacking",
	Returning = "Returning",
}

export type EnemyAIData = {
	enemy: Model,
	config: any,
	currentState: string,
	target: Player?,
	spawnPosition: Vector3,
	lastAttackTime: number,
	path: Path?,
	pathUpdateTime: number,
	lastPosition: Vector3?,
	stuckTime: number,
	lastJumpTime: number,
	failedPathAttempts: number,
	wallFollowDirection: number?,
	lastDetectionTime: number,
	currentStrategy: string?,
	lastDistanceToPlayer: number?,
	healthConnection: RBXScriptConnection?,
	aiConnection: RBXScriptConnection?,
}

local activeAIs: {[Model]: EnemyAIData} = {}

-- finds closest alive player within range
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

-- checks if theres a clear path between two points (used for wall detection)
local function hasLineOfSight(fromPosition: Vector3, toPosition: Vector3, ignoreModel: Model): boolean
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {ignoreModel}
	
	local direction = (toPosition - fromPosition)
	local ray = workspace:Raycast(fromPosition, direction, rayParams)
	
	-- no hit or hit terrain = we can see player
	return ray == nil or ray.Instance:IsA("Terrain") == false
end

-- detects if enemy hasnt moved much and is stuck
local function isEnemyStuck(aiData: EnemyAIData, currentPosition: Vector3): boolean
	local currentTime = tick()
	
	if not aiData.lastPosition then
		aiData.lastPosition = currentPosition
		aiData.stuckTime = currentTime
		return false
	end
	
	local distance = (currentPosition - aiData.lastPosition).Magnitude
	
	if distance < 1 then
		-- stuck for more than 2 seconds
		if (currentTime - aiData.stuckTime) > 2 then
			return true
		end
	else
		aiData.lastPosition = currentPosition
		aiData.stuckTime = currentTime
	end
	
	return false
end

-- main movement logic with obstacle detection and avoidance strategies
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
	
	-- track progress
	if not aiData.lastPosition then
		aiData.lastPosition = currentPosition
		aiData.lastDistanceToPlayer = distanceToPlayer
	end
	
	-- check if currently committed to a movement strategy
	-- this prevents the ai from flip-flopping between strategies
	local commitTime = 5
	if aiData.currentStrategy == "goaround" then
		commitTime = 20 -- need longer time to walk around big walls
	end
	
	local isCommitted = aiData.currentStrategy and (currentTime - aiData.lastDetectionTime) < commitTime
	
	if isCommitted then
		-- executing committed strategy, dont check for new obstacles
		
		if aiData.currentStrategy == "jump" then
			-- keep moving forward and jumping over small obstacles
			humanoid:MoveTo(targetPosition)
			if (currentTime - aiData.lastJumpTime) > 1.2 then
				humanoid.Jump = true
				aiData.lastJumpTime = currentTime
			end
			
		elseif aiData.currentStrategy == "goaround" then
			-- move far perpendicular to wall until we have line of sight again
			local perpendicular = Vector3.new(-direction.Z, 0, direction.X) * aiData.wallFollowDirection
			local targetSidePosition = currentPosition + perpendicular * 15
			humanoid:MoveTo(targetSidePosition)
			
			-- check if we cleared the wall
			if hasLineOfSight(currentPosition, targetPosition, enemy) then
				aiData.currentStrategy = nil
				aiData.lastPosition = currentPosition
			end
		end
		
		return
	end
	
	-- not committed - check if making progress toward player
	local timeSinceCheck = currentTime - aiData.stuckTime
	
	if timeSinceCheck > 0.5 then
		local moved = (currentPosition - aiData.lastPosition).Magnitude
		local distanceChange = aiData.lastDistanceToPlayer - distanceToPlayer
		
		aiData.lastPosition = currentPosition
		aiData.lastDistanceToPlayer = distanceToPlayer
		aiData.stuckTime = currentTime
		
		-- not making progress = something blocking us
		if moved < 1 or distanceChange < 0.5 then
			
			-- raycast to see whats in front
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
				
				-- small obstacle = jump over it
				if obstacleHeight < 5 then
					aiData.currentStrategy = "jump"
					aiData.lastDetectionTime = currentTime
					aiData.lastJumpTime = currentTime
					humanoid.Jump = true
					humanoid:MoveTo(targetPosition)
					
				else
					-- big wall = walk around it
					-- calculate which side is shorter
					local perpLeft = Vector3.new(-direction.Z, 0, direction.X)
					local perpRight = Vector3.new(direction.Z, 0, -direction.X)
					
					local leftPoint = currentPosition + perpLeft * (obstacleWidth / 2 + 3)
					local rightPoint = currentPosition + perpRight * (obstacleWidth / 2 + 3)
					
					local leftDist = (targetPosition - leftPoint).Magnitude
					local rightDist = (targetPosition - rightPoint).Magnitude
					
					-- pick the shorter path
					aiData.wallFollowDirection = leftDist < rightDist and 1 or -1
					
					aiData.currentStrategy = "goaround"
					aiData.lastDetectionTime = currentTime
				end
			else
				-- no obstacle detected but still stuck, just jump
				if (currentTime - aiData.lastJumpTime) > 2 then
					humanoid.Jump = true
					aiData.lastJumpTime = currentTime
				end
			end
		end
	end
	
	-- default behavior
	humanoid:MoveTo(targetPosition)
end

-- updates ai state machine each frame
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
	
	-- state machine
	if aiData.currentState == AIState.Idle then
		-- look for players
		local nearestPlayer = findNearestPlayer(currentPosition, config.chaseRange)
		
		if nearestPlayer then
			aiData.target = nearestPlayer
			aiData.currentState = AIState.Chasing
		end
		
	elseif aiData.currentState == AIState.Chasing then
		-- chase target
		if not aiData.target or not aiData.target.Character then
			aiData.target = nil
			aiData.currentState = AIState.Idle
			return
		end
		
		-- check if target is still alive
		local targetHumanoid = aiData.target.Character:FindFirstChildOfClass("Humanoid")
		if not targetHumanoid or targetHumanoid.Health <= 0 then
			aiData.target = nil
			aiData.currentState = AIState.Idle
			return
		end
		
		local targetHrp = aiData.target.Character:FindFirstChild("HumanoidRootPart") :: Part?
		if not targetHrp then
			aiData.target = nil
			aiData.currentState = AIState.Idle
			return
		end
		
		local targetPosition = targetHrp.Position
		local distance = (targetPosition - currentPosition).Magnitude
		
		-- close enough to attack
		if distance <= config.attackRange then
			aiData.currentState = AIState.Attacking
			humanoid:MoveTo(currentPosition)
		-- player escaped
		elseif distance > config.chaseRange * 1.5 then
			aiData.target = nil
			aiData.currentState = AIState.Returning
		else
			-- keep chasing
			moveToTarget(aiData, targetPosition)
		end
		
	elseif aiData.currentState == AIState.Attacking then
		-- attack target
		if not aiData.target or not aiData.target.Character then
			aiData.target = nil
			aiData.currentState = AIState.Idle
			return
		end
		
		local targetHumanoid = aiData.target.Character:FindFirstChildOfClass("Humanoid")
		if not targetHumanoid or targetHumanoid.Health <= 0 then
			aiData.target = nil
			aiData.currentState = AIState.Idle
			return
		end
		
		local targetHrp = aiData.target.Character:FindFirstChild("HumanoidRootPart") :: Part?
		if not targetHrp then
			aiData.target = nil
			aiData.currentState = AIState.Idle
			return
		end
		
		local targetPosition = targetHrp.Position
		local distance = (targetPosition - currentPosition).Magnitude
		
		-- face the target
		hrp.CFrame = CFrame.new(currentPosition, Vector3.new(targetPosition.X, currentPosition.Y, targetPosition.Z))
		
		-- target moved out of range
		if distance > config.attackRange * 1.2 then
			aiData.currentState = AIState.Chasing
		else
			-- attack if cooldown ready
			local currentTime = tick()
			if (currentTime - aiData.lastAttackTime) >= config.attackCooldown then
				aiData.lastAttackTime = currentTime
				
				-- set attribute for enemyservice to handle
				enemy:SetAttribute("AttackTarget", aiData.target.Name)
			end
		end
		
	elseif aiData.currentState == AIState.Returning then
		-- return to spawn point
		local distance = (aiData.spawnPosition - currentPosition).Magnitude
		
		if distance < 5 then
			aiData.currentState = AIState.Idle
			humanoid:MoveTo(currentPosition)
		else
			moveToTarget(aiData, aiData.spawnPosition)
		end
	end
end

-- starts ai for an enemy
function EnemyAI.StartAI(enemy: Model, config: any, spawnPosition: Vector3)
	if activeAIs[enemy] then
		warn(`ai already active for {enemy.Name}`)
		return
	end
	
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
	
	-- ai update loop runs at 10hz
	aiData.aiConnection = RunService.Heartbeat:Connect(function()
		-- throttle to ~10 updates per second for performance
		if tick() % 0.1 < 0.016 then
			updateAI(aiData)
		end
	end)
end

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

function EnemyAI.ResetAI(enemy: Model)
	local aiData = activeAIs[enemy]
	if not aiData then
		return
	end
	
	-- clear target and reset state
	aiData.target = nil
	aiData.currentState = AIState.Idle
	aiData.lastAttackTime = 0
	aiData.currentStrategy = nil
	aiData.wallFollowDirection = nil
	
	-- move back to spawn
	local hrp = enemy:FindFirstChild("HumanoidRootPart") :: Part?
	if hrp then
		hrp.CFrame = CFrame.new(aiData.spawnPosition)
	end
end

function EnemyAI.GetAIData(enemy: Model): EnemyAIData?
	return activeAIs[enemy]
end

function EnemyAI.CleanupAll()
	for enemy, aiData in activeAIs do
		EnemyAI.StopAI(enemy)
	end
end

return EnemyAI

