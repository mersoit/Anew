extends CanvasLayer

signal dialogue_finished_with_outcome(outcome: String)
signal dialogue_finished
signal trigger_end # NEW: Signal for ending the game and showing highlight slides

@onready var panel: Panel = $Panel
@onready var label: Label = $Panel/Label
@onready var button_container: VBoxContainer = $Panel/Buttons

var current_npc: Node = null
var dialogue_tree: Dictionary = {}
var current_node: String = ""

func start_dialogue(npc: Node, tree: Dictionary):
	visible = true
	current_npc = npc
	dialogue_tree = tree
	current_node = "root" if tree.has("root") else tree.keys()[0]  # fallback to first node
	panel.visible = true
	label.visible = true
	_show_node()
	
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
	current_node = option.get("next", "")

	# Handle special trigger (e.g. ending the game)
	if option.has("action") and option["action"].has("trigger"):
		var trig = option["action"]["trigger"]
		if trig == "trigger_end":
			emit_signal("trigger_end")
			_end_dialogue()
			return
		elif trig == "next_scene" and current_npc and current_npc.has_method("do_action"):
			current_npc.do_action(option["action"])
	else:
		if option.has("action") and current_npc and current_npc.has_method("do_action"):
			current_npc.do_action(option["action"])

	if option.has("outcome"):
		emit_signal("dialogue_finished_with_outcome", option["outcome"])	

	_show_node()

func _end_dialogue():
	panel.visible = false
	emit_signal("dialogue_finished")
