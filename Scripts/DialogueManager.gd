extends CanvasLayer

signal dialogue_finished_with_outcome(outcome: String)
signal dialogue_finished
signal trigger_end # Signal for ending the game and showing highlight slides

@onready var panel: Panel = $Panel
@onready var label: Label = $Panel/Label
@onready var button_container: VBoxContainer = $Panel/Buttons
@onready var portrait_sprite: Sprite2D = $PortraitSprite

var current_target: Node = null
var dialogue_tree: Dictionary = {}
var current_node: String = ""
var root_game: Node = null
var dialogue_active: bool = false

func start_dialogue(npc: Node, tree: Dictionary):
	if dialogue_active:
		return
	dialogue_active = true
	visible = true
	if is_instance_valid(portrait_sprite):
		portrait_sprite.visible = false
	current_target = npc
	dialogue_tree = tree
	current_node = "root" if tree.has("root") else tree.keys()[0]
	panel.visible = true
	label.visible = true
	# Show and set portrait
	if is_instance_valid(portrait_sprite):
		var tex = null
		if is_instance_valid(npc) and npc.has_node("Sprite"):
			var sprite = npc.get_node("Sprite")
			if is_instance_valid(sprite) and sprite.texture:
				tex = sprite.texture
		if tex:
			portrait_sprite.texture = tex
			portrait_sprite.visible = true
			portrait_sprite.scale = Vector2(0.4, 0.4)
		else:
			portrait_sprite.visible = false
	root_game = get_node("/root/Game")
	_show_node()

func _ready():
	visible = false

func _show_node():
	var children := button_container.get_children()
	for child in children:
		if is_instance_valid(child):
			child.queue_free()

	if not dialogue_tree.has(current_node):
		print("⚠️ Dialogue node '%s' not found." % current_node)
		_end_dialogue()
		return

	var node = dialogue_tree[current_node]
	label.text = node.get("npc_line", "[...]")

	for option in node.get("responses", []):
		var btn := Button.new()
		btn.text = option.get("player_line", "...")
		btn.pressed.connect(_on_option_selected.bind(option))
		button_container.add_child(btn)

func _on_option_selected(option: Dictionary):
	# Store if this is a next_scene trigger
	var should_trigger_next_scene = false
	
	# Process the action FIRST, before changing current_node
	if option.has("action"):
		var action = option["action"]
		if action != null and typeof(action) == TYPE_DICTIONARY:
			# Handle dialogue switching
			if action.has("switch_dialogue"):
				var switch_data = action["switch_dialogue"]
				if switch_data.has("target_id") and switch_data.has("new_root") and root_game:
					print("🔄 Switching dialogue for %s to %s" % [switch_data["target_id"], switch_data["new_root"]])
					root_game.switch_dialogue_node(switch_data["target_id"], switch_data["new_root"])

			# Handle scene progression
			if action.has("trigger"):
				var trig = action["trigger"]
				if trig == "trigger_end":
					emit_signal("trigger_end")
					_end_dialogue()
					return
				elif trig == "next_scene":
					# Mark that we should trigger next scene
					should_trigger_next_scene = true
					print("🎬 Next scene will be triggered after dialogue closes")
		
		# Handle other actions through the target
		if current_target and current_target.has_method("do_action"):
			current_target.do_action(action)

	# Record outcome if present
	if option.has("outcome"):
		emit_signal("dialogue_finished_with_outcome", option["outcome"])

	# Now change to the next dialogue node
	current_node = option.get("next", "")
	
	# Check if we have a next node to show
	if current_node != "" and dialogue_tree.has(current_node):
		_show_node()
	else:
		# No next node, end dialogue
		_end_dialogue()
		# If this was a next_scene trigger, handle it after dialogue closes
		if should_trigger_next_scene and root_game:
			root_game.call_deferred("next_scene")
		
func try_close_on_player_distance(player: Node, target: Node, max_distance: float = 64.0):
	if not visible:
		return
	if not is_instance_valid(player) or not is_instance_valid(target):
		return
	if player.global_position.distance_to(target.global_position) > max_distance:
		_end_dialogue()
		
func _end_dialogue():
	panel.visible = false
	visible = false
	dialogue_active = false
	if is_instance_valid(portrait_sprite):
		portrait_sprite.visible = false
	emit_signal("dialogue_finished")
