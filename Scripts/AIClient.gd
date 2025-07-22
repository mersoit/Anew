extends Node

signal scene_json_ready(scene_data: Dictionary)
signal image_ready(id: String, path: String)
signal all_images_ready()
signal ending_slides_ready(slide_data: Array) # For highlight slides
# The 'scene_generation_failed' signal is now removed and replaced by a direct function call.

var current_scene_id: String = ""
const SCENE_REQUEST_URL := "https://mersbot.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2025-01-01-preview"
const IMAGE_REQUEST_URL_GPT1 := "https://admin-md45xf05-westus3.cognitiveservices.azure.com/openai/deployments/gpt-image-1/images/generations?api-version=2025-04-01-preview"
const GPT_REPHRASE_URL := "https://mersbot.openai.azure.com/openai/deployments/gpt-35-turbo/chat/completions?api-version=2025-01-01-preview"
const IMAGE_REQUEST_URL := "https://mersbot.openai.azure.com/openai/deployments/dall-e-3/images/generations?api-version=2024-04-01-preview"

var OPENAI_API_KEY = ""
var AZURE_IMAGE_API_KEY := ""

const SceneValidator = preload("res://Scripts/SceneValidator.gd")
const MAX_REPAIR_ATTEMPTS = 2
var scene_repair_attempts: int = 0

# Header helpers for different endpoints
func get_text_headers() -> PackedStringArray:
	return PackedStringArray([
		"Content-Type: application/json",
		"api-key: %s" % OPENAI_API_KEY
	])

func get_image_headers() -> PackedStringArray:
	return PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % AZURE_IMAGE_API_KEY
	])

const CONTENT_TYPE_HEADER := "Content-Type: application/json"

var total_images_requested: int = 0
var images_finished: int = 0
var current_scene_index: int = -1
var retry_counts: Dictionary = {}
var rate_limit_retries: Dictionary = {}

# For ending slide collection
var highlight_summaries: Array[String] = []
var highlight_images: Array[String] = []
var all_scene_jsons: Array[Dictionary] = [] # store scenes in order

var expected_image_ids: Array = []

func request_scene_json(topic: String, theme: String, history: String = "", scene_index: int = 1):
	_reset_state_for_new_scene()
	current_scene_index = scene_index
	var user_prompt := "Generate scene %d for topic '%s' and theme '%s'. " % [scene_index, topic, theme]
	user_prompt += "Set the scene_index property to %d in the JSON. " % scene_index
	if not history.is_empty():
		user_prompt += "Here is the full player history so far:\n%s" % history

	var http_request := HTTPRequest.new()
	add_child(http_request)

	var system_prompt := ""
	var prompt_file := FileAccess.open("res://Scripts/system_prompt.txt", FileAccess.READ)
	if prompt_file:
		system_prompt = prompt_file.get_as_text()
		prompt_file.close()
	else:
		print("❌ System prompt file not found!")
		return

	var body := {
		"messages": [
			{"role": "system", "content": system_prompt},
			{"role": "user", "content": user_prompt}
		],
		"max_tokens": 8192
	}

	http_request.request_completed.connect(_on_scene_response.bind(http_request, topic, theme, history, scene_index))
	http_request.request(SCENE_REQUEST_URL, get_text_headers(), HTTPClient.METHOD_POST, JSON.stringify(body))

func _on_scene_response(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest, topic: String, theme: String, history: String, scene_index: int):
	http_request.queue_free()
	# --- MODIFICATION: Get a reference to the game node for failure handling ---
	var game_node = get_node("/root/Game")

	if code != 200:
		print("❌ Scene request error (%d): %s" % [code, body.get_string_from_utf8()])
		_retry_scene_request(game_node, scene_index)
		return

	var response_text: String = body.get_string_from_utf8()
	var json_result: Dictionary = JSON.parse_string(response_text)

	if not json_result is Dictionary or not json_result.has("choices"):
		print("❌ Invalid GPT scene response structure. Raw text: ", response_text)
		_retry_scene_request(game_node, scene_index)
		return

	var content_text: String = json_result["choices"][0]["message"]["content"]
	
	print("===== RAW JSON FROM LLM (Pre-Validation) =====")
	print(content_text)
	print("==============================================")
	
	var cleaned_text = content_text.strip_edges()
	if cleaned_text.begins_with("```json"):
		cleaned_text = cleaned_text.trim_prefix("```json").strip_edges()
	if cleaned_text.ends_with("```"):
		cleaned_text = cleaned_text.trim_suffix("```").strip_edges()

	var start_brace = cleaned_text.find("{")
	var end_brace = cleaned_text.rfind("}")
	var scene_json 

	if start_brace != -1 and end_brace != -1 and start_brace < end_brace:
		var json_string = cleaned_text.substr(start_brace, end_brace - start_brace + 1)
		scene_json = JSON.parse_string(json_string)
	else:
		scene_json = null
	
	if not scene_json is Dictionary:
		print("❌ Scene content JSON parsing failed. Raw content was:\n", content_text)
		_retry_scene_request(game_node, scene_index)
		return

	var is_final_scene = (scene_index >= 5)
	var validation = SceneValidator.validate_scene(scene_json, scene_index, is_final_scene)

	if not validation.is_valid:
		print("❌ Scene validation failed! Errors: ", validation.errors)
		if scene_repair_attempts < MAX_REPAIR_ATTEMPTS:
			scene_repair_attempts += 1
			print("🔧 Attempting scene repair (%d/%d)..." % [scene_repair_attempts, MAX_REPAIR_ATTEMPTS])
			_request_scene_repair(content_text, validation.errors, topic, theme, history, scene_index)
		else:
			print("❌ Max repair attempts reached. Requesting a completely new scene.")
			_retry_scene_request(game_node, scene_index)
		return
	
	print("✅ Scene validation passed.")
	scene_repair_attempts = 0

	_process_scene_json(scene_json)
	all_scene_jsons.append(scene_json)
	emit_signal("scene_json_ready", scene_json)

func _request_scene_repair(broken_json_string: String, errors: Array, topic: String, theme: String, history: String, scene_index: int):
	var http_request := HTTPRequest.new()
	add_child(http_request)

	var error_string = "\n- ".join(errors)
	var repair_prompt = """The following JSON scene, which was generated for a '%s' topic with a '%s' theme for scene %d, has validation errors.
Please review the original rules and the errors below, then fix the JSON. Return only the corrected, pure JSON.

History of player actions so far:
%s

Errors to fix:
- %s

Original broken JSON to fix:
%s
""" % [topic, theme, scene_index, history if not history.is_empty() else "No history yet.", error_string, broken_json_string]

	var system_prompt := ""
	var prompt_file := FileAccess.open("res://Scripts/system_prompt.txt", FileAccess.READ)
	if prompt_file:
		system_prompt = prompt_file.get_as_text()
		prompt_file.close()

	var body := {
		"messages": [
			{"role": "system", "content": system_prompt},
			{"role": "user", "content": repair_prompt}
		],
		"max_tokens": 8192
	}

	http_request.request_completed.connect(_on_scene_response.bind(http_request, topic, theme, history, scene_index))
	http_request.request(SCENE_REQUEST_URL, get_text_headers(), HTTPClient.METHOD_POST, JSON.stringify(body))

# --- MODIFICATION: This function now takes the game node and calls it directly ---
func _retry_scene_request(game_node: Node, scene_index: int):
	print("❗️ Instructing game to regenerate the scene from scratch.")
	scene_repair_attempts = 0
	if is_instance_valid(game_node) and game_node.has_method("handle_scene_generation_failure"):
		game_node.handle_scene_generation_failure(scene_index)
	else:
		print("CRITICAL ERROR: Game node is invalid or missing 'handle_scene_generation_failure' method.")

func _process_scene_json(scene_json: Dictionary):
	var clean_prompt: Callable = func(p: String) -> String: return p.strip_edges().replace("\n", " ")

	if scene_json.has("player"):
		scene_json["player"]["sprite_prompt"] = clean_prompt.call(scene_json["player"].get("sprite_prompt", ""))

	for npc in scene_json.get("npcs", []):
		npc["sprite_prompt"] = clean_prompt.call(npc.get("sprite_prompt", ""))

	var expanded_objects: Array = []
	for obj in scene_json.get("objects", []):
		var locations = obj.get("location", [])
		if typeof(locations) == TYPE_ARRAY and not locations.is_empty() and typeof(locations[0]) == TYPE_ARRAY:
			for i in range(locations.size()):
				var new_obj = obj.duplicate(true)
				new_obj["id"] = "%s_%d" % [obj.get("id", "obj"), i]
				new_obj["location"] = locations[i]
				expanded_objects.append(new_obj)
		else:
			expanded_objects.append(obj)
	scene_json["objects"] = expanded_objects

func get_expected_image_ids(scene_json: Dictionary, scene_index: int) -> Array:
	var ids := []
	var seen_ids := {}

	if scene_json.has("background_prompt"):
		var base_id = "background"
		if not seen_ids.has(base_id):
			var unique_id = "scene_%d_%s" % [scene_index, base_id]
			ids.append(unique_id)
			seen_ids[base_id] = true

	if scene_json.has("player") and scene_json["player"].has("sprite_prompt"):
		var base_id = "player"
		if not seen_ids.has(base_id):
			var unique_id = "scene_%d_%s" % [scene_index, base_id]
			ids.append(unique_id)
			seen_ids[base_id] = true

	for npc in scene_json.get("npcs", []):
		var base_id = "npc_" + str(npc.get("id", ""))
		if not seen_ids.has(base_id):
			var unique_id = "scene_%d_%s" % [scene_index, base_id]
			ids.append(unique_id)
			seen_ids[base_id] = true

	for obj in scene_json.get("objects", []):
		var base_id = "obj_" + str(obj.get("id", ""))
		if not seen_ids.has(base_id):
			var unique_id = "scene_%d_%s" % [scene_index, base_id]
			ids.append(unique_id)
			seen_ids[base_id] = true

	if scene_json.has("highlight_prompt"):
		var base_id = "highlight"
		var unique_id = "scene_%d_%s" % [scene_index, base_id]
		ids.append(unique_id)

	return ids

func request_all_images(scene_json: Dictionary, scene_index: int) -> void:
	print("🎯 AIClient.request_all_images called with scene_index: ", scene_index)
	current_scene_index = scene_index
	var all_prompts := []
	var seen_ids := {}

	var add_prompt = func(base_id: String, prompt: String):
		if not seen_ids.has(base_id):
			var unique_id: String = "scene_%d_%s" % [scene_index, base_id]
			all_prompts.append({"id": unique_id, "prompt": prompt})
			seen_ids[base_id] = true

	if scene_json.has("background_prompt"):
		add_prompt.call("background", scene_json["background_prompt"])

	if scene_json.has("player") and scene_json["player"].has("sprite_prompt"):
		add_prompt.call("player", scene_json["player"]["sprite_prompt"])

	for npc in scene_json.get("npcs", []):
		add_prompt.call("npc_" + str(npc.get("id", "")), npc["sprite_prompt"])

	for obj in scene_json.get("objects", []):
		add_prompt.call("obj_" + str(obj.get("id", "")), obj.get("sprite_prompt", ""))

	expected_image_ids = []
	for d in all_prompts:
		expected_image_ids.append(d["id"])
	if scene_json.has("highlight_prompt"):
		expected_image_ids.append("scene_%d_highlight" % scene_index)

	total_images_requested = all_prompts.size()
	images_finished = 0
	if total_images_requested == 0:
		emit_signal("all_images_ready")
		return

	if scene_json.has("highlight_prompt"):
		_request_image("scene_%d_highlight" % scene_index, scene_json["highlight_prompt"])

	for item in all_prompts:
		_request_image(item["id"], item["prompt"])

func _reset_state_for_new_scene():
	total_images_requested = 0
	images_finished = 0
	retry_counts.clear()
	rate_limit_retries.clear()
	scene_repair_attempts = 0

func _request_image(id: String, prompt: String, is_retry := false):
	var max_retries := 3
	if not retry_counts.has(id):
		retry_counts[id] = 0

	var http_request := HTTPRequest.new()
	add_child(http_request)

	var body: Dictionary
	if id.ends_with("_background") or id.ends_with("_highlight"):
		body = {
			"prompt": prompt,
			"size": "1024x1024",
			"quality": "low",
			"output_compression": 100,
			"output_format": "png",
			"n": 1,
			"moderation": "low"
		}
	else:
		body = {
			"prompt": prompt,
			"size": "1024x1024",
			"background": "transparent",
			"quality": "low",
			"output_compression": 100,
			"output_format": "png",
			"n": 1,
			"moderation": "low"
		}

	http_request.request_completed.connect(
		func(result, code, headers, body_bytes):
			http_request.queue_free()
			if code != 200:
				print("❌ Image generation failed for %s. Code: %s" % [id, str(code)])
				retry_counts[id] += 1
				if retry_counts[id] < max_retries:
					print("🔄 Retrying image %s (attempt %d/%d)" % [id, retry_counts[id]+1, max_retries])
					_request_image(id, prompt, true)
				else:
					print("❌ Max retries reached for %s, giving up." % id)
					images_finished += 1
					_check_all_images_ready()
				return

			var response_text: String = body_bytes.get_string_from_utf8()
			var json_result: Dictionary = JSON.parse_string(response_text)
			if json_result.has("data"):
				var data0 = json_result["data"][0]
				if data0.has("b64_json"):
					var image_bytes = Marshalls.base64_to_raw(data0["b64_json"])
					var path: String = "user://%s.png" % id
					var file := FileAccess.open(path, FileAccess.WRITE)
					file.store_buffer(image_bytes)
					file.close()
					emit_signal("image_ready", id, path)
					images_finished += 1
					_check_all_images_ready()
				elif data0.has("url"):
					var image_url = data0["url"]
					_download_image(id, image_url)
				else:
					print("❌ Neither b64_json nor url found in response for:", id)
					images_finished += 1
					_check_all_images_ready()
			else:
				print("❌ No image data found in response for:", id)
				images_finished += 1
				_check_all_images_ready()
	)
	http_request.request(IMAGE_REQUEST_URL_GPT1, get_image_headers(), HTTPClient.METHOD_POST, JSON.stringify(body))

func _rephrase_and_retry_image(id: String, original_prompt: String):
	var http_request := HTTPRequest.new()
	add_child(http_request)

	var rephrase_prompt := """Please rephrase this DALL-E 3 prompt to be clearer and more specific while keeping the same intent. Make it more descriptive and add details that will help generate a better image. Original prompt: "%s"\n\nReturn ONLY the rephrased prompt, nothing else.""" % original_prompt

	var body := {
		"messages": [
			{"role": "user", "content": rephrase_prompt}
		],
		"max_tokens": 200,
		"temperature": 0.7
	}

	http_request.request_completed.connect(
		func(result, code, headers, body_bytes):
			http_request.queue_free()
			if code != 200:
				print("❌ Image rephrase/retry failed for %s." % id)
				images_finished += 1
				_check_all_images_ready()
				return

			var response_text: String = body_bytes.get_string_from_utf8()
			var json_result: Dictionary = JSON.parse_string(response_text)
			if json_result.has("choices") and json_result["choices"].size() > 0:
				var rephrased = json_result["choices"][0]["message"]["content"]
				_request_image(id, rephrased, true)
			else:
				print("❌ Rephrase returned no choices, giving up for:", id)
				images_finished += 1
				_check_all_images_ready()
	)
	http_request.request(GPT_REPHRASE_URL, get_text_headers(), HTTPClient.METHOD_POST, JSON.stringify(body))

func _check_all_images_ready():
	if images_finished >= total_images_requested and total_images_requested > 0:
		emit_signal("all_images_ready")

func _download_image(id: String, url: String):
	var http_request := HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(
		func(result, response_code, headers, body_bytes):
			http_request.queue_free()
			if response_code == 200:
				var path: String = "user://%s.png" % id
				var file := FileAccess.open(path, FileAccess.WRITE)
				file.store_buffer(body_bytes)
				file.close()
				emit_signal("image_ready", id, path)
				images_finished += 1
				_check_all_images_ready()
			else:
				print("❌ Failed to download image for:", id)
				images_finished += 1
				_check_all_images_ready()
	)
	http_request.request(url)

# --- Ending Slides Logic ---

func get_ending_slides():
	highlight_summaries.clear()
	highlight_images.clear()
	var slides: Array = []

	for i in range(all_scene_jsons.size()):
		var scene = all_scene_jsons[i]
		var summary := ""
		var image_path := ""
		if scene.has("highlight_summary"):
			summary = scene["highlight_summary"]
		elif scene.has("narrative"):
			summary = scene["narrative"]
		else:
			summary = "No summary available."
		highlight_summaries.append(summary)

		var h_id = "scene_%d_highlight" % (i+1)
		var user_path = "user://%s.png" % h_id
		if FileAccess.file_exists(user_path):
			image_path = user_path
		else:
			image_path = ""
		highlight_images.append(image_path)

		slides.append({"summary": summary, "image": image_path})

	emit_signal("ending_slides_ready", slides)

func reset_session():
	highlight_summaries.clear()
	highlight_images.clear()
	all_scene_jsons.clear()
	current_scene_index = -1
