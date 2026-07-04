--!strict

--[[
Connected Discord-GitHub
@hi2ryan on discord
@hii2ryan on roblox
]]

const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")

const jecs = require(ReplicatedStorage.packages.jecs)

type Entity<T = nil> = jecs.Entity<T>

type SystemFn<T... = ...unknown> = (T...) -> ()
type SystemEntry = { fn: SystemFn, priority: number }
type Scheduler = {
	_systems: { [RBXScriptSignal]: { SystemEntry } },

	schedule: <T...>(self: Scheduler, signal: RBXScriptSignal, SystemFn<T...>, priority: number) -> (),
	run: (self: Scheduler) -> (),
}

type Prefabs = {
	human: (origin: vector, name: string) -> Entity,
	alien: (origin: vector, name: string) -> Entity,
}

-- create ecs world
const world = jecs.world()

-- localize ecs vars
const pair = jecs.pair
const Wildcard = jecs.Wildcard

-- create ECS components
const Transform = world:component<<CFrame>>()
const Position = world:component<<vector>>()
const Velocity = world:component<<vector>>()

--- Represents the size of an entity's bounding box
const Size = world:component<<vector>>()

--- Defines the root BasePart of an entity.
const RootPart = world:component<<BasePart>>()

-- ECS tags

--- Determines whether an entity is affected by gravitational acceleration
const Gravity = world:entity()

--- Determines the species an entity is
--- ex. pairs: (Species, Human); (Species, Alien)
const Species = world:entity()

const Human = world:entity()
const Alien = world:entity()

--- The default health for a human entity
const HUMAN_SIZE = vector.create(2.5, 2.5, 2.5)

--- The default health for an alien entity
const ALIEN_SIZE = HUMAN_SIZE * 2

-- physics constants
const MIN_BOUNCE = 0.5
const BOUNCE_DAMPING_RATIO = 0.6

-- species acceleration map
const GRAVITATIONAL_ACCELERATION: { [Entity]: vector } = {
	[Human] = vector.create(0, -100, 0),

	-- for some reason aliens are not affected as much by gravity
	[Alien] = vector.create(0, -25, 0),
}

-- create cached ecs queries
const q_gravity = world:query(Velocity, Gravity, pair(Species, Wildcard)):cached()
const q_movement = world:query(
    Position,
    Velocity,
    Transform,
    RootPart,
    Size
):cached()
const q_transforms = world:query(RootPart, Transform):cached()

-- create raycast params that will be reused throughout apply_velocity
const collision_params = RaycastParams.new()
collision_params.RespectCanCollide = true

const scheduler = {
	_systems = {},
} :: Scheduler

--- Schedules a system to be ran under `signal`. Prioritizes higher priorities first.
function scheduler.schedule<T...>(self: Scheduler, signal: RBXScriptSignal, system: SystemFn<T...>, priority: number)
	-- create system entry
	const entry: SystemEntry = { fn = system :: SystemFn, priority = priority }
	const systems = scheduler._systems[signal]

	if systems then
		-- insert system entry into pre-existing system array
		table.insert(systems, entry)
	else
		-- system array has not been created for this signal before, initialize it with the entry
		scheduler._systems[signal] = { entry }
	end
end

--- Runs the systems under the scheduler.
function scheduler.run(self: Scheduler)
	for signal, systems in self._systems do
		-- sort by priority
		table.sort(systems, function(a: SystemEntry, b: SystemEntry): boolean
			return a.priority > b.priority
		end)

		const system_count = #systems

		-- map systems to system functions
		const system_fns = table.create<<SystemFn>>(system_count)
		for i = 1, system_count do
			system_fns[i] = systems[i].fn
		end

		signal:Connect(function(...)
			-- run all systems under signal
			for i = 1, system_count do
				const system_fn = system_fns[i]
				system_fn(...)
			end
		end)
	end
end

-- prefabs for ecs entity creation
local prefabs: Prefabs
do
	-- create a white outlined highlight around the parts
	-- use a container model so it can support all the parts instead of the highlight limit
	const CONTAINER = Instance.new("Model")
	const highlight = Instance.new("Highlight")
	highlight.Adornee = CONTAINER
	highlight.FillTransparency = 1
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.Parent = CONTAINER

	--- Creates a "human" entity along with its rootpart.
	const function human_create(origin: vector, name: string): Entity
		-- create part
		const root_part = Instance.new("Part")
		root_part.Name = `human-{name}`
		root_part.CFrame = CFrame.new(origin :: any)
		root_part.Anchored = true
		root_part.Size = HUMAN_SIZE :: any
		root_part.Color = Color3.fromRGB(232, 224, 140)
		root_part.Parent = CONTAINER

		-- create ecs entity for the "human"
		const entity = world:entity()
		world:set(entity, Transform, CFrame.new(origin :: any))
		world:set(entity, Position, origin)
		world:set(entity, Velocity, vector.zero)
		world:set(entity, Size, HUMAN_SIZE)
		world:set(entity, RootPart, root_part)
		world:add(entity, Gravity)
		world:add(entity, pair(Species, Human))

		return entity
	end

	--- Creates an "alien" entity along with its rootpart.
	const function alien_create(origin: vector, name: string): Entity
		-- create part
		const root_part = Instance.new("Part")
		root_part.Name = `alien-{name}`
		root_part.CFrame = CFrame.new(origin :: any)
		root_part.Anchored = true
		root_part.Shape = Enum.PartType.Wedge
		root_part.Size = ALIEN_SIZE :: any -- alien bigger than human
		root_part.Color = Color3.fromRGB(78, 220, 88)
		root_part.Parent = CONTAINER

		-- create ecs entity for the "alien"
		const entity = world:entity()
		world:set(entity, Transform, CFrame.new(origin :: any))
		world:set(entity, Position, origin)
		world:set(entity, Velocity, vector.zero)
		world:set(entity, Size, ALIEN_SIZE)
		world:set(entity, RootPart, root_part)
		world:add(entity, Gravity)
		world:add(entity, pair(Species, Alien))

		return entity
	end

	prefabs = {
		human = human_create,
		alien = alien_create,
	}
end

--- Applies gravitational acceleration to every entity with the following components:
--- Gravity, (Species, *) and Velocity
const function apply_gravity(dt: number)
	debug.profilebegin("apply_gravity")

	for entity, velocity in q_gravity do
		-- get the species pair relationship target
		const species = world:target(entity, Species) :: Entity?
		assert(species) -- we know it has (Species, *) because of the query

		-- add acceleration * delta time to velocity
		const acceleration = GRAVITATIONAL_ACCELERATION[species]
		velocity += acceleration * dt

		-- update velocity
		world:set(entity, Velocity, velocity)
	end

	debug.profileend()
end

--- Applies velocity to entities along with checking for collisions via raycasting.
--- Upon a collision, bounces the entity in the reflected direction of the collision (unless the reflected velocity is too small)
const function apply_velocity(dt: number)
	debug.profilebegin("apply_velocity")

	-- query part movement
	for _, archetype in q_movement:archetypes() do
		const columns = archetype.columns_map

		-- get Transform, Position, Velocity, RootPart, and Size columns
		const transforms: { CFrame } = columns[Transform]
		const positions: { vector } = columns[Position]
		const velocities: { vector } = columns[Velocity]
		const root_parts: { BasePart } = columns[RootPart]
		const sizes: { vector } = columns[Size]

		for row, entity in archetype.entities do
			-- retrieve position, velocity, root part, size, and transform row values
			const prev_position = positions[row]
			const velocity = velocities[row]
			const root_part = root_parts[row]
			const size = sizes[row]

			-- update position based on velocity * delta time
			const direction = velocity * dt
			local new_position = prev_position + direction

			const dir_n = vector.normalize(direction)

			-- raycast for collision detection
			collision_params.ExcludeInstances = { root_part }

			-- all axes are the same for the current parts so we can just use y
			const half_size = size.y * 0.5

			-- convert scalar half size into vector size in direction of entity direction
			const vec_half_size = dir_n * half_size

			-- raycast from center to half of its size in the direction + the velocity direction
			const origin = prev_position
			const ray_dir = direction + vec_half_size

			-- exclude this part from its own raycast collisions
			collision_params.ExcludeInstances = { root_part }

			const raycast_result = workspace:Raycast(origin :: any, ray_dir :: any, collision_params)
			if raycast_result then
				-- collision detected

				-- retrieve position ray hit and the normal we hit
				const hit_pos: vector = raycast_result.Position :: any
				const normal: vector = raycast_result.Normal :: any

				-- calc. dot product
				const dot = vector.dot(velocity, normal)

				-- reflect dot for bounce
				const bounce = velocity - (2 * dot) * normal
				local new_velocity = bounce * BOUNCE_DAMPING_RATIO

				-- update position to be above the hit surface
				new_position = hit_pos + normal * half_size

				if vector.magnitude(new_velocity) < MIN_BOUNCE then
					-- stop to prevent jittering and weird movement
					new_velocity = vector.zero
				end

				-- update velocity
				velocities[row] = new_velocity
			end

			const new_transform = CFrame.new(new_position :: any)

			-- update position and transform
			positions[row] = new_position
			transforms[row] = new_transform
		end
	end

	debug.profileend()
end

--- Uses BulkMoveTo to update entities' parts' transforms (CFrames).
const function update_transforms(_dt: number)
	debug.profilebegin("update_transforms")

	-- query transforms
	for _, archetype in q_transforms:archetypes() do
		const columns = archetype.columns_map

		-- get RootPart & Transform columns
		const root_parts: { BasePart } = columns[RootPart]
		const transforms: { CFrame } = columns[Transform]

		-- use bulkmoveto for performance and because we already have a setup for its parameters
		workspace:BulkMoveTo(root_parts, transforms)
	end

	debug.profileend()
end

-- register systems
scheduler:schedule(RunService.Heartbeat, apply_gravity, 3)
scheduler:schedule(RunService.Heartbeat, apply_velocity, 2)
scheduler:schedule(RunService.Heartbeat, update_transforms, 1)

-- start running systems
scheduler:run()

-- wait
task.wait(3.5)
print("starting")

-- constants for spawning
const ORIGIN_HEIGHT = 25
const DISPLACEMENT = vector.create(0, 10, 0)
const RANDOMNESS_FACTOR = 5

const RANDOM = Random.new()

-- create human/alien tower starting at ORIGIN_HEIGHT height and going up by HEIGHT_DISP
local position = vector.create(0, ORIGIN_HEIGHT, 0)
while true do
	local offset: vector = RANDOM:NextUnitVector() * RANDOMNESS_FACTOR :: any
	position += DISPLACEMENT + offset

	-- spawn human
	prefabs.human(position, "billbert")
	task.wait(1.5)

	-- spawn alien
	prefabs.alien(position - offset, "steven")
	task.wait(1.5)
end
