extends Node2D

@onready var camera: Camera2D = $Camera2D
@onready var background: Sprite2D = $Background
@onready var ai_client: Node = $AIClient
@onready var loading_label: Label = $UI/LoadingLabel
@onready var player_scene: PackedScene = preload("res://scenes/Player.tscn")
@onready var npc_scene: PackedScene = preload("res://scenes/NPC.tscn")
@onready var object_scene: PackedScene = preload("res://scenes/Object.tscn")
@onready var scene_transition: Node = $SceneTransition
@onready var dialogue_manager: Node = $DialogueManager

var current_scene_index: int = 1
var topic: String = "High Fantasy"
var theme: String = "Combat"
var previous_outcome: String = ""
var scene_json := {}
var image_paths := {}
var player_history: Array[String] = []
var waiting_for_images := false
var scene_ready_queued := false
var all_images_finalized := false
var highlight_slides: Array = []
var game_ending: bool = false
var next_scene_delay_timer: Timer = null
var progression_flags := {}
var expected_image_ids: Array = []

func _ready():
	camera.make_current()
	ai_client.connect("scene_json_ready", _on_scene_json_received)
	ai_client.connect("image_ready", _on_image_ready)
	ai_client.connect("all_images_ready", _on_all_images_ready)
	ai_client.connect("ending_slides_ready", _on_ending_slides_ready)
	scene_transition.connect("scene_ready", _on_scene_ready)
	scene_transition.connect("end_game", _on_end_game)
	dialogue_manager.connect("dialogue_finished_with_outcome", _on_dialogue_finished)
	dialogue_manager.connect("trigger_next_scene", _on_trigger_next_scene)
	_setup_label()
	$Camera2D.position = Vector2(0, 0)
	_clear_scene()

	background.centered = true
	background.position = Vector2(0, 0)
	background.scale = Vector2(1, 1)

	var screen_size = get_viewport().get_visible_rect().size
	var bg_size = Vector2(1024, 1024)
	if screen_size.x > bg_size.x or screen_size.y > bg_size.y:
		var scale_factor = max(screen_size.x / bg_size.x, screen_size.y / bg_size.y)
		camera.zoom = Vector2(1 / scale_factor, 1 / scale_factor)
	next_scene_delay_timer = Timer.new()
	next_scene_delay_timer.one_shot = true
	add_child(next_scene_delay_timer)
	next_scene_delay_timer.timeout.connect(_on_next_scene_delay_timeout)
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

func _on_scene_ready(scene_index: int):
	if not all_images_finalized:
		scene_ready_queued = true
		print("⏳ Scene build delayed until images are finalized")
		return
	current_scene_index = scene_index
	_clear_scene()
	generate_scene(current_scene_index)

func generate_scene(scene_id: int):
	print("🚀 Generating scene %d with topic '%s' and theme '%s'" % [scene_id, topic, theme])
	loading_label.text = "Generating scene %d..." % scene_id
	ai_client.current_scene_id = "scene%d" % scene_id
	var history := _build_history_summary()
	ai_client.request_scene_json(topic, theme, history)
	waiting_for_images = true
	all_images_finalized = false
	scene_ready_queued = false

func _on_scene_json_received(scene_json: Dictionary) -> void:
	print("📥 Game received scene JSON")
	self.scene_json = scene_json
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
	ai_client.request_all_images(scene_json, current_scene_index)
	expected_image_ids = ai_client.get_expected_image_ids(scene_json, current_scene_index)

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
	print("✅ All images finalized. Building scene now...")
	_build_scene()

func _build_scene():
	all_images_finalized = true
	if image_paths.has("scene_%d_background" % current_scene_index):
		var bg_path: String = image_paths["scene_%d_background" % current_scene_index]
		var img := Image.new()
		var file := FileAccess.open(bg_path, FileAccess.READ)
		if file:
			var err := img.load_png_from_buffer(file.get_buffer(file.get_length()))
			if err == OK:
				background.texture = ImageTexture.create_from_image(img)
			else:
				print("⚠️ Background image decode failed.")
		else:
			print("⚠️ Could not read background image file.")
	else:
		print("⚠️ Background image not found in image_paths.")

	for child in get_children():
		if child is CharacterBody2D and child != self:
			child.queue_free()

	if scene_json.has("player"):
		var p = player_scene.instantiate()
		p.position = _grid_to_pos(scene_json["player"].get("location", [7, 6]))
		if image_paths.has("scene_%d_player" % current_scene_index):
			p.set_sprite(image_paths["scene_%d_player" % current_scene_index])
		add_child(p)

	for npc_data in scene_json.get("npcs", []):
		var positions = npc_data.get("locations", [])
		if positions.is_empty():
			positions = [npc_data.get("location", [0, 0])]
		for pos in positions:
			var n = npc_scene.instantiate()
			n.position = _grid_to_pos(pos)
			n.set_data(npc_data)
			n.set("dialogue_tree", npc_data.get("dialogue_tree", {}))
			n.set("scene_transition", scene_transition)
			var npc_id = "scene_%d_npc_%s" % [current_scene_index, npc_data.get("id", "")]
			if image_paths.has(npc_id):
				n.set_sprite(image_paths[npc_id])
			add_child(n)

	for obj_data in scene_json.get("objects", []):
		var positions = obj_data.get("locations", [])
		if positions.is_empty():
			positions = [obj_data.get("position", [0, 0])]
		for pos in positions:
			var o = object_scene.instantiate()
			o.position = _grid_to_pos(pos)
			o.set_data(obj_data)
			o.set("dialogue_tree", obj_data.get("dialogue_tree", {}))
			o.set("scene_transition", scene_transition)
			var obj_id = "scene_%d_obj_%s" % [current_scene_index, obj_data.get("id", "")]
			if image_paths.has(obj_id):
				o.set_sprite(image_paths[obj_id])
			add_child(o)

	loading_label.text = ""
	if scene_ready_queued:
		next_scene() # Instead of scene_transition.next_scene()

func next_scene():
	current_scene_index += 1
	_clear_scene()
	generate_scene(current_scene_index)

func _on_dialogue_finished(outcome: String):
	if outcome != "":
		player_history.append("- " + outcome)
	previous_outcome = _build_history_summary()
	next_scene()

func _on_next_scene_delay_timeout():
	next_scene()

func _on_trigger_next_scene():
	next_scene_delay_timer.start(5.0)

func _build_history_summary() -> String:
	var summary := ""
	for entry in player_history:
		summary += entry + "\n"
	return summary

func _grid_to_pos(grid: Array) -> Vector2:
	var tile_w = 64
	var tile_h = 64
	return Vector2(grid[0] * tile_w, grid[1] * tile_h)

func set_topic_and_theme(t: String, th: String) -> void:
	topic = t
	theme = th
	current_scene_index = 1
	player_history.clear()
	highlight_slides.clear()
	game_ending = false
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

func _on_end_game():
	game_ending = true
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
	for child in get_children():
		var cid = child.get("id") if child.has_method("get") else null
		var tree = child.get("dialogue_tree") if child.has_method("get") else null
		if cid != null and cid == target_id:
			if tree != null and typeof(tree) == TYPE_DICTIONARY and tree.has(new_root):
				tree["root"] = new_root
				print("🔀 Dialogue for %s now starts at %s" % [target_id, new_root])
			else:
				print("⚠️ No such root node: %s in %s" % [new_root, target_id])
			return
	print("⚠️ Could not find target for dialogue switch: %s" % target_id)

func _clear_scene():
	for child in get_children():
		if (child is CharacterBody2D or child is Area2D) and child != self:
			child.queue_free()

func set_progression_flag(flag: String):
	if progression_flags.has(flag):
		progression_flags[flag] = true
		print("✅ Progression flag set:", flag)
