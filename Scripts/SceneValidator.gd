# SceneValidator.gd
# A static utility class to validate the logical integrity of a scene JSON.
extends Node

# The main validation function.
static func validate_scene(scene_json: Dictionary, scene_index: int, is_final_scene: bool) -> Dictionary:
	var errors: Array[String] = []

	# 1. Basic Structural Validation
	if not scene_json.has("scene_index"): errors.append("Missing 'scene_index' property.")
	if not scene_json.has("narrative"): errors.append("Missing 'narrative' property.")
	if not scene_json.has("background_prompt"): errors.append("Missing 'background_prompt'.")
	if not scene_json.has("player"): errors.append("Missing 'player' object.")

	if not errors.is_empty():
		return { "is_valid": false, "errors": errors }

	# 2. Collect all entities and their dialogue trees
	var all_entities = scene_json.get("npcs", []) + scene_json.get("objects", [])
	var all_entity_ids: Dictionary = {}
	for entity in all_entities:
		if entity.has("id"):
			all_entity_ids[entity["id"]] = entity

	# 3. Progression Path Validation (More Relaxed)
	var required_trigger = "trigger_end" if is_final_scene else "next_scene"
	var trigger_found = false
	for entity in all_entities:
		if entity.has("dialogue_tree"):
			if _dialogue_tree_has_path_to_trigger(entity["dialogue_tree"], required_trigger):
				trigger_found = true
				break # Found at least one path, that's enough.
	
	if not trigger_found:
		errors.append("Scene has no valid progression path. No dialogue tree leads to a '%s' trigger." % required_trigger)

	# 4. Action and Connection Validation (Now with visibility logic)
	for entity in all_entities:
		if not entity.has("dialogue_tree"): continue
		
		var source_id = entity.get("id", "Unknown")
		for node_key in entity["dialogue_tree"]:
			var node = entity["dialogue_tree"][node_key]
			if node.has("responses"):
				for response in node["responses"]:
					if response.has("action"):
						var action = response["action"]
						
						# Validate 'reveal' actions
						if action.has("reveal"):
							for reveal_id in action["reveal"]:
								if not all_entity_ids.has(reveal_id):
									errors.append("Action in '%s' tries to reveal non-existent entity ID: '%s'" % [source_id, reveal_id])
								elif all_entity_ids[reveal_id].get("visible_on_start", true):
									errors.append("Action in '%s' tries to reveal entity '%s' which is already visible by default." % [source_id, reveal_id])
						
						# Validate 'switch_dialogue' actions
						if action.has("switch_dialogue"):
							var switch_data = action["switch_dialogue"]
							var target_id = switch_data["target_id"]
							var new_root = switch_data["new_root"]

							if not all_entity_ids.has(target_id):
								errors.append("Action in '%s' refers to non-existent entity ID for switch_dialogue: '%s'" % [source_id, target_id])
								continue # Skip further checks on this broken action
							
							var target_entity = all_entity_ids[target_id]
							if not target_entity.get("dialogue_tree", {}).has(new_root):
								errors.append("Action in '%s' refers to non-existent dialogue node '%s' in target '%s'" % [source_id, new_root, target_id])

							# --- NEW VALIDATION LOGIC ---
							# Check if the target is hidden by default
							if not target_entity.get("visible_on_start", true):
								# If it's hidden, the action MUST also contain a 'reveal' for it.
								var reveals_in_action = action.get("reveal", [])
								if not target_id in reveals_in_action:
									errors.append("Logical Error in '%s': Action tries to 'switch_dialogue' on hidden entity '%s' without revealing it in the same action." % [source_id, target_id])


	return { "is_valid": errors.is_empty(), "errors": errors }


# Helper function to perform a DFS search for a trigger in a dialogue tree.
static func _dialogue_tree_has_path_to_trigger(tree: Dictionary, trigger_name: String) -> bool:
	if tree.is_empty(): return false
	
	var q: Array = ["root"] # Start search from the "root" node
	var visited: Dictionary = {}

	while not q.is_empty():
		var current_node_key = q.pop_front()
		if not tree.has(current_node_key) or visited.has(current_node_key):
			continue
		
		visited[current_node_key] = true
		var node = tree[current_node_key]

		# Check responses for the trigger
		if node.has("responses"):
			for response in node["responses"]:
				# Check for the action trigger
				if response.has("action") and response["action"].has("trigger") and response["action"]["trigger"] == trigger_name:
					return true # Found it!
				
				# Add the next node to the queue for searching
				if response.has("next"):
					var next_node = response["next"]
					if not visited.has(next_node):
						q.append(next_node)
						
	return false # Traversed all reachable nodes, no trigger found
