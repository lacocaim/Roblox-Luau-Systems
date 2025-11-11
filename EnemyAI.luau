--!strict

--[[
	Enemy AI system with pathfinding and obstacle avoidance
	
	Enemies use a state machine to control behavior
	When chasing they detect obstacles with raycasting
	and choose strategies based on obstacle size
]]

local PathfindingService = game:GetService("PathfindingService") -- used for complex pathfinding but we use custom movement here
local RunService = game:GetService("RunService") -- needed for heartbeat connection to run ai updates

local EnemyAI = {} -- module table to export

local AIState = { -- enum for state machine states
	Idle = "Idle", -- enemy waiting at spawn
	Chasing = "Chasing", -- enemy pursuing player
	Attacking = "Attacking", -- enemy in range and attacking
	Returning = "Returning", -- enemy going back to spawn
}

export type EnemyAIData = { -- type definition for ai data structure
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
	local nearestPlayer: Player? = nil -- stores closest player found so far
	local nearestDistance = range -- maximum search radius in studs
	
	for _, player in game:GetService("Players"):GetPlayers() do -- iterate through all players in server
		if player.Character then -- check if player has spawned character model
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid") -- get humanoid component from character
			local hrp = player.Character:FindFirstChild("HumanoidRootPart") :: Part? -- get rootpart for position data
			
			if humanoid and hrp and humanoid.Health > 0 then -- verify player is alive with valid components
				local distance = (hrp.Position - position).Magnitude -- calculate distance between enemy and player using vector subtraction
				if distance < nearestDistance then -- check if this player is closer than current nearest
					nearestPlayer = player -- update nearest player reference
					nearestDistance = distance -- update minimum distance for next comparison
				end
			end
		end
	end
	
	return nearestPlayer -- return closest player or nil if none found
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
	local rayParams = RaycastParams.new() -- create new raycast parameters object
	rayParams.FilterType = Enum.RaycastFilterType.Exclude -- set filter to ignore specific instances
	rayParams.FilterDescendantsInstances = {ignoreModel} -- exclude enemy model from raycast hits
	
	local direction = (toPosition - fromPosition) -- calculate vector from enemy to target
	local ray = workspace:Raycast(fromPosition, direction, rayParams) -- cast ray to detect obstacles
	
	return ray == nil or ray.Instance:IsA("Terrain") == false -- return true if no obstacle or if obstacle is terrain
end

--[[
	Compares current position to previous position to detect if enemy
	is stuck
	
	Prevents enemies from getting permanently stuck on geometry by
	triggering obstacle avoidance when movement stops
]]
local function isEnemyStuck(aiData: EnemyAIData, currentPosition: Vector3): boolean
	local currentTime = tick() -- get current unix timestamp in seconds
	
	if not aiData.lastPosition then -- check if this is first position check
		aiData.lastPosition = currentPosition -- store initial position for next frame comparison
		aiData.stuckTime = currentTime -- record when stuck detection started
		return false -- return false since we need at least two frames to detect stuck
	end
	
	local distance = (currentPosition - aiData.lastPosition).Magnitude -- calculate studs moved since last check
	
	if distance < 1 then -- check if enemy barely moved indicating stuck
		if (currentTime - aiData.stuckTime) > 2 then -- check if stuck for more than 2 seconds
			return true -- return true to trigger obstacle avoidance
		end
	else -- enemy moved significantly so not stuck
		aiData.lastPosition = currentPosition -- update last position for next check
		aiData.stuckTime = currentTime -- reset stuck timer
	end
	
	return false -- return false if not stuck long enough
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
	local enemy = aiData.enemy -- get enemy model reference
	local humanoid = enemy:FindFirstChildOfClass("Humanoid") -- get humanoid for movement control
	local hrp = enemy:FindFirstChild("HumanoidRootPart") :: Part? -- get rootpart for position data
	
	if not humanoid or not hrp then -- validate required components exist
		return -- exit early if enemy missing components
	end
	
	local currentPosition = hrp.Position -- get current position in world space
	local currentTime = tick() -- get current timestamp for timing calculations
	local direction = (targetPosition - currentPosition) -- calculate direction vector to target
	local distanceToPlayer = direction.Magnitude -- get distance in studs before normalizing
	direction = direction.Unit -- normalize direction to unit vector for consistent movement speed
	
	if not aiData.lastPosition then -- check if this is first movement update
		aiData.lastPosition = currentPosition -- initialize position tracking
		aiData.lastDistanceToPlayer = distanceToPlayer -- initialize distance tracking
	end
	
	local commitTime = 5 -- default commitment duration in seconds for jump strategy
	if aiData.currentStrategy == "goaround" then -- check if using wall follow strategy
		commitTime = 20 -- wall follow needs longer commitment since path is indirect
	end
	
	local isCommitted = aiData.currentStrategy -- check if strategy is active
		and (currentTime - aiData.lastDetectionTime) < commitTime -- and time elapsed is less than commit duration
	
	if isCommitted then -- execute committed strategy without rechecking obstacles
		if aiData.currentStrategy == "jump" then -- execute jump over obstacle strategy
			humanoid:MoveTo(targetPosition) -- move directly toward target
			if (currentTime - aiData.lastJumpTime) > 1.2 then -- check if cooldown elapsed to prevent spam
				humanoid.Jump = true -- trigger jump to clear obstacle
				aiData.lastJumpTime = currentTime -- record jump time for cooldown
			end
			
		elseif aiData.currentStrategy == "goaround" then -- execute wall follow strategy
			local perpendicular = Vector3.new(-direction.Z, 0, direction.X) -- calculate perpendicular vector using 2d rotation
			perpendicular = perpendicular * aiData.wallFollowDirection -- apply left or right direction multiplier
			local targetSidePosition = currentPosition + perpendicular * 15 -- calculate position 15 studs to the side
			humanoid:MoveTo(targetSidePosition) -- move to side position to go around obstacle
			
			if hasLineOfSight(currentPosition, targetPosition, enemy) then -- check if obstacle cleared with raycast
				aiData.currentStrategy = nil -- clear strategy to return to direct movement
				aiData.lastPosition = currentPosition -- update position for stuck detection
			end
		end
		
		return -- exit early since committed strategy is executing
	end
	
	local timeSinceCheck = currentTime - aiData.stuckTime -- calculate time elapsed since last stuck check
	
	if timeSinceCheck > 0.5 then -- check every half second to avoid excessive raycasting
		local moved = (currentPosition - aiData.lastPosition).Magnitude -- calculate distance moved since last check
		local distanceChange = aiData.lastDistanceToPlayer - distanceToPlayer -- calculate if getting closer to player
		
		aiData.lastPosition = currentPosition -- update stored position for next check
		aiData.lastDistanceToPlayer = distanceToPlayer -- update stored distance for next check
		aiData.stuckTime = currentTime -- update check timestamp
		
		if moved < 1 or distanceChange < 0.5 then -- check if not moving much or not getting closer
			local rayParams = RaycastParams.new() -- create raycast parameters for obstacle detection
			rayParams.FilterDescendantsInstances = {enemy} -- exclude enemy from raycast hits
			
			local ray = workspace:Raycast( -- cast ray forward to detect obstacles
				currentPosition + Vector3.new(0, 2, 0), -- start ray 2 studs above ground to avoid floor
				direction * 6, -- ray length of 6 studs ahead
				rayParams -- apply filter parameters
			)
			
			if ray and ray.Instance then -- check if obstacle detected
				local obstacle = ray.Instance -- get the part that was hit
				local obstacleSize = obstacle.Size -- get size vector of obstacle
				local obstacleHeight = obstacleSize.Y -- extract y component for height
				local obstacleWidth = math.max(obstacleSize.X, obstacleSize.Z) -- get larger horizontal dimension
				
				if obstacleHeight < 5 then -- check if obstacle is short enough to jump
					aiData.currentStrategy = "jump" -- set strategy to jump over
					aiData.lastDetectionTime = currentTime -- record when strategy started
					aiData.lastJumpTime = currentTime -- record jump timestamp
					humanoid.Jump = true -- immediately trigger first jump
					humanoid:MoveTo(targetPosition) -- continue moving toward target
					
				else -- obstacle too tall to jump so go around
					local perpLeft = Vector3.new(-direction.Z, 0, direction.X) -- calculate left perpendicular using 2d rotation
					local perpRight = Vector3.new(direction.Z, 0, -direction.X) -- calculate right perpendicular
					
					local leftPoint = currentPosition -- calculate point to left of obstacle
						+ perpLeft * (obstacleWidth / 2 + 3) -- offset by half width plus clearance
					local rightPoint = currentPosition -- calculate point to right of obstacle
						+ perpRight * (obstacleWidth / 2 + 3) -- offset by half width plus clearance
					
					local leftDist = (targetPosition - leftPoint).Magnitude -- calculate distance to target from left point
					local rightDist = (targetPosition - rightPoint).Magnitude -- calculate distance to target from right point
					
					aiData.wallFollowDirection = if leftDist < rightDist -- choose direction that gets closer to target
						then 1 -- positive 1 for left direction
						else -1 -- negative 1 for right direction
					
					aiData.currentStrategy = "goaround" -- set strategy to wall follow
					aiData.lastDetectionTime = currentTime -- record when strategy started
				end
			else -- no obstacle detected but stuck
				if (currentTime - aiData.lastJumpTime) > 2 then -- check if jump cooldown expired
					humanoid.Jump = true -- try jumping anyway in case small obstacle missed
					aiData.lastJumpTime = currentTime -- record jump timestamp
				end
			end
		end
	end
	
	humanoid:MoveTo(targetPosition) -- default movement when no strategy active
end

--[[
	Executes state machine logic for enemy behavior
	
	Runs periodically via heartbeat connection to update enemy state
	and handle transitions between idle, chasing, attacking and
	returning based on player proximity and health
]]
local function updateAI(aiData: EnemyAIData)
	local enemy = aiData.enemy -- get enemy model reference
	local config = aiData.config -- get enemy configuration data
	local humanoid = enemy:FindFirstChildOfClass("Humanoid") -- get humanoid component
	local hrp = enemy:FindFirstChild("HumanoidRootPart") :: Part? -- get rootpart component
	
	if not humanoid or not hrp or humanoid.Health <= 0 then -- validate components and check if dead
		return -- exit if enemy invalid or dead
	end
	
	humanoid.WalkSpeed = config.speed -- apply configured movement speed
	
	local currentPosition = hrp.Position -- get current world position
	
	if aiData.currentState == AIState.Idle then -- check if enemy is waiting at spawn
		local nearestPlayer = findNearestPlayer( -- search for closest player within range
			currentPosition, -- enemy position to search from
			config.chaseRange -- maximum detection radius
		)
		
		if nearestPlayer then -- check if player found in range
			aiData.target = nearestPlayer -- set player as chase target
			aiData.currentState = AIState.Chasing -- transition to chasing state
		end
		
	elseif aiData.currentState == AIState.Chasing then -- check if enemy pursuing player
		if not aiData.target or not aiData.target.Character then -- validate target player exists with character
			aiData.target = nil -- clear invalid target
			aiData.currentState = AIState.Idle -- return to idle state
			return -- exit early
		end
		
		local targetHumanoid = aiData.target.Character:FindFirstChildOfClass( -- get player humanoid
			"Humanoid"
		)
		if not targetHumanoid or targetHumanoid.Health <= 0 then -- check if player dead or missing humanoid
			aiData.target = nil -- clear dead target
			aiData.currentState = AIState.Idle -- return to idle state
			return -- exit early
		end
		
		local targetHrp = aiData.target.Character:FindFirstChild( -- get player rootpart
			"HumanoidRootPart"
		) :: Part?
		if not targetHrp then -- validate rootpart exists
			aiData.target = nil -- clear invalid target
			aiData.currentState = AIState.Idle -- return to idle state
			return -- exit early
		end
		
		local targetPosition = targetHrp.Position -- get player world position
		local distance = (targetPosition - currentPosition).Magnitude -- calculate distance to player
		
		if distance <= config.attackRange then -- check if close enough to attack
			aiData.currentState = AIState.Attacking -- transition to attacking state
			humanoid:MoveTo(currentPosition) -- stop moving
		elseif distance > config.chaseRange * 1.5 then -- check if player escaped too far
			aiData.target = nil -- clear escaped target
			aiData.currentState = AIState.Returning -- transition to returning state
		else -- player still in chase range
			moveToTarget(aiData, targetPosition) -- continue pursuing player
		end
		
	elseif aiData.currentState == AIState.Attacking then -- check if enemy in attack mode
		if not aiData.target or not aiData.target.Character then -- validate target player exists with character
			aiData.target = nil -- clear invalid target
			aiData.currentState = AIState.Idle -- return to idle state
			return -- exit early
		end
		
		local targetHumanoid = aiData.target.Character:FindFirstChildOfClass( -- get player humanoid
			"Humanoid"
		)
		if not targetHumanoid or targetHumanoid.Health <= 0 then -- check if player dead or missing humanoid
			aiData.target = nil -- clear dead target
			aiData.currentState = AIState.Idle -- return to idle state
			return -- exit early
		end
		
		local targetHrp = aiData.target.Character:FindFirstChild( -- get player rootpart
			"HumanoidRootPart"
		) :: Part?
		if not targetHrp then -- validate rootpart exists
			aiData.target = nil -- clear invalid target
			aiData.currentState = AIState.Idle -- return to idle state
			return -- exit early
		end
		
		local targetPosition = targetHrp.Position -- get player world position
		local distance = (targetPosition - currentPosition).Magnitude -- calculate distance to player
		
		hrp.CFrame = CFrame.new( -- rotate enemy to face player
			currentPosition, -- keep current position
			Vector3.new(targetPosition.X, currentPosition.Y, targetPosition.Z) -- look at player but keep same y rotation
		)
		
		if distance > config.attackRange * 1.2 then -- check if player moved out of attack range
			aiData.currentState = AIState.Chasing -- transition back to chasing state
		else -- player still in range
			local currentTime = tick() -- get current timestamp
			if (currentTime - aiData.lastAttackTime) >= config.attackCooldown then -- check if attack cooldown finished
				aiData.lastAttackTime = currentTime -- record attack timestamp
				
				enemy:SetAttribute("AttackTarget", aiData.target.Name) -- set attribute for combatservice to handle damage
			end
		end
		
	elseif aiData.currentState == AIState.Returning then -- check if enemy going back to spawn
		local distance = (aiData.spawnPosition - currentPosition).Magnitude -- calculate distance to spawn point
		
		if distance < 5 then -- check if reached spawn position
			aiData.currentState = AIState.Idle -- transition to idle state
			humanoid:MoveTo(currentPosition) -- stop moving
		else -- still far from spawn
			moveToTarget(aiData, aiData.spawnPosition) -- continue moving toward spawn
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
	if activeAIs[enemy] then -- check if ai already running for this enemy
		warn(`ai already active for {enemy.Name}`) -- output warning to prevent duplicate systems
		return -- exit early
	end
	
	local aiData: EnemyAIData = { -- create new ai data structure
		enemy = enemy, -- store enemy model reference
		config = config, -- store configuration table
		currentState = AIState.Idle, -- start in idle state at spawn
		target = nil, -- no target initially
		spawnPosition = spawnPosition, -- store spawn location for returning
		lastAttackTime = 0, -- initialize attack cooldown timer
		path = nil, -- no pathfinding path initially
		pathUpdateTime = 0, -- initialize path recalculation timer
		lastPosition = nil, -- no previous position for stuck detection
		stuckTime = 0, -- initialize stuck detection timer
		lastJumpTime = 0, -- initialize jump cooldown timer
		failedPathAttempts = 0, -- counter for pathfinding failures
		wallFollowDirection = nil, -- no wall follow direction initially
		lastDetectionTime = 0, -- initialize obstacle detection timer
		currentStrategy = nil, -- no avoidance strategy active
		lastDistanceToPlayer = nil, -- no previous distance for comparison
		healthConnection = nil, -- no health event connection yet
		aiConnection = nil, -- no heartbeat connection yet
	}
	
	activeAIs[enemy] = aiData -- register enemy in active ai table
	
	aiData.aiConnection = RunService.Heartbeat:Connect(function() -- connect to heartbeat event for ai updates
		if tick() % 0.1 < 0.016 then -- throttle updates to run roughly every 0.1 seconds using modulo
			updateAI(aiData) -- execute state machine update
		end
	end)
end

--[[
	Stops AI system for an enemy and cleans up connections
	
	Called when enemy dies or is removed to prevent memory leaks from
	dangling connections
]]
function EnemyAI.StopAI(enemy: Model)
	local aiData = activeAIs[enemy] -- get ai data for this enemy
	if not aiData then -- check if ai exists
		return -- exit if no ai to stop
	end
	
	if aiData.aiConnection then -- check if heartbeat connection exists
		aiData.aiConnection:Disconnect() -- disconnect from heartbeat to stop updates
	end
	
	activeAIs[enemy] = nil -- remove enemy from active ai table
end

--[[
	Resets enemy to spawn position and clears combat state
	
	Used when enemy needs to be reset without destroying and
	recreating the entire AI system
]]
function EnemyAI.ResetAI(enemy: Model)
	local aiData = activeAIs[enemy] -- get ai data for this enemy
	if not aiData then -- check if ai exists
		return -- exit if no ai to reset
	end
	
	aiData.target = nil -- clear chase target
	aiData.currentState = AIState.Idle -- reset to idle state
	aiData.lastAttackTime = 0 -- reset attack cooldown
	aiData.currentStrategy = nil -- clear avoidance strategy
	aiData.wallFollowDirection = nil -- clear wall follow direction
	
	local hrp = enemy:FindFirstChild("HumanoidRootPart") :: Part? -- get enemy rootpart
	if hrp then -- validate rootpart exists
		hrp.CFrame = CFrame.new(aiData.spawnPosition) -- teleport enemy back to spawn
	end
end

--[[
	Retrieves AI data structure for debugging or external control
	
	Allows other systems to check enemy state or modify behavior
	without direct access to internal activeAIs table
]]
function EnemyAI.GetAIData(enemy: Model): EnemyAIData?
	return activeAIs[enemy] -- return ai data from active table or nil if not found
end

--[[
	Stops all active enemy AI systems for server shutdown
	
	Prevents errors from AI trying to update after game resources are
	cleaned up
]]
function EnemyAI.CleanupAll()
	for enemy, aiData in activeAIs do -- iterate through all active enemy ais
		EnemyAI.StopAI(enemy) -- stop ai and cleanup connections
	end
end

return EnemyAI -- export module table
