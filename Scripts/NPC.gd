extends Area2D

@export var speed := 100.0
@onready var sprite: Sprite2D = $Sprite
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

var target_position := Vector2.ZERO
var click_timer := Timer.new()
var last_clicked_target: Node = null
var interaction_target: Node = null
var interactables := []
var id: String = ""
var dialogue_tree := {}
var scene_transition: Node = null

func _ready():
	add_child(click_timer)
	click_timer.wait_time = 0.3
	click_timer.one_shot = true

	add_to_group("interactables")

	# If you want proximity, set up signals here using the main collision shape or another Area2D if needed

	var client = get_node_or_null("/root/AIClient")
	if client:
		client.connect("image_ready", Callable(self, "_on_image_ready"))
	else:
		print("⚠️ AIClient singleton not found in NPC._ready()")

	connect("input_event", Callable(self, "_on_input_event"))

func _process(delta):
	if interaction_target and global_position.distance_to(interaction_target.global_position) < 36:
		_interact_with_target()
		return

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

func _on_input_event(viewport, event, shape_idx):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		on_interact()

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

func _on_image_ready(received_id: String, path: String) -> void:
	if received_id == id:
		print("🎯 NPC loading texture from:", path)
		set_sprite(path)

func set_data(data: Dictionary):
	if data.has("id"):
		id = "npc_" + str(data["id"])
	if data.has("dialogue_tree"):
		dialogue_tree = data["dialogue_tree"]

func get_dialogue_tree():
	return dialogue_tree

func on_interact():
	print("🗣️ NPC interacted:", name)
	if get_dialogue_tree().size() > 0:
		print("🧩 Dialogue available for", name)
		var root = get_tree().get_root()
		var game_node = root.get_node("Game")
		if game_node:
			game_node._on_interact(self)
	else:
		print("🧱 No dialogue available for", name)
