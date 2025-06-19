extends Node

signal scene_ready(scene_index: int)
signal start_dialogue_with_data(dialogue_data: Variant)

@export var max_scenes: int = 7
var current_scene: int = 1

func next_scene():
	print("⏭️ Scene transition triggered")
	if current_scene > max_scenes:
		print("[Game End] Maximum scenes reached.")
		return
	print("[SceneTransition] Advancing to scene %d" % current_scene)
	emit_signal("scene_ready", current_scene)
	current_scene += 1

func reset():
	current_scene = 1
	print("[SceneTransition] Reset to scene 1")

func start_dialogue(dialogue_data: Variant):
	print("🗨️ start_dialogue called with:", dialogue_data)
	emit_signal("start_dialogue_with_data", dialogue_data)

func get_current_scene_index() -> int:
	return current_scene

func set_current_scene_index(index: int):
	current_scene = index
	print("[SceneTransition] Set current scene index to", index)
