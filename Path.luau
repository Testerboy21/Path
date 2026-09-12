--[[
	Path:
		Manages agent oriented pathfinding

		Properties:
			Spacing: number? -- Spacing between intermediate points on the path, setting this to a large number will only keep the "core" points on the path

			CanJump: boolean?
			CanClimb: boolean?
			NoPartial: boolean? -- Option to exclude partial paths, if any
			Visualize: boolean? -- Visualizes routed points in the world

			Avoid: { [number]: string } -- Table of pathfinding labels (custom or material)
			Allow: { [number]: string } -- ^
			Priorities: { [string]: number } -- Table of pathfinding priorities with a label as the key and numbered priority as the value.

			OnLink: (label: string) -> () -- Function that runs when a custom pathfinding link is traversed, the path is automatically cancelled and the function is ran.
			OnCancel: (reached: boolean) -> () -- Function that runs when the finder is cancelled. Gives a parameters that signifies if the goal was reached.
			OnBlocked: (blockers: { [number]: instance }, inFront: boolean) -> (boolean?) -- Function that determines the status of the finder if a pathway is blocked. If the return state is true, it will recompute. If false, it will cancel. If nil, nothing will happen.
																							A table of potential objects that blocked the path and a boolean determining if the blockage occurred in the front or back of the agent is given.
]]

local CONSTS = {
	Links = "Path.Links",
	Region = "Path.Region",
	Modifier = "Path.Modifier"
}

local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local World = require(ReplicatedStorage.Modules.World)
local Trove = require(ReplicatedStorage.Packages.Trove)

local m = {
	Labels = {},
	Following = {}
}

-- private
local function isValidPath(a, b)
	return (a - b).Magnitude <= (3 * 10 ^ 3)
end

local function isValidLabel(name)
	local isMaterial = pcall(function()
		return Enum.Material[name]
	end)

	return not not (isMaterial or m:GetLabel(name))
end

local function visualize(location, size, lifetime, color)
	local part = Instance.new("Part")

	part.Anchored = true
	part.CanCollide = false
	part.Transparency = 0.65
	part.Name = "World.Visualizer"
	part.Material = Enum.Material.SmoothPlastic
	part.Color = color or Color3.fromRGB(255, 0, 0)

	part.Size = type(size) == "number" and (Vector3.one * size) or size
	part.CFrame = typeof(location) == "Vector3" and CFrame.new(location) or location

	part.Parent = Workspace

	if lifetime then
		task.delay(lifetime, part.Destroy, part)
	end

	return part
end

local function locateInRadius(location, radius, ignored, allowOnly)
	allowOnly = not not allowOnly

	local params = nil
	local position = location

	if typeof(location) == "CFrame" then
		position = location.Position
	end

	if ignored then
		params = OverlapParams.new()
		params.FilterDescendantsInstances = ignored

		if allowOnly then
			params.FilterType = Enum.RaycastFilterType.Include
		end
	end

	return Workspace:GetPartBoundsInRadius(position, radius, params)
end

-- public
function m:GetLabel(name)
	assert(type(name) == "string", "Path.GetLabel | name must be a string")

	return self.Labels[name]
end

function m:IsFollowing(agent, location)
	assert(typeof(agent) == "Instance" and (agent:IsA("Player") or agent:IsA("Model")), "Path.IsFollowing | agent must be a player or NPC")
	assert(typeof(location) == "CFrame" or typeof(location) == "Vector3", "Path.IsFollowing | location must be a CFrame or Vector3")

	local info = self.Following[agent]
	if not info then
		return false
	end

	return info.Location == location
end

function m:Cancel(agent)
	assert(typeof(agent) == "Instance" and (agent:IsA("Player") or agent:IsA("Model")), "Path.Cancel | agent must be a player or NPC")

	local info = self.Following[agent]
	local current = info and info.Cleanup

	if not current then
		return
	end

	local character = agent
	if agent:IsA("Player") then
		character = agent.Character
	end

	local humanoid = character and character:FindFirstChild("Humanoid")
	if not humanoid then
		return
	end

	current:Clean()
	humanoid:Move(Vector3.zAxis * 1e-2)

	current = nil
	self.Following[agent] = nil
end

function m:MoveTo(agent, position)
	assert(typeof(agent) == "Instance" and (agent:IsA("Player") or agent:IsA("Model")), "Path.MoveTo | agent must be a player or NPC")
	assert(typeof(position) == "Vector3", "Path.MoveTo | position must be a Vector3")

	local character = agent
	if agent:IsA("Player") then
		character = agent.Character
	end

	local humanoid = character and character:FindFirstChild("Humanoid")
	if not humanoid then
		return
	end

	local cleanup = Trove.new()
	local walkToPoint = humanoid:GetPropertyChangedSignal("WalkToPoint")
	local moveDirection = humanoid:GetPropertyChangedSignal("MoveDirection")

	cleanup:Connect(walkToPoint, function()
		if humanoid.WalkToPoint == position then
			return
		end

		cleanup:Clean()
		cleanup = nil
	end)

	cleanup:Connect(moveDirection, function()
		cleanup:Clean()
		cleanup = nil
	end)

	cleanup:Connect(humanoid.MoveToFinished, function(reached)
		if reached then
			cleanup:Clean()
			cleanup = nil
		else
			humanoid:MoveTo(position)
		end
	end)

	return humanoid:MoveTo(position)
end

function m:RemoveLabel(object, name)
	assert(typeof(object) == "Instance" and object:IsA("PVInstance"), "Path.RemoveLabel | object must be a PVInstance")
	assert(type(name) == "string", "Path.RemoveLabel | name must be a string")

	-- verify
	local label = self:GetLabel(name)
	local found = label and table.find(label, object)

	if not found then
		return
	end

	table.remove(label, found) do
		if not next(label) then
			self.Labels[name] = nil
		end
	end

	local region = object
	if object:IsA("Model") then
		region = object:FindFirstChild(CONSTS.Region)

		if not region then
			return
		end
	end

	local modifier = region:FindFirstChild(CONSTS.Modifier)
	if not modifier then
		return
	end

	-- clean
	modifier:Destroy()
	modifier = nil

	if object:IsA("Model") then
		region:Destroy()
		region = nil
	end
end

function m:AddLabel(object, name)
	assert(typeof(object) == "Instance" and object:IsA("PVInstance"), "Path.AddLabel | object must be a PVInstance")
	assert(type(name) == "string", "Path.AddLabel | name must be a string")

	-- verify
	local destroying = nil
	local label = self:GetLabel(name)

	if not label then
		label = {}
		self.Labels[name] = label
	elseif table.find(label, object) then
		return
	end

	if object:IsA("Model") then
		-- setup
		local matrix, size = object:GetBoundingBox()
		local region = Instance.new("Part")

		region.Size = size
		region.Transparency = 1
		region.Name = CONSTS.Region

		region.Anchored = true
		region.CanCollide = false

		-- modifier
		local modifier = Instance.new("PathfindingModifier")

		modifier.Name = CONSTS.Modifier
		modifier.Label = name
		modifier.Parent = region

		-- region
		region.CFrame = matrix
		region.Parent = object
	else
		local modifier = Instance.new("PathfindingModifier")

		modifier.Name = CONSTS.Modifier
		modifier.Label = name
		modifier.Parent = object
	end

	destroying = object.Destroying:Once(function()
		if table.find(label, object) then
			self:RemoveLabel(object, name)
		end

		destroying = nil
	end)

	return table.insert(label, object)
end

function m:CreateLink(from, to, name)
	assert(typeof(from) == "Vector3", "Path.CreateLink | from must be Vector3")
	assert(typeof(to) == "Vector3", "Path.CreateLink | to must be a Vector3")
	assert(type(name) == "string", "Path.CreateLink | name must be a string")

	if not isValidPath(from, to) then
		return
	end

	local folder = Workspace:FindFirstChild(CONSTS.Links)
	if not folder then
		folder = Instance.new("Folder")

		folder.Name = CONSTS.Links
		folder.Parent = Workspace

		local removed = nil
		removed = folder.ChildRemoved:Connect(function()
			if not next(folder:GetChildren()) then
				folder:Destroy()
				folder = nil

				removed:Disconnect()
				removed = nil
			end
		end)
	end

	local link = Instance.new("PathfindingLink")

	-- from
	local a = Instance.new("Part")
	local attachment0  = Instance.new("Attachment")

	a.CanCollide = false
	a.Anchored = true
	a.Transparency = 1
	a.Position = from

	attachment0.Parent = a
	a.Parent = link

	-- to
	local b = Instance.new("Part")
	local attachment1  = Instance.new("Attachment")

	b.CanCollide = false
	b.Anchored = true
	b.Transparency = 1
	b.Position = to

	attachment1.Parent = b
	b.Parent = link

	-- link
	link.Attachment0 = attachment0
	link.Attachment1 = attachment1

	link.Label = name
	link.Parent = folder

	return link
end

function m:FollowAndAvoid(agent, location, objects, properties)
	assert(typeof(agent) == "Instance" and (agent:IsA("Player") or agent:IsA("Model")), "Path.FollowAndAvoid | agent must be a player or NPC")
	assert(typeof(location) == "CFrame" or typeof(location) == "Vector3", "Path.FollowAndAvoid | location must be a CFrame or Vector3")
	assert(type(objects) == "table", "Path.FollowAndAvoid | objects must be a table")
	assert(type(properties) == "table", "Path.FollowAndAvoid | properties must be a table")

	-- add
	local cleanup = Trove.new()
	local label = HttpService:GenerateGUID()

	-- verify
	for _, obj in objects do
		if typeof(obj) ~= "Instance" or not obj:IsA("PVInstance") then
			continue
		end

		self:AddLabel(obj, label)

		cleanup:Add(function()
			self:RemoveLabel(obj, label)
		end)
	end

	-- run
	local old = properties.OnCancel
	local cancel = function(reached)
		cleanup:Clean()

		if type(old) == "function" then
			old(reached)
		end
	end

	properties.Avoid = { label }
	properties.OnCancel = cancel

	return self:Follow(agent, location, properties)
end

function m:Follow(agent, location, properties)
	assert(typeof(agent) == "Instance" and (agent:IsA("Player") or agent:IsA("Model")), "Path.Follow | agent must be a player or NPC")
	assert(typeof(location) == "CFrame" or typeof(location) == "Vector3", "Path.Follow | location must be a CFrame or Vector3")
	assert(type(properties) == "table", "Path.Follow | properties must be a table")

	-- verify
	local info = self.Following[agent]
	local current = info and info.Cleanup

	if current then
		current:Clean()
	end

	local character = agent
	if agent:IsA("Player") then
		character = agent.Character
	end

	local humanoid = character and character:FindFirstChild("Humanoid")
	if not humanoid then
		return false
	end

	local start = humanoid.RootPart.Position
	local finish = typeof(location) == "CFrame" and location.Position or location

	if not isValidPath(start, finish) then
		return false
	end

	-- setup
	if not current then
		current = Trove.new()
	end

	local costs = {}
	local modifierCleanup = nil
	local params = { Costs = costs, PathSettings = {} }

	-- properties
	local canJump = properties.CanJump or true
	local spacing = tonumber(properties.Spacing) or 4

	params.WaypointSpacing = spacing
	params.PathSettings.SupportPartialPath = not properties.NoPartial

	-- properties | Agent
	local size = character:GetExtentsSize()

	params.AgentHeight = size.Y
	params.AgentRadius = size.X / 2
	params.AgentCanJump = canJump
	params.AgentCanClimb = properties.CanClimb

	-- properties | Avoid
	local avoid = properties.Avoid
	if avoid and type(avoid) == "table" then
		for _, label in avoid do
			if type(label) ~= "string" or not isValidLabel(label) then
				continue
			end

			costs[label] = math.huge
		end
	end

	-- properties | Priorities
	local priorities = properties.Priorities
	if priorities and type(priorities) == "table" then
		for label, priority in priorities do
			if (type(label) ~= "string" or not tonumber(priority)) or (avoid and avoid[label]) or not isValidLabel(label) then
				continue
			end

			costs[label] = priority
		end
	end

	-- properties | Allow
	local allow = properties.Allow
	if allow and type(allow) == "table" then
		modifierCleanup = current:Extend()

		for _, label in allow do
			if type(label) ~= "string" or (avoid and avoid[label]) or not isValidLabel(label) then
				continue
			end

			local objects = self:GetLabel(label)
			if not objects or not next(objects) then
				continue
			end

			for _, obj in objects do
				local region = obj
				if obj:IsA("Model") then
					region = obj:FindFirstChild(CONSTS.Region)

					if not region then
						continue
					end
				end

				local modifier = region:FindFirstChild(CONSTS.Modifier)
				if not modifier then
					continue
				end

				if not modifier.PassThrough then
					modifier.PassThrough = true

					modifierCleanup:Add(function()
						modifier.PassThrough = false
					end)
				end
			end
		end
	end

	-- create
	local path = PathfindingService:CreatePath(params)
	local success = pcall(path.ComputeAsync, path, start, finish)

	if modifierCleanup then
		modifierCleanup:Clean()
	end

	if not success or path.Status == Enum.PathStatus.NoPath then
		return false
	end

	-- setup | info
	info = {
		Cleanup = current,
		Location = location
	}

	-- setup | route
	local route = path:GetWaypoints()
	if properties.Visualize then
		for _, point in route do
			current:Add(visualize(0.5, point.Position))
		end
	end

	-- run
	local reached = false
	local currentRoute = 1
	local nextRoute = currentRoute + 1

	-- run | cleanup
	local moveDirection = humanoid:GetPropertyChangedSignal("MoveDirection")
	local walkToPoint = humanoid:GetPropertyChangedSignal("WalkToPoint")

	current:Add(function()
		local onCancel = properties.OnCancel
		if type(onCancel) ~= "function" then
			return
		end

		onCancel(reached)
	end)

	current:Connect(moveDirection, function()
		self:Cancel(agent)
	end)

	current:Connect(walkToPoint, function()
		local fromRoute = false
		for _, point in route do
			if point.Position ~= humanoid.WalkToPoint then
				continue
			end

			fromRoute = true
			break
		end

		if not fromRoute then
			self:Cancel(agent)
		end
	end)

	-- run | callbacks
	current:Connect(path.Blocked, function(index)
		local onBlock = properties.OnBlocked
		if not onBlock or type(onBlock) ~= "function" then
			return
		end

		-- calculate & decide
		local blockers = locateInRadius(route[index].Position, 1)
		local inFront = index > currentRoute
		local action = onBlock(blockers, inFront)

		if action == false then
			self:Cancel(agent)
		elseif action == true then
			self:Follow(agent, location, properties)
		end
	end)

	current:Connect(humanoid.MoveToFinished, function(hasReached)
		if not hasReached then
			return
		end

		local from = route[currentRoute]
		local to = route[nextRoute]

		if canJump and from.Action == Enum.PathWaypointAction.Jump then
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end

		-- next
		if nextRoute <= #route then
			local nextLabel = to.Label
			local nextPosition = to.Position

			-- custom
			if self:GetLabel(nextLabel) and to.Action == Enum.PathWaypointAction.Custom then
				local onLink = properties.OnLink

				if type(onLink) == "function" then
					onLink(nextLabel)
				end

				self:Cancel(agent)
			else
				currentRoute = nextRoute
				nextRoute = currentRoute + 1

				self:MoveTo(agent, nextPosition)
			end
		else
			reached = true
			self:Cancel(agent)
		end
	end)

	self.Following[agent] = info
 	self:MoveTo(agent, route[currentRoute].Position)

	return true
end

return m
