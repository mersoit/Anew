extends Node2D

@onready var camera: Camera2D = $Camera2D
@onready var background: Sprite2D = $Background
@onready var ai_client: Node = $AIClient
@onready var loading_label: Label = $UI/LoadingLabel
@onready var player_scene: PackedScene = preload("res://Scenes/Player.tscn")
@onready var npc_scene: PackedScene = preload("res://Scenes/NPC.tscn")
@onready var object_scene: PackedScene = preload("res://Scenes/Object.tscn")
@onready var dialogue_manager: Node = $DialogueManager

var current_scene_index: int = 1
var topic: String = "High Fantasy"
var theme: String = "Combat"
var player_history: Array[String] = []
var scene_json := {}
var image_paths := {}
var all_images_finalized := false
var highlight_slides: Array = []
var progression_flags := {}
var expected_image_ids: Array = []
var scene_generation_in_progress: bool = false

func _ready():
	camera.make_current()
	ai_client.connect("scene_json_ready", _on_scene_json_received)
	ai_client.connect("image_ready", _on_image_ready)
	ai_client.connect("all_images_ready", _on_all_images_ready)
	ai_client.connect("ending_slides_ready", _on_ending_slides_ready)
	dialogue_manager.connect("dialogue_finished_with_outcome", _on_dialogue_finished_with_outcome)
	_setup_label()
	$Camera2D.position = Vector2(0, 0)
	_clear_scene()
	background.centered = true
	background.position = Vector2(0, 0)
	var screen_size = get_viewport().get_visible_rect().size
	var bg_size = Vector2(1024, 1024)
	if screen_size.x > bg_size.x or screen_size.y > bg_size.y:
		var scale_factor = max(screen_size.x / bg_size.x, screen_size.y / bg_size.y)
		camera.zoom = Vector2(1 / scale_factor, 1 / scale_factor)
	print("✅ Game Ready")

func _setup_label():
	loading_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	loading_label.anchor_left = 0.0
	loading_label.anchor_right = 1.0
	loading_label.anchor_top = 0.0
	loading_label.anchor_bottom = 0.0
	loading_label.offset_left = 32
	loading_label.offset_right = -32
	loading_label.offset_top = 20
	loading_label.offset_bottom = 100

func handle_scene_generation_failure(scene_index: int):
	print("🚨 Scene generation failed after all retries. Resetting and regenerating from scratch...")
	scene_generation_in_progress = false
	generate_scene(scene_index)

func generate_scene(scene_id: int):
	if scene_generation_in_progress and scene_id == current_scene_index:
		print("⏳ Scene %d generation is already in progress. Ignoring duplicate request." % scene_id)
		return
	print("🚀 Generating scene %d with topic '%s' and theme '%s'" % [scene_id, topic, theme])
	scene_generation_in_progress = true
	loading_label.text = "Generating scene %d..." % scene_id
	image_paths.clear()
	expected_image_ids.clear()
	all_images_finalized = false
	current_scene_index = scene_id
	var history := _build_history_summary()
	ai_client.request_scene_json(topic, theme, history, scene_id)

func _on_scene_json_received(received_scene_json: Dictionary) -> void:
	print("📥 Game received scene JSON")
	self.scene_json = received_scene_json
	progression_flags = {}
	if scene_json.has("progression_conditions"):
		for cond in scene_json["progression_conditions"]:
			progression_flags[cond] = false
	if scene_json.has("narrative"):
		loading_label.text = scene_json["narrative"]
	else:
		loading_label.text = "Loading scene..."
	await get_tree().process_frame
	print("🎯 Requesting image generation tasks...")
	expected_image_ids = ai_client.get_expected_image_ids(scene_json, current_scene_index)
	ai_client.request_all_images(scene_json, current_scene_index)

func _on_image_ready(id: String, path: String):
	image_paths[id] = path
	print("📸 Image ready:", id, "→", path)
	if not all_images_finalized and expected_image_ids.size() > 0:
		var all_ready = true
		for expected_id in expected_image_ids:
			if not image_paths.has(expected_id):
				all_ready = false
				break
		if all_ready:
			_on_all_images_ready()

func _on_all_images_ready():
	if all_images_finalized:
		print("⚠️ Scene already finalized, skipping redundant build.")
		return
	var missing_images := []
	for expected_id in expected_image_ids:
		if not image_paths.has(expected_id):
			missing_images.append(expected_id)
	if not missing_images.is_empty():
		print("⏳ Waiting for missing images before building scene:", missing_images)
		return
	print("✅ All images finalized. Building scene now...")
	all_images_finalized = true
	_build_scene()

func _build_scene():
	_clear_scene()
	if image_paths.has("scene_%d_background" % current_scene_index):
		var bg_path: String = image_paths["scene_%d_background" % current_scene_index]
		var img := Image.new()
		var file := FileAccess.open(bg_path, FileAccess.READ)
		if file:
			var err := img.load_png_from_buffer(file.get_buffer(file.get_length()))
			if err == OK:
				background.texture = ImageTexture.create_from_image(img)
	else:
		print("⚠️ Background image not found in image_paths for scene %d" % current_scene_index)

	if scene_json.has("player"):
		var p = player_scene.instantiate()
		p.position = _grid_to_pos(scene_json["player"].get("location", [7, 6]))
		if image_paths.has("scene_%d_player" % current_scene_index):
			p.set_sprite(image_paths["scene_%d_player" % current_scene_index])
		add_child(p)

	for npc_data in scene_json.get("npcs", []):
		var n = npc_scene.instantiate()
		n.position = _grid_to_pos(npc_data.get("location", [0, 0]))
		n.set_data(npc_data)
		var npc_id = "scene_%d_npc_%s" % [current_scene_index, npc_data.get("id", "")]
		if image_paths.has(npc_id):
			n.set_sprite(image_paths[npc_id])
		n.visible = npc_data.get("visible_on_start", true)
		add_child(n)

	for obj_data in scene_json.get("objects", []):
		var o = object_scene.instantiate()
		o.position = _grid_to_pos(obj_data.get("location", [0, 0]))
		o.set_data(obj_data)
		var obj_id = "scene_%d_obj_%s" % [current_scene_index, obj_data.get("id", "")]
		if image_paths.has(obj_id):
			o.set_sprite(image_paths[obj_id])
		o.visible = obj_data.get("visible_on_start", true)
		add_child(o)

	loading_label.text = ""
	scene_generation_in_progress = false 

func next_scene():
	if scene_generation_in_progress:
		print("⏳ Scene generation already in progress, skipping duplicate next_scene call.")
		return
	current_scene_index += 1
	_clear_scene()
	generate_scene(current_scene_index)

func _on_dialogue_finished_with_outcome(outcome: String):
	if outcome != "":
		player_history.append("- " + outcome)

func _build_history_summary() -> String:
	return "\n".join(player_history)

func _grid_to_pos(grid: Array) -> Vector2:
	var tile_w = 40
	var tile_h = 40
	return Vector2(grid[0] * tile_w, grid[1] * tile_h)

func set_topic_and_theme(t: String, th: String) -> void:
	topic = t
	theme = th
	current_scene_index = 1
	player_history.clear()
	highlight_slides.clear()
	generate_scene(current_scene_index)

func record_event(event: String) -> void:
	player_history.append(event)

func _on_interact(target_node):
	if target_node.has_method("get_dialogue_tree"):
		var tree = target_node.get_dialogue_tree()
		if tree.size() > 0:
			dialogue_manager.start_dialogue(target_node, tree)
		else:
			print("🧱 No dialogue for this entity.")

func end_game():
	loading_label.text = "Gathering your story highlights..."
	ai_client.get_ending_slides()

func _on_ending_slides_ready(slides: Array):
	highlight_slides = slides
	_show_ending_slides()

func _show_ending_slides():
	_clear_scene()
	loading_label.text = "Your Journey Highlights:"
	if highlight_slides.is_empty():
		loading_label.text = "No journey highlights available."
		return
	var i = 0
	for slide in highlight_slides:
		print("Ending Slide #%d" % (i + 1))
		print("Summary: %s" % slide.get("summary", ""))
		print("Image: %s" % slide.get("image", ""))
		i += 1
	loading_label.text = "1. " + highlight_slides[0].get("summary", "")

func switch_dialogue_node(target_id: String, new_root: String):
	print("🎯 Attempting to switch dialogue for %s to root: %s" % [target_id, new_root])
	for child in get_children():
		if not is_instance_valid(child): continue
		var child_id = ""
		if child.has_method("get") and child.get("id") != null:
			child_id = child.get("id")
		if child_id == target_id or child_id.begins_with(target_id + "_"):
			print("✅ Found matching entity: %s (id: %s)" % [child.name, child_id])
			if child.has_method("get_dialogue_tree"):
				var tree = child.get_dialogue_tree()
				if tree != null and typeof(tree) == TYPE_DICTIONARY:
					if tree.has(new_root):
						var new_tree = tree.duplicate(true)
						new_tree["root"] = new_tree[new_root]
						if child.has_method("set"):
							child.set("dialogue_tree", new_tree)
							print("✅ Successfully switched %s dialogue to start at: %s" % [target_id, new_root])
					else:
						print("⚠️ No such root node: %s in %s's dialogue tree" % [new_root, target_id])
				else:
					print("⚠️ Invalid dialogue tree for %s" % target_id)
			return
	print("⚠️ Could not find target with id: %s" % target_id)

# --- THIS IS THE MISSING FUNCTION ---
func reveal_entities(ids_to_reveal: Array):
	print("✨ Revealing entities:", ids_to_reveal)
	for entity_id in ids_to_reveal:
		var found_node = null
		for child in get_children():
			if child.has_method("get") and child.get("id") != null:
				var child_id = child.get("id")
				if child_id == entity_id or child_id.begins_with(entity_id + "_"):
					found_node = child
					break
		
		if found_node:
			if not found_node.visible:
				print("  -> Found and revealing:", found_node.name, "(id:", found_node.get("id"), ")")
				found_node.visible = true
			else:
				print("  -> Entity", found_node.name, "is already visible.")
		else:
			print("  -> ⚠️ Could not find entity with id:", entity_id, "to reveal.")

func _clear_scene():
	for child in get_children():
		if (child is CharacterBody2D or child is Area2D) and child != self:
			child.queue_free()

func set_progression_flag(flag: String):
	if progression_flags.has(flag):
		progression_flags[flag] = true
		print("✅ Progression flag set:", flag)
