extends Area2D

@onready var sprite: Sprite2D = $Sprite
@onready var label_node: Label = $Label
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var shape: RectangleShape2D = collision_shape.shape

const GRID_SIZE = 16
const GRID_WIDTH = 32
const GRID_HEIGHT = 24

var display_name: String = ""
var label: String = ""
var interaction: String = ""
var scene_transition: Node = null
var id: String = ""
var raw_size: float = 32.0
var dialogue_tree := {}

func grid_to_world(grid_pos: Vector2) -> Vector2:
	return Vector2(
		(grid_pos.x - GRID_WIDTH / 2) * GRID_SIZE,
		(grid_pos.y - GRID_HEIGHT / 2) * GRID_SIZE
	)

func set_location(grid_pos: Vector2i):
	position = grid_to_world(grid_pos)

func _ready():
	add_to_group("interactables")
	if id == "":
		id = "obj_" + name.to_lower()

	var client = get_node_or_null("/root/AIClient")
	if client:
		client.connect("image_ready", Callable(self, "_on_image_ready"))
	else:
		print("⚠️ AIClient singleton not found in Object._ready()")

	if is_instance_valid(label_node):
		label_node.visible = false
	else:
		print("⚠️ Label node missing at _ready()")

	connect("mouse_entered", Callable(self, "_on_mouse_entered"))
	connect("mouse_exited", Callable(self, "_on_mouse_exited"))
	connect("input_event", Callable(self, "_on_input_event"))

func _on_mouse_entered():
	if is_instance_valid(label_node):
		label_node.visible = true

func _on_mouse_exited():
	if is_instance_valid(label_node):
		label_node.visible = false

func _on_input_event(viewport, event, shape_idx):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		on_interact()

func set_data(data: Dictionary):
	await ready
	if data.has("name"):
		display_name = data["name"]
	label = data.get("label", "")
	interaction = data.get("interaction", "")
	dialogue_tree = data.get("dialogue_tree", {})

	if data.has("size"):
		raw_size = float(data["size"])

	if is_instance_valid(label_node):
		label_node.text = label
	else:
		print("⚠️ label_node not ready when set_data was called")

	if data.has("action"):
		set_meta("action_data", data["action"])
	if data.has("location"):
		set_location(Vector2i(data["location"][0], data["location"][1]))
	if data.has("id"):
		id = "obj_" + str(data["id"])

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
				var tex_size = tex.get_size()
				if tex_size.x == 0 or tex_size.y == 0:
					print("⚠️ Invalid texture size for:", path)
					return
				var scale_y = raw_size / tex_size.y
				sprite.scale = Vector2(scale_y, scale_y)
				shape.extents = tex_size * sprite.scale * 0.5
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

func on_interact():
	print("🖱️ Object clicked:", display_name)
	get_node("/root/Game").record_event("interacted with object: \"%s\"" % display_name)

	if is_instance_valid(label_node):
		label_node.visible = true
		await get_tree().create_timer(1.0).timeout
		label_node.visible = false

	var dm = get_node("/root/Game/DialogueManager")
	if dm:
		if dialogue_tree.size() > 0:
			dm.start_dialogue(self, dialogue_tree)
		elif interaction != "":
			dm.start_dialogue(self, {
				"root": {
					"npc_line": interaction,
					"responses": []
				}
			})
	else:
		print("⚠️ DialogueManager not found in scene tree")

	if has_meta("action_data"):
		do_action(get_meta("action_data"))

func do_action(action: Dictionary):
	if action.has("transform"):
		if action["transform"].has("scale"):
			scale = Vector2(action["transform"]["scale"][0], action["transform"]["scale"][1])
		if action["transform"].has("move"):
			position += Vector2(action["transform"]["move"][0], action["transform"]["move"][1])

	if action.has("delete") and action["delete"]:
		queue_free()

	if action.has("color") and is_instance_valid(sprite):
		sprite.modulate = Color(action["color"][0], action["color"][1], action["color"][2])

	if action.has("trigger") and action["trigger"] == "next_scene" and scene_transition:
		get_node("/root/Game").record_event("interacted with %s" % display_name)
		scene_transition.next_scene()

func get_dialogue_tree():
	return dialogue_tree

func _on_image_ready(received_id: String, path: String) -> void:
	if received_id == id:
		print("🎯 Object loading texture from:", path)
		set_sprite(path)
