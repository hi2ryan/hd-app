--!strict

--[[
Connected Discord-GitHub
@hi2ryan on discord
@hii2ryan on roblox
]]

const ContentProvider = game:GetService("ContentProvider")
const PhysicsService = game:GetService("PhysicsService")
const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const TweenService = game:GetService("TweenService")

const jecs = require(ReplicatedStorage.packages.jecs)

type Entity<T = nil> = jecs.Entity<T>

type SystemFn<T... = ...unknown> = (T...) -> ()
type SystemEntry = { fn: SystemFn, priority: number }

--- A system scheduler.
type Scheduler = {
	_systems: { [RBXScriptSignal]: { SystemEntry } },

	--- Schedules a system to run according to a signal and with a designated priority.
	schedule: <T...>(self: Scheduler, signal: RBXScriptSignal<T...>, SystemFn<T...>, priority: number) -> (),

	--- Runs all scheduled systems according to their signals and priorities.
	run: (self: Scheduler) -> (),
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

--- Determines when an entity should despawn
const DespawnsAt = world:component<<number>>()

--- The TextLabel of an entity's BillboardGui which shows the bounce counter.
const BounceLabel = world:component<<TextLabel>>()

--- Represents how many times an entity has bounced.
const BounceCount = world:component<<number>>()

-- ECS tags

--- Determines whether an entity is affected by gravitational acceleration
const Gravity = world:entity()

--- Determines the species an entity is
--- ex. pairs: (Species, Human); (Species, Alien)
const Species = world:entity()

const Human = world:entity()
const Alien = world:entity()

-- Species-Size map
const SPECIES_SIZE: { [Entity]: vector } = {
	[Human] = vector.one * 2.5, -- human size: (2.5, 2.5, 2.5)
	[Alien] = vector.one * 5    -- alien size: (5, 5, 5)
}

--- Species-Color map
const SPECIES_COLOR: { [Entity]: Color3 } = {
	[Human] = Color3.fromRGB(232, 224, 140),
	[Alien] = Color3.fromRGB(78, 220, 88),
}

--- Species-Lifetime(seconds) map
const SPECIES_LIFETIME: { [Entity]: number } = {
	[Human] = 10,
	[Alien] = 25,
}

-- physics constants
const MIN_BOUNCE = 2 -- when the velocity magnitude is below this threshold, stops bouncing
const BOUNCE_DAMPING_RATIO = 0.6 -- bounce velocity damping multiplier

--- The height at which entities will be deleted and their models will be destroyed.
const DESTROY_HEIGHT = -500

-- species acceleration map
const GRAVITATIONAL_ACCELERATION: { [Entity]: vector } = {
	[Human] = vector.create(0, -100, 0),

	-- Aliens are not affected as much by gravity
	[Alien] = vector.create(0, -25, 0),
}

--- The bounce SFX that will be used when an entity bounces off a surface.
const BOUNCE_SOUND = Instance.new("Sound")
BOUNCE_SOUND.Name = "bounce"
BOUNCE_SOUND.SoundId = "rbxassetid://96931068976144"

-- create cached ecs queries
const q_despawns = world:query(DespawnsAt):cached()
const q_gravity = world:query(Velocity, Gravity, pair(Species, Wildcard)):cached()
const q_movement = world:query(
    Position,
    Velocity,
    Transform,
    RootPart,
    Size,
	BounceCount,
	BounceLabel
):cached()
const q_positions = world:query(Position):cached()
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

--- Plays the `BOUNCE_SOUND` at `position`.
const function play_bounce_sound(position: vector)
	-- create an attachment at the position
	const attachment = Instance.new("Attachment")
	attachment.WorldPosition = position :: any

	-- place bounce sound under the attachment to make the sound emit from position
	const sound = BOUNCE_SOUND:Clone()
	sound.Parent = attachment

	attachment.Parent = workspace

	-- play the sound and destroy the attachment when it ends
	sound:Play()
	sound.Ended:Once(function()
		attachment:Destroy()
	end)
end

--- Creates an entity of a species with parameters for its name and origin.
local prefab: (species: Entity, name: string, origin: vector) -> Entity
do
	-- for creating a white outlined highlight around the parts
	-- use a container model so it can support all the parts instead of the highlight limit
	const CONTAINER = Instance.new("Model")
	CONTAINER.Name = "highlight_container"
	const highlight = Instance.new("Highlight")
	highlight.Adornee = CONTAINER
	highlight.FillTransparency = 1
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.Parent = CONTAINER
	CONTAINER.Parent = workspace

	--- Creates a species' root part by its name, origin, size, color, and species.
	const function create_root_part(name: string, origin: vector, color: Color3, species: Entity): Part
		-- get string name from species entity
		const species_name = if species == Human then "human" else "alien"

		-- create part
		const root_part = Instance.new("Part")
		root_part.Name = `{species_name}_{name}`
		root_part.CFrame = CFrame.new(origin :: any) -- position at origin
		root_part.Anchored = true
		root_part.Shape = Enum.PartType.Wedge
		root_part.Color = color
		root_part.Parent = CONTAINER

		return root_part
	end

	const PRE_TWEEN_SIZE = vector.one * 0.05

	--- Tweens the `root_part`'s size from (essentially) zero. This is purely cosmetic as the
	--- Size component is not modified.
	const function play_spawn_tween(root_part: BasePart, target_size: vector)
		root_part.Size = PRE_TWEEN_SIZE :: any

		const tween = TweenService:Create(
			root_part,
			TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = target_size :: any }
		)
		tween:Play()
	end

	--- Creates the bounce counter BillboardGui for an entity.
	--- Returns the BillboardGui and bounce counter label.
	const function create_billboard(offset: number): (BillboardGui, TextLabel)
		-- create BillboardGui
		const billboard_gui = Instance.new("BillboardGui")
		billboard_gui.LightInfluence = 0
		billboard_gui.AlwaysOnTop = true
		billboard_gui.Size = UDim2.fromScale(2.5, 1)
		billboard_gui.StudsOffset = Vector3.new(0, offset, 0)
		billboard_gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

		-- create "Bounces" title label which will be below bounce count and slightly transparent
		const title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.FontFace = Font.new(
			"rbxassetid://12187372847",
			Enum.FontWeight.SemiBold,
			Enum.FontStyle.Normal
		) -- Barlow semibold
		title.Position = UDim2.fromScale(0, 0.6)
		title.Size = UDim2.fromScale(1, 0.4)
		title.Text = "Bounces"
		title.TextColor3 = Color3.new(1, 1, 1)
		title.TextScaled = true
		title.TextTransparency = 0.25

		-- create yellow to orange gradient
		const gradient = Instance.new("UIGradient")
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 217, 0)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 113, 65)),
		})
		gradient.Rotation = 90
		gradient.Parent = title

		local stroke = Instance.new("UIStroke")
		stroke.StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize
		stroke.Thickness = 0.05
		stroke.Transparency = 0.5
		stroke.Parent = title

		title.Parent = billboard_gui

		-- create bounce count label
		const bounces = Instance.new("TextLabel")
		bounces.BackgroundTransparency = 1
		bounces.FontFace = Font.new(
			"rbxassetid://12187372847",
			Enum.FontWeight.ExtraBold,
			Enum.FontStyle.Normal
		) -- Barlow extra bold
		bounces.Position = UDim2.fromScale(0, 0.1)
		bounces.Size = UDim2.fromScale(1, 0.6)
		bounces.Text = "0"
		bounces.TextColor3 = Color3.new(1, 1, 1)
		bounces.TextScaled = true
		gradient:Clone().Parent = bounces
		stroke:Clone().Parent = bounces
		bounces.Parent = billboard_gui

		return billboard_gui, bounces
	end

	prefab = function(species: Entity, name: string, origin: vector): Entity
		-- get species size & color by predefined constants map
		const size = SPECIES_SIZE[species]
		const color = SPECIES_COLOR[species]
		const lifetime = SPECIES_LIFETIME[species]

		-- create root part
		const root_part = create_root_part(name, origin, color, species)

		-- create bounce count billboard
		const offset = if species == Human then 2 else 3
		const billboard, bounce_label = create_billboard(offset)
		billboard.Parent = root_part

		-- create entity and assign components
		const entity = world:entity()

		-- set the entity's initial CFrame (Transform) to be origin
		world:set(entity, Transform, CFrame.new(origin :: any))

		-- set the entity's initial position to origin
		world:set(entity, Position, origin)

		-- zero the entity's velocity
		world:set(entity, Velocity, vector.zero)

		-- set the entity's size
		world:set(entity, Size, size)

		-- assign the entity's rootpart
		world:set(entity, RootPart, root_part)

		-- set the entity to despawn at to now + lifetime
		world:set(entity, DespawnsAt, os.clock() + lifetime)

		-- initialize entity bounce count to 0
		world:set(entity, BounceCount, 0)

		-- assign bounce count TextLabel to entity
		world:set(entity, BounceLabel, bounce_label)

		-- add the Gravity tag to the entity to apply gravitational acceleration
		world:add(entity, Gravity)

		-- add the species pair to the entity
		world:add(entity, pair(Species, species))

		-- play spawn tween
		play_spawn_tween(root_part, size)

		return entity
	end
end

--- Despawns entities based on their species' lifetime.
const function entities_despawn(dt: number)
	debug.profilebegin("entities_despawn")

	-- cache os.clock call to prevent constantly calling it for comparison
	const now = os.clock()

	for _, archetype in q_despawns:archetypes() do
		const columns = archetype.columns_map
		const entities = archetype.entities

		-- get DespawnsAt column
		const despawn_times: { number } = columns[DespawnsAt]

		-- iterate backwards to prevent iterator invalidation when an entity is deleted
		for row = #entities, 1, -1 do
			const entity = entities[row]

			-- check if we are past their despawn time
			const despawns_at = despawn_times[row]
			if now > despawns_at then
				-- they should despawn now, delete entity
				world:delete(entity)
			end
		end
	end

	debug.profileend()
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

		-- get Transform, Position, Velocity, RootPart, Size, BounceCount, and BounceLabel columns
		const transforms: { CFrame } = columns[Transform]
		const positions: { vector } = columns[Position]
		const velocities: { vector } = columns[Velocity]
		const root_parts: { BasePart } = columns[RootPart]
		const sizes: { vector } = columns[Size]
		const bounce_counts: { number } = columns[BounceCount]
		const bounce_labels: { TextLabel } = columns[BounceLabel]

		for row, entity in archetype.entities do
			-- retrieve position, velocity, root part, size, and transform row values
			const prev_position = positions[row]
			const velocity = velocities[row]
			const root_part = root_parts[row]
			const size = sizes[row]

			-- update position based on velocity * delta time
			const direction = velocity * dt
			local new_position = prev_position + direction

			-- all axes are the same for the current parts so we can just use y
			const half_size = size.y * 0.5

			-- convert scalar half size into vector in the entity's direction
			const vec_half_size = vector.normalize(direction) * half_size

			-- raycast from center to half of its size in the direction + the velocity direction
			const origin = prev_position
			const ray_dir = direction + vec_half_size

			-- exclude this part from its own collision check raycast
			collision_params.ExcludeInstances = { root_part }

			-- raycast to detect collisions
			const raycast_result = workspace:Raycast(origin :: any, ray_dir :: any, collision_params)
			if raycast_result then
				-- collision detected

				-- retrieve position ray hit and the normal we hit
				const hit_pos: vector = raycast_result.Position :: any
				const normal: vector = raycast_result.Normal :: any

				-- calculate the velocity that went into the surface normal (dot product)
				const dot = vector.dot(velocity, normal)

				-- reflect velocity by surface normal
				const bounce = velocity - (2 * dot) * normal

				-- reduce bounce velocity (damp) so it eventually stops
				local new_velocity = bounce * BOUNCE_DAMPING_RATIO

				-- set position to be above the hit surface
				new_position = hit_pos + normal * half_size

				if vector.magnitude(new_velocity) < MIN_BOUNCE then
					-- stop to prevent jittering and weird movement
					new_velocity = vector.zero
				else
					-- add 1 to bounce count
					const prev_bounce_count = bounce_counts[row]
					const bounce_label = bounce_labels[row]

					const bounce_count = prev_bounce_count + 1

					-- update bounce count
					bounce_counts[row] = bounce_count

					-- update bounce count display
					bounce_label.Text = tostring(bounce_count)

					-- play bounce sound at the hit position
					play_bounce_sound(hit_pos)
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

--- System that deletes all entities under `DESTROY_HEIGHT`
const function respect_bounds(dt: number)
	debug.profilebegin("respect_bounds")

	-- iterate all archetypes of q_positions query (Position)
	for _, archetype in q_positions:archetypes() do
		const columns = archetype.columns_map
		const entities = archetype.entities

		-- retrieve positions column
		const positions: { vector } = columns[Position]

		-- iterate backwards to prevent iterator invalidation when an entity is deleted
		for row = #entities, 1, -1 do
			const entity = entities[row]

			-- retrieve entity position
			const position = positions[row]

			-- check if the entity's y position is below the destroy height
			if position.y < DESTROY_HEIGHT then
				-- too far down, delete entity
				-- this will, in turn, delete the RootPart due to the removed hook
				world:delete(entity)
			end
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
-- ordering: despawn entities -> apply gravity -> apply velocity -> destroy entities out of bounds -> update transforms
-- we despawn entities first to prevent running through all other physics systems for a dead, stale entity
scheduler:schedule(RunService.Heartbeat, entities_despawn, 5)
scheduler:schedule(RunService.Heartbeat, apply_gravity, 4)
scheduler:schedule(RunService.Heartbeat, apply_velocity, 3)
scheduler:schedule(RunService.Heartbeat, respect_bounds, 2)
scheduler:schedule(RunService.Heartbeat, update_transforms, 1)

-- add hook to destroy RootPart after an entity with the component is deleted
world:removed(RootPart, function(e: Entity, id: jecs.Id, delete: boolean?)
	if not delete then
		-- entity was not deleted
		-- in this case this will never happen because we do not call world:remove(e, RootPart)
		return
	end

	-- destroy rootpart instance
	const root_part = world:get(e, RootPart)
	if root_part then
		root_part:Destroy()
	end
end)

task.spawn(function()
	-- preload bounce sound
	ContentProvider:PreloadAsync({BOUNCE_SOUND})
end)

-- start running systems
scheduler:run()

-- wait for player to load and stuff
task.wait(3.5)
print("starting")

-- constants for spawning
const ORIGIN_HEIGHT = 25 -- initial height
const DISPLACEMENT = vector.create(0, 10, 0) -- each iteration adds this
const RANDOMNESS_STRENGTH = 5 -- how strong to apply random offset (multiplier)

const RANDOM = Random.new()

-- start spawning humans and aleins starting at ORIGIN_HEIGHT height and going up by DISPLACEMENT
local position = vector.create(0, ORIGIN_HEIGHT, 0)
while true do
	-- add random offset
	local offset: vector = RANDOM:NextUnitVector() * RANDOMNESS_STRENGTH :: any
	position += DISPLACEMENT + offset

	-- spawn human
	prefab(Human, "billbert", position)
	task.wait(1.5)

	-- spawn alien
	prefab(Alien, "steven", position - offset)
	task.wait(1.5)
end
