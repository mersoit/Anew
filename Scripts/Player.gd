extends CharacterBody2D

@export var speed := 100.0
@export var interaction_distance := 36.0  # Make this configurable
@onready var sprite: Sprite2D = $Sprite
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

var target_position := Vector2.ZERO
var click_timer := Timer.new()
var last_clicked_target: Node = null
var interaction_target: Node = null
var interactables := []
var id: String = "player"
var game = null  # Will be set in _ready

func _ready():
	add_to_group("player")
	add_child(click_timer)
	click_timer.wait_time = 0.3
	click_timer.one_shot = true
	
	game = get_node_or_null("/root/Game")

	# Optional: setup proximity via Area2D if needed, else remove
	if is_instance_valid(collision_shape):
		if collision_shape.get_parent() is Area2D and collision_shape.get_parent() != self:
			var area = collision_shape.get_parent()
			area.body_entered.connect(_on_body_entered)
			area.body_exited.connect(_on_body_exited)

	var client = get_node_or_null("/root/Game/AIClient")  # Use full path
	if client:
		client.connect("image_ready", Callable(self, "_on_image_ready"))
	else:
		print("⚠️ AIClient not found in Player._ready()")

func _physics_process(delta):
	# Check if we should interact
	if interaction_target and position.distance_to(interaction_target.global_position) < interaction_distance:
		velocity = Vector2.ZERO
		_interact_with_target()		
		return
		
	# Check if we should close dialogue due to distance
	var game = get_node_or_null("/root/Game")
	if game:
		var dm = game.get_node_or_null("DialogueManager")
		if dm and dm.visible and dm.current_target:
			dm.try_close_on_player_distance(self, dm.current_target, 64.0)

	# Move towards target
	if position.distance_to(target_position) > 4:
		var direction = (target_position - position).normalized()
		velocity = direction * speed
		move_and_slide()
	else:
		velocity = Vector2.ZERO

func _unhandled_input(event):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var click_pos = get_global_mouse_position()
		target_position = click_pos

		var space_state = get_world_2d().direct_space_state
		var point_query := PhysicsPointQueryParameters2D.new()
		point_query.position = click_pos
		point_query.collide_with_areas = true
		point_query.collide_with_bodies = true

		var result = space_state.intersect_point(point_query, 32)
		interaction_target = null

		for res in result:
			var obj = res.collider
			if obj and obj.is_in_group("interactables") and obj.has_method("on_interact"):
				interaction_target = obj
				
				# Check if we're already close enough
				if global_position.distance_to(obj.global_position) < interaction_distance:
					# We're close enough, interact immediately
					if last_clicked_target == obj and click_timer.time_left > 0:
						print("🖱️ Double clicked:", obj.name)
						obj.on_interact()
						interaction_target = null
						click_timer.stop()
					else:
						# Single click while close - interact immediately
						obj.on_interact()
						interaction_target = null
					last_clicked_target = obj
					click_timer.start()
				else:
					# We're too far, set as target to walk towards
					last_clicked_target = obj
					click_timer.start()
				break

func _interact_with_target():
	if interaction_target and interaction_target.has_method("on_interact"):
		interaction_target.on_interact()
	interaction_target = null

func _draw():
	draw_circle(Vector2.ZERO, 96, Color(0.2, 0.8, 1.0, 0.2))

func _on_body_entered(body):
	if body not in interactables:
		interactables.append(body)

func _on_body_exited(body):
	if body in interactables:
		interactables.erase(body)

func set_sprite(path: String):
	await ready
	var img := Image.new()
	var file := FileAccess.open(path, FileAccess.READ)
	if file:
		var err := img.load_png_from_buffer(file.get_buffer(file.get_length()))
		if err == OK:
			var tex := ImageTexture.create_from_image(img)
			if is_instance_valid(sprite):
				sprite.texture = tex
				var target_size = Vector2(32, 32)
				var tex_size = tex.get_size()
				sprite.scale = target_size / tex_size
			else:
				print("❌ sprite is null in set_sprite")
		else:
			print("❌ Failed to decode image from path:", path)
	else:
		print("❌ Failed to load image file at:", path)

func make_edge_white_transparent(img: Image, threshold := 0.95):
	img.convert(Image.FORMAT_RGBA8)
	var w = img.get_width()
	var h = img.get_height()
	var visited := {}
	var queue := []

	# --- 1. Flood-fill edge background ---
	for x in range(w):
		for y in [0, h-1]:
			if _is_white(img.get_pixel(x, y), threshold):
				var v = Vector2i(x, y)
				queue.append(v)
				visited[v] = true
	for y in range(h):
		for x in [0, w-1]:
			if _is_white(img.get_pixel(x, y), threshold):
				var v = Vector2i(x, y)
				queue.append(v)
				visited[v] = true
	
	var dirs = [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]
	while not queue.is_empty():
		var v: Vector2i = queue.pop_front()
		img.set_pixel(v.x, v.y, Color(0,0,0,0))
		for d in dirs:
			var n = v + d
			if n.x >= 0 and n.x < w and n.y >= 0 and n.y < h:
				if not visited.has(n) and _is_white(img.get_pixel(n.x, n.y), threshold):
					queue.append(n)
					visited[n] = true

	# --- 2. Aggressive cleanup: remove ALL remaining (isolated) white pixels ---
	for y in range(h):
		for x in range(w):
			var pixel = img.get_pixel(x, y)
			if _is_white(pixel, threshold) and pixel.a > 0.5:
				img.set_pixel(x, y, Color(0,0,0,0))

	# --- 3. Smart pass: Remove small background islands inside sprite using local neighborhood ---
	# (removes "holes" of off-white inside sprite body)
	var to_clear := []
	for y in range(1, h-1):
		for x in range(1, w-1):
			var c = img.get_pixel(x, y)
			if _is_white(c, threshold) and c.a > 0.5:
				var neighbor_alpha_sum = 0.0
				var neighbor_count = 0
				for dy in [-1,0,1]:
					for dx in [-1,0,1]:
						if dx == 0 and dy == 0:
							continue
						var n = img.get_pixel(x+dx, y+dy)
						neighbor_alpha_sum += n.a
						neighbor_count += 1
				if neighbor_alpha_sum < neighbor_count * 0.5:
					# Most neighbors are already transparent, so this is likely background
					to_clear.append(Vector2i(x, y))
	for v in to_clear:
		img.set_pixel(v.x, v.y, Color(0,0,0,0))

func _is_white(c: Color, threshold := 0.95) -> bool:
	var brightness = (c.r + c.g + c.b) / 3.0
	return brightness >= threshold and c.a > 0.5
						

func _on_image_ready(received_id: String, path: String) -> void:
	if received_id == id:
		print("🎯 Player loading texture from:", path)
		set_sprite(path)
