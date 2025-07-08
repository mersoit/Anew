extends CharacterBody2D

@export var speed := 100.0
@onready var sprite: Sprite2D = $Sprite
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

var target_position := Vector2.ZERO
var click_timer := Timer.new()
var last_clicked_target: Node = null
var interaction_target: Node = null
var interactables := []
var id: String = "player"
var game = get_node_or_null("/root/Game")

func _ready():
	add_child(click_timer)
	click_timer.wait_time = 0.3
	click_timer.one_shot = true

	# Optional: setup proximity via Area2D if needed, else remove
	if is_instance_valid(collision_shape):
		if collision_shape.get_parent() is Area2D and collision_shape.get_parent() != self:
			var area = collision_shape.get_parent()
			area.body_entered.connect(_on_body_entered)
			area.body_exited.connect(_on_body_exited)

	var client = get_node_or_null("/root/AIClient")
	if client:
		client.connect("image_ready", Callable(self, "_on_image_ready"))
	else:
		print("⚠️ AIClient singleton not found in Player._ready()")

	target_position = position

func _physics_process(delta):
	if interaction_target and position.distance_to(interaction_target.global_position) < 36:
		velocity = Vector2.ZERO
		_interact_with_target()		
		return
	var game = get_node_or_null("/root/Game")
	if game:
		var dm = game.get_node_or_null("DialogueManager")
		if dm and dm.visible and dm.current_target:
			dm.try_close_on_player_distance(self, dm.current_target, 64.0) # Adjust distance as needed

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
				if last_clicked_target == obj and click_timer.time_left > 0:
					print("🖱️ Double clicked:", obj.name)
					obj.on_interact()
					interaction_target = null
					click_timer.stop()
				else:
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
			make_edge_white_transparent(img, 0.97)
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

func _is_white(c: Color, threshold := 0.97) -> bool:
	return c.r >= threshold and c.g >= threshold and c.b >= threshold

func make_edge_white_transparent(img: Image, threshold := 0.97):
	img.convert(Image.FORMAT_RGBA8)
	var w = img.get_width()
	var h = img.get_height()
	var visited := {}
	var queue := []
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
				if not visited.has(n):
					if _is_white(img.get_pixel(n.x, n.y), threshold):
						queue.append(n)
						visited[n] = true
						

func _on_image_ready(received_id: String, path: String) -> void:
	if received_id == id:
		print("🎯 Player loading texture from:", path)
		set_sprite(path)
