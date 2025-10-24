--!strict
-- EnemyAI.luau
-- ai behavior for enemies - pathfinding, chasing, attacking made by lacocaim

local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

local EnemyAI = {}

-- ai state enum
local AIState = {
	Idle = "Idle",
	Chasing = "Chasing",
	Attacking = "Attacking",
	Returning = "Returning",
}

-- enemy ai data structure
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
	currentStrategy: string?, -- "jump" or "goaround"
	lastDistanceToPlayer: number?,
	healthConnection: RBXScriptConnection?,
	aiConnection: RBXScriptConnection?,
}

local activeAIs: {[Model]: EnemyAIData} = {}

-- find nearest player within range
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

-- check if enemy has line of sight to target
local function hasLineOfSight(fromPosition: Vector3, toPosition: Vector3, ignoreModel: Model): boolean
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {ignoreModel}
	
	local direction = (toPosition - fromPosition)
	local ray = workspace:Raycast(fromPosition, direction, rayParams)
	
	-- if no hit, or hit something that's not a wall, we have line of sight
	return ray == nil or ray.Instance:IsA("Terrain") == false
end

-- detect if enemy is stuck
local function isEnemyStuck(aiData: EnemyAIData, currentPosition: Vector3): boolean
	local currentTime = tick()
	
	-- initialize last position if not set
	if not aiData.lastPosition then
		aiData.lastPosition = currentPosition
		aiData.stuckTime = currentTime
		return false
	end
	
	-- check if enemy has moved significantly
	local distance = (currentPosition - aiData.lastPosition).Magnitude
	
	if distance < 1 then -- hasn't moved much
		-- check if stuck for too long
		if (currentTime - aiData.stuckTime) > 2 then
			return true
		end
	else
		-- reset stuck timer if moving
		aiData.lastPosition = currentPosition
		aiData.stuckTime = currentTime
	end
	
	return false
end

-- check progress and react appropriately
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
	
	-- track last distance to see if making progress
	if not aiData.lastPosition then
		aiData.lastPosition = currentPosition
		aiData.lastDistanceToPlayer = distanceToPlayer
	end
	
	-- check if we're committed to a strategy
	local commitTime = 5 -- default 5 seconds for jumping
	if aiData.currentStrategy == "goaround" then
		commitTime = 20 -- 20 SECONDS for going around big walls!
	end
	
	local isCommitted = aiData.currentStrategy and (currentTime - aiData.lastDetectionTime) < commitTime
	
	if isCommitted then
		-- EXECUTING COMMITTED STRATEGY
		
		if aiData.currentStrategy == "jump" then
			-- jump strategy - keep running forward and jumping (5 second commitment)
			humanoid:MoveTo(targetPosition)
			if (currentTime - aiData.lastJumpTime) > 1.2 then
				humanoid.Jump = true
				aiData.lastJumpTime = currentTime
			end
			
		elseif aiData.currentStrategy == "goaround" then
			-- go around strategy - move FAR perpendicular until clear (20 second commitment!)
			local perpendicular = Vector3.new(-direction.Z, 0, direction.X) * aiData.wallFollowDirection
			local targetSidePosition = currentPosition + perpendicular * 15 -- go MUCH farther!
			humanoid:MoveTo(targetSidePosition)
			
			-- check if we've cleared the wall
			if hasLineOfSight(currentPosition, targetPosition, enemy) then
				print(`{enemy.Name} cleared the big wall! Resuming chase`)
				aiData.currentStrategy = nil
				aiData.lastPosition = currentPosition
			end
		end
		
		return -- don't check obstacles while committed
	end
	
	-- NOT COMMITTED - check if making progress
	local timeSinceCheck = currentTime - aiData.stuckTime
	
	if timeSinceCheck > 0.5 then -- check every 0.5 seconds
		local moved = (currentPosition - aiData.lastPosition).Magnitude
		local distanceChange = aiData.lastDistanceToPlayer - distanceToPlayer
		
		-- update tracking
		aiData.lastPosition = currentPosition
		aiData.lastDistanceToPlayer = distanceToPlayer
		aiData.stuckTime = currentTime
		
		-- check if NOT making progress (moved less than 1 stud or not getting closer)
		if moved < 1 or distanceChange < 0.5 then
			-- NOT MAKING PROGRESS - something is blocking us
			
			-- raycast to find what's in front
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
				
				print(`{enemy.Name} hit obstacle: {obstacle.Name}, Height: {obstacleHeight}, Width: {obstacleWidth}`)
				
				if obstacleHeight < 5 then
					-- SMALL WALL - JUMP!
					print(`{enemy.Name} jumping over small wall!`)
					aiData.currentStrategy = "jump"
					aiData.lastDetectionTime = currentTime
					aiData.lastJumpTime = currentTime
					humanoid.Jump = true
					humanoid:MoveTo(targetPosition)
					
				else
					-- BIG WALL - GO AROUND!
					-- calculate which direction to go (perpendicular to forward direction)
					local perpLeft = Vector3.new(-direction.Z, 0, direction.X)
					local perpRight = Vector3.new(direction.Z, 0, -direction.X)
					
					-- check both sides to see which is faster
					local leftPoint = currentPosition + perpLeft * (obstacleWidth / 2 + 3)
					local rightPoint = currentPosition + perpRight * (obstacleWidth / 2 + 3)
					
					local leftDist = (targetPosition - leftPoint).Magnitude
					local rightDist = (targetPosition - rightPoint).Magnitude
					
					-- pick closer side
					aiData.wallFollowDirection = leftDist < rightDist and 1 or -1
					local sideText = aiData.wallFollowDirection > 0 and "LEFT" or "RIGHT"
					
					print(`{enemy.Name} COMMITTED to going FAR {sideText} around {obstacleWidth} stud wide wall for 20 SECONDS!`)
					aiData.currentStrategy = "goaround"
					aiData.lastDetectionTime = currentTime
				end
			else
				-- no obstacle detected but stuck - force jump
				if (currentTime - aiData.lastJumpTime) > 2 then
					humanoid.Jump = true
					aiData.lastJumpTime = currentTime
				end
			end
		end
	end
	
	-- default behavior - run straight at player
	humanoid:MoveTo(targetPosition)
end

-- ai behavior update loop
local function updateAI(aiData: EnemyAIData)
	local enemy = aiData.enemy
	local config = aiData.config
	local humanoid = enemy:FindFirstChildOfClass("Humanoid")
	local hrp = enemy:FindFirstChild("HumanoidRootPart") :: Part?
	
	if not humanoid or not hrp or humanoid.Health <= 0 then
		return
	end
	
	-- set walk speed
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
		
		-- check if in attack range
		if distance <= config.attackRange then
			aiData.currentState = AIState.Attacking
			humanoid:MoveTo(currentPosition) -- Stop moving
		-- check if target escaped
		elseif distance > config.chaseRange * 1.5 then
			aiData.target = nil
			aiData.currentState = AIState.Returning
		else
			-- chase target
			moveToTarget(aiData, targetPosition)
		end
		
	elseif aiData.currentState == AIState.Attacking then
		-- attack target
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
		
		-- face target
		hrp.CFrame = CFrame.new(currentPosition, Vector3.new(targetPosition.X, currentPosition.Y, targetPosition.Z))
		
		-- check if target moved out of range
		if distance > config.attackRange * 1.2 then
			aiData.currentState = AIState.Chasing
		else
			-- perform attack if cooldown is ready
			local currentTime = tick()
			if (currentTime - aiData.lastAttackTime) >= config.attackCooldown then
				aiData.lastAttackTime = currentTime
				
				-- fire attack event (will be handled by EnemyService)
				enemy:SetAttribute("AttackTarget", aiData.target.Name)
			end
		end
		
	elseif aiData.currentState == AIState.Returning then
		-- return to spawn point
		local distance = (aiData.spawnPosition - currentPosition).Magnitude
		
		if distance < 5 then
			aiData.currentState = AIState.Idle
			humanoid:MoveTo(currentPosition) -- stop moving
		else
			moveToTarget(aiData, aiData.spawnPosition)
		end
	end
end

-- start ai for an enemy
function EnemyAI.StartAI(enemy: Model, config: any, spawnPosition: Vector3)
	if activeAIs[enemy] then
		warn(`AI already active for {enemy.Name}`)
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
	
	-- ai update loop (every 0.1 seconds)
	aiData.aiConnection = RunService.Heartbeat:Connect(function()
		-- throttle to ~10 updates per second
		if tick() % 0.1 < 0.016 then
			updateAI(aiData)
		end
	end)
	
	print(`AI started for {enemy.Name}`)
end

-- stop ai for an enemy
function EnemyAI.StopAI(enemy: Model)
	local aiData = activeAIs[enemy]
	if not aiData then
		return
	end
	
	-- disconnect connections
	if aiData.aiConnection then
		aiData.aiConnection:Disconnect()
	end
	
	activeAIs[enemy] = nil
	print(`AI stopped for {enemy.Name}`)
end

-- getr ai data for an enemy
function EnemyAI.GetAIData(enemy: Model): EnemyAIData?
	return activeAIs[enemy]
end

-- cleanup all ais
function EnemyAI.CleanupAll()
	for enemy, aiData in activeAIs do
		EnemyAI.StopAI(enemy)
	end
end

return EnemyAI
