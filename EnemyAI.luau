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
	local nearestPlayer: Player? = nil -- stores the closest player found so far
	local nearestDistance = range -- maximum search distance, gets smaller as closer players are found
	
	for _, player in game:GetService("Players"):GetPlayers() do -- iterates through all players in the server
		if player.Character then -- checks if player has spawned character model
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid") -- gets the humanoid component controlling health and movement
			local hrp = player.Character:FindFirstChild("HumanoidRootPart") :: Part? -- gets the main body part used for position calculations
			
			if humanoid and hrp and humanoid.Health > 0 then -- validates player is alive and has necessary components
				local distance = (hrp.Position - position).Magnitude -- calculates euclidean distance between enemy and player
				if distance < nearestDistance then -- checks if this player is closer than previous closest
					nearestPlayer = player -- updates the nearest player reference
					nearestDistance = distance -- updates minimum distance for next comparison
				end
			end
		end
	end
	
	return nearestPlayer -- returns closest player or nil if none found in range
end

-- checks if theres a clear path between two points (used for wall detection)
local function hasLineOfSight(fromPosition: Vector3, toPosition: Vector3, ignoreModel: Model): boolean
	local rayParams = RaycastParams.new() -- creates parameters object for raycast configuration
	rayParams.FilterType = Enum.RaycastFilterType.Exclude -- sets filter to ignore specific instances instead of whitelist
	rayParams.FilterDescendantsInstances = {ignoreModel} -- excludes the enemy model so it doesnt hit itself
	
	local direction = (toPosition - fromPosition) -- calculates vector direction from start to end point
	local ray = workspace:Raycast(fromPosition, direction, rayParams) -- casts ray through 3d space to detect obstacles
	
	-- no hit or hit terrain = we can see player
	return ray == nil or ray.Instance:IsA("Terrain") == false -- returns true if nothing blocks the path or only terrain was hit
end

-- detects if enemy hasnt moved much and is stuck
local function isEnemyStuck(aiData: EnemyAIData, currentPosition: Vector3): boolean
	local currentTime = tick() -- gets current unix timestamp in seconds
	
	if not aiData.lastPosition then -- checks if this is the first position check
		aiData.lastPosition = currentPosition -- initializes starting position for future comparisons
		aiData.stuckTime = currentTime -- records when tracking started
		return false -- cant be stuck on first check
	end
	
	local distance = (currentPosition - aiData.lastPosition).Magnitude -- calculates how far enemy moved since last check
	
	if distance < 1 then -- checks if movement is less than 1 stud (considered stuck)
		-- stuck for more than 2 seconds
		if (currentTime - aiData.stuckTime) > 2 then -- checks if stuck duration exceeds threshold
			return true -- enemy is confirmed stuck
		end
	else
		aiData.lastPosition = currentPosition -- updates last known position since enemy moved
		aiData.stuckTime = currentTime -- resets stuck timer since enemy is moving
	end
	
	return false -- enemy is not stuck yet
end

-- main movement logic with obstacle detection and avoidance strategies
local function moveToTarget(aiData: EnemyAIData, targetPosition: Vector3)
	local enemy = aiData.enemy -- reference to the enemy model
	local humanoid = enemy:FindFirstChildOfClass("Humanoid") -- gets humanoid for movement commands
	local hrp = enemy:FindFirstChild("HumanoidRootPart") :: Part? -- gets root part for position and physics
	
	if not humanoid or not hrp then -- validates required components exist
		return -- exits if enemy is missing critical parts
	end
	
	local currentPosition = hrp.Position -- stores current 3d position as vector3
	local currentTime = tick() -- gets current timestamp for time-based calculations
	local direction = (targetPosition - currentPosition) -- calculates direction vector to target
	local distanceToPlayer = direction.Magnitude -- stores distance before normalizing
	direction = direction.Unit -- normalizes direction to unit vector (length of 1)
	
	-- track progress
	if not aiData.lastPosition then -- checks if tracking has been initialized
		aiData.lastPosition = currentPosition -- sets initial position for movement comparison
		aiData.lastDistanceToPlayer = distanceToPlayer -- records starting distance to measure progress
	end
	
	-- check if currently committed to a movement strategy
	-- this prevents the ai from flip-flopping between strategies
	local commitTime = 5 -- default commit duration in seconds for jump strategy
	if aiData.currentStrategy == "goaround" then -- checks if using wall avoidance strategy
		commitTime = 20 -- extends commit time since going around takes longer
	end
	
	local isCommitted = aiData.currentStrategy and (currentTime - aiData.lastDetectionTime) < commitTime -- determines if still executing a strategy
	
	if isCommitted then -- checks if currently executing a committed strategy
		-- executing committed strategy, dont check for new obstacles
		
		if aiData.currentStrategy == "jump" then -- handles jump obstacle avoidance
			-- keep moving forward and jumping over small obstacles
			humanoid:MoveTo(targetPosition) -- continues moving toward target
			if (currentTime - aiData.lastJumpTime) > 1.2 then -- checks if enough time passed since last jump
				humanoid.Jump = true -- triggers jump animation and upward velocity
				aiData.lastJumpTime = currentTime -- updates jump timestamp to prevent spam
			end
			
		elseif aiData.currentStrategy == "goaround" then -- handles wall circumnavigation
			-- move far perpendicular to wall until we have line of sight again
			local perpendicular = Vector3.new(-direction.Z, 0, direction.X) * aiData.wallFollowDirection -- calculates perpendicular vector (90 degrees from forward)
			local targetSidePosition = currentPosition + perpendicular * 15 -- calculates position 15 studs to the side
			humanoid:MoveTo(targetSidePosition) -- moves to side position to go around obstacle
			
			-- check if we cleared the wall
			if hasLineOfSight(currentPosition, targetPosition, enemy) then -- raycasts to see if path is now clear
				aiData.currentStrategy = nil -- clears strategy to return to normal pathfinding
				aiData.lastPosition = currentPosition -- updates position tracking
			end
		end
		
		return -- exits function early to prevent strategy interruption
	end
	
	-- not committed - check if making progress toward player
	local timeSinceCheck = currentTime - aiData.stuckTime -- calculates seconds since last progress check
	
	if timeSinceCheck > 0.5 then -- runs progress check every half second for performance
		local moved = (currentPosition - aiData.lastPosition).Magnitude -- calculates distance moved since last check
		local distanceChange = aiData.lastDistanceToPlayer - distanceToPlayer -- calculates if getting closer to player (positive = closer)
		
		aiData.lastPosition = currentPosition -- updates position for next iteration
		aiData.lastDistanceToPlayer = distanceToPlayer -- updates distance for next comparison
		aiData.stuckTime = currentTime -- resets check timer
		
		-- not making progress = something blocking us
		if moved < 1 or distanceChange < 0.5 then -- checks if barely moved or not getting closer to player
			
			-- raycast to see whats in front
			local rayParams = RaycastParams.new() -- creates raycast configuration object
			rayParams.FilterDescendantsInstances = {enemy} -- excludes enemy from raycast to prevent self-detection
			
			local ray = workspace:Raycast( -- casts ray forward to detect obstacles
				currentPosition + Vector3.new(0, 2, 0), -- starts ray 2 studs above ground to avoid floor detection
				direction * 6, -- casts ray 6 studs forward in direction of player
				rayParams -- applies filter settings
			)
			
			if ray and ray.Instance then -- checks if raycast hit something
				local obstacle = ray.Instance -- gets the part that was hit
				local obstacleSize = obstacle.Size -- gets dimensions of obstacle as vector3
				local obstacleHeight = obstacleSize.Y -- extracts vertical height of obstacle
				local obstacleWidth = math.max(obstacleSize.X, obstacleSize.Z) -- gets largest horizontal dimension
				
				-- small obstacle = jump over it
				if obstacleHeight < 5 then -- checks if obstacle is shorter than 5 studs (jumpable)
					aiData.currentStrategy = "jump" -- sets ai to use jumping strategy
					aiData.lastDetectionTime = currentTime -- records when strategy was chosen
					aiData.lastJumpTime = currentTime -- initializes jump timer
					humanoid.Jump = true -- immediately triggers first jump
					humanoid:MoveTo(targetPosition) -- continues moving toward player while jumping
					
				else -- obstacle is too tall to jump over
					-- big wall = walk around it
					-- calculate which side is shorter
					local perpLeft = Vector3.new(-direction.Z, 0, direction.X) -- calculates left perpendicular vector using cross product rotation
					local perpRight = Vector3.new(direction.Z, 0, -direction.X) -- calculates right perpendicular vector (opposite of left)
					
					local leftPoint = currentPosition + perpLeft * (obstacleWidth / 2 + 3) -- calculates position around left side with 3 stud buffer
					local rightPoint = currentPosition + perpRight * (obstacleWidth / 2 + 3) -- calculates position around right side with 3 stud buffer
					
					local leftDist = (targetPosition - leftPoint).Magnitude -- measures total distance if going left
					local rightDist = (targetPosition - rightPoint).Magnitude -- measures total distance if going right
					
					-- pick the shorter path
					aiData.wallFollowDirection = leftDist < rightDist and 1 or -1 -- stores -1 or 1 to indicate which direction to circle
					
					aiData.currentStrategy = "goaround" -- sets ai to use wall circumnavigation strategy
					aiData.lastDetectionTime = currentTime -- records when strategy started
				end
			else -- no obstacle detected by raycast
				-- no obstacle detected but still stuck, just jump
				if (currentTime - aiData.lastJumpTime) > 2 then -- checks if 2 seconds passed since last jump attempt
					humanoid.Jump = true -- triggers jump to try getting unstuck
					aiData.lastJumpTime = currentTime -- updates jump timer
				end
			end
		end
	end
	
	-- default behavior
	humanoid:MoveTo(targetPosition) -- basic movement command when no special strategy is active
end

-- updates ai state machine each frame
local function updateAI(aiData: EnemyAIData)
	local enemy = aiData.enemy -- reference to enemy model being controlled
	local config = aiData.config -- table containing ai behavior parameters like speed and ranges
	local humanoid = enemy:FindFirstChildOfClass("Humanoid") -- gets humanoid for health and movement
	local hrp = enemy:FindFirstChild("HumanoidRootPart") :: Part? -- gets root part for position calculations
	
	if not humanoid or not hrp or humanoid.Health <= 0 then -- validates enemy is alive and has required parts
		return -- exits if enemy is dead or invalid
	end
	
	humanoid.WalkSpeed = config.speed -- applies configured movement speed from enemy type config
	
	local currentPosition = hrp.Position -- gets current world position as vector3
	
	-- state machine
	if aiData.currentState == AIState.Idle then -- checks if enemy is in idle state (not engaged)
		-- look for players
		local nearestPlayer = findNearestPlayer(currentPosition, config.chaseRange) -- searches for closest player within detection range
		
		if nearestPlayer then -- checks if a valid player target was found
			aiData.target = nearestPlayer -- sets the player as current target
			aiData.currentState = AIState.Chasing -- transitions to chasing state to pursue player
		end
		
	elseif aiData.currentState == AIState.Chasing then -- handles pursuing player target
		-- chase target
		if not aiData.target or not aiData.target.Character then -- validates target still exists and has character
			aiData.target = nil -- clears invalid target
			aiData.currentState = AIState.Idle -- returns to idle to find new target
			return -- exits early
		end
		
		-- check if target is still alive
		local targetHumanoid = aiData.target.Character:FindFirstChildOfClass("Humanoid") -- gets target's humanoid to check health
		if not targetHumanoid or targetHumanoid.Health <= 0 then -- checks if player died
			aiData.target = nil -- clears dead target
			aiData.currentState = AIState.Idle -- returns to idle state
			return -- exits early
		end
		
		local targetHrp = aiData.target.Character:FindFirstChild("HumanoidRootPart") :: Part? -- gets target's root part for position
		if not targetHrp then -- validates target has root part
			aiData.target = nil -- clears invalid target
			aiData.currentState = AIState.Idle -- returns to idle
			return -- exits early
		end
		
		local targetPosition = targetHrp.Position -- gets target's current world position
		local distance = (targetPosition - currentPosition).Magnitude -- calculates distance to target
		
		-- close enough to attack
		if distance <= config.attackRange then -- checks if within attack distance
			aiData.currentState = AIState.Attacking -- transitions to attacking state
			humanoid:MoveTo(currentPosition) -- stops movement to perform attack
		-- player escaped
		elseif distance > config.chaseRange * 1.5 then -- checks if player moved too far away (1.5x chase range)
			aiData.target = nil -- abandons target
			aiData.currentState = AIState.Returning -- begins returning to spawn point
		else -- player is in chase range but not attack range
			-- keep chasing
			moveToTarget(aiData, targetPosition) -- calls movement function with obstacle avoidance
		end
		
	elseif aiData.currentState == AIState.Attacking then -- handles attack behavior
		-- attack target
		if not aiData.target or not aiData.target.Character then -- validates target exists
			aiData.target = nil -- clears invalid target
			aiData.currentState = AIState.Idle -- returns to idle
			return -- exits early
		end
		
		local targetHumanoid = aiData.target.Character:FindFirstChildOfClass("Humanoid") -- gets target humanoid
		if not targetHumanoid or targetHumanoid.Health <= 0 then -- checks if target died
			aiData.target = nil -- clears dead target
			aiData.currentState = AIState.Idle -- returns to idle
			return -- exits early
		end
		
		local targetHrp = aiData.target.Character:FindFirstChild("HumanoidRootPart") :: Part? -- gets target root part
		if not targetHrp then -- validates target has root part
			aiData.target = nil -- clears invalid target
			aiData.currentState = AIState.Idle -- returns to idle
			return -- exits early
		end
		
		local targetPosition = targetHrp.Position -- gets target position
		local distance = (targetPosition - currentPosition).Magnitude -- calculates current distance to target
		
		-- face the target
		hrp.CFrame = CFrame.new(currentPosition, Vector3.new(targetPosition.X, currentPosition.Y, targetPosition.Z)) -- rotates enemy to look at target (locks y axis)
		
		-- target moved out of range
		if distance > config.attackRange * 1.2 then -- checks if target moved beyond attack range with buffer
			aiData.currentState = AIState.Chasing -- switches back to chasing to close distance
		else -- target is still in attack range
			-- attack if cooldown ready
			local currentTime = tick() -- gets current timestamp
			if (currentTime - aiData.lastAttackTime) >= config.attackCooldown then -- checks if attack cooldown finished
				aiData.lastAttackTime = currentTime -- resets cooldown timer
				
				-- set attribute for enemyservice to handle
				enemy:SetAttribute("AttackTarget", aiData.target.Name) -- signals enemyservice to process damage through attribute system
			end
		end
		
	elseif aiData.currentState == AIState.Returning then -- handles returning to spawn after losing target
		-- return to spawn point
		local distance = (aiData.spawnPosition - currentPosition).Magnitude -- calculates distance from current position to spawn point
		
		if distance < 5 then -- checks if close enough to spawn (within 5 studs)
			aiData.currentState = AIState.Idle -- switches to idle state at spawn
			humanoid:MoveTo(currentPosition) -- stops movement
		else -- still far from spawn
			moveToTarget(aiData, aiData.spawnPosition) -- moves toward spawn using pathfinding with obstacle avoidance
		end
	end
end

-- starts ai for an enemy
function EnemyAI.StartAI(enemy: Model, config: any, spawnPosition: Vector3)
	if activeAIs[enemy] then -- checks if ai already running for this enemy
		warn(`ai already active for {enemy.Name}`) -- logs warning to prevent duplicate ai systems
		return -- exits without starting duplicate
	end
	
	local aiData: EnemyAIData = { -- creates ai data structure with all required fields
		enemy = enemy, -- stores reference to enemy model
		config = config, -- stores behavior configuration (speed, ranges, damage)
		currentState = AIState.Idle, -- initializes in idle state
		target = nil, -- no target at start
		spawnPosition = spawnPosition, -- stores spawn location for returning behavior
		lastAttackTime = 0, -- initializes attack cooldown timer
		path = nil, -- pathfinding path object (unused in current implementation)
		pathUpdateTime = 0, -- timestamp for path recalculation
		lastPosition = nil, -- tracks position for stuck detection
		stuckTime = 0, -- timestamp for stuck duration tracking
		lastJumpTime = 0, -- timestamp for jump cooldown
		failedPathAttempts = 0, -- counter for pathfinding failures
		wallFollowDirection = nil, -- stores which direction to go around walls (-1 or 1)
		lastDetectionTime = 0, -- timestamp when obstacle strategy started
		currentStrategy = nil, -- stores current avoidance strategy ("jump" or "goaround")
		lastDistanceToPlayer = nil, -- tracks distance for progress checking
		healthConnection = nil, -- connection for health changed events
		aiConnection = nil, -- connection for ai update loop
	}
	
	activeAIs[enemy] = aiData -- registers ai in active table for tracking
	
	-- ai update loop runs at 10hz
	aiData.aiConnection = RunService.Heartbeat:Connect(function() -- connects to render heartbeat event (runs every frame)
		-- throttle to 10 updates per second for performance
		if tick() % 0.1 < 0.016 then -- uses modulo to run only ~10 times per second instead of 60fps
			updateAI(aiData) -- calls state machine update function
		end
	end)
end

-- stops ai for an enemy and cleans up connections
function EnemyAI.StopAI(enemy: Model)
	local aiData = activeAIs[enemy] -- gets ai data from active table
	if not aiData then -- checks if ai exists for this enemy
		return -- exits if no ai running
	end
	
	if aiData.aiConnection then -- checks if heartbeat connection exists
		aiData.aiConnection:Disconnect() -- disconnects from heartbeat to stop updates
	end
	
	activeAIs[enemy] = nil -- removes from active table to free memory
end

-- resets ai to initial state and teleports enemy to spawn
function EnemyAI.ResetAI(enemy: Model)
	local aiData = activeAIs[enemy] -- gets ai data from active table
	if not aiData then -- checks if ai exists for this enemy
		return -- exits if no ai running
	end
	
	-- clear target and reset state
	aiData.target = nil -- removes current target
	aiData.currentState = AIState.Idle -- resets to idle state
	aiData.lastAttackTime = 0 -- resets attack cooldown
	aiData.currentStrategy = nil -- clears movement strategy
	aiData.wallFollowDirection = nil -- clears wall avoidance direction
	
	-- move back to spawn
	local hrp = enemy:FindFirstChild("HumanoidRootPart") :: Part? -- gets root part
	if hrp then -- validates root part exists
		hrp.CFrame = CFrame.new(aiData.spawnPosition) -- teleports enemy to spawn position
	end
end

-- gets ai data for an enemy (useful for debugging or external systems)
function EnemyAI.GetAIData(enemy: Model): EnemyAIData?
	return activeAIs[enemy] -- returns ai data table or nil if not found
end

-- stops all active ais and cleans up connections (called on server shutdown)
function EnemyAI.CleanupAll()
	for enemy, aiData in activeAIs do -- iterates through all active enemy ais
		EnemyAI.StopAI(enemy) -- stops each ai and disconnects events
	end
end

return EnemyAI

