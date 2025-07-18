extends Node

signal scene_json_ready(scene_data: Dictionary)
signal image_ready(id: String, path: String)
signal all_images_ready()
signal ending_slides_ready(slide_data: Array) # For highlight slides

var current_scene_id: String = ""
const SCENE_REQUEST_URL := "https://mersbot.openai.azure.com/openai/deployments/gpt-4o-mini/chat/completions?api-version=2025-01-01-preview"
const IMAGE_REQUEST_URL_GPT1 := "https://admin-md45xf05-westus3.cognitiveservices.azure.com/openai/deployments/gpt-image-1/images/generations?api-version=2025-04-01-preview"
const GPT_REPHRASE_URL := "https://mersbot.openai.azure.com/openai/deployments/gpt-35-turbo/chat/completions?api-version=2025-01-01-preview"
const IMAGE_REQUEST_URL := "https://mersbot.openai.azure.com/openai/deployments/dall-e-3/images/generations?api-version=2024-04-01-preview"

var OPENAI_API_KEY = ""
var AZURE_IMAGE_API_KEY := ""

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

# --- NEW: Store expected image IDs for ready check ---
var expected_image_ids: Array = []

func request_scene_json(topic: String, theme: String, history: String = "", scene_index: int = 1):
	_reset_state_for_new_scene()
	var user_prompt := "Generate scene %d for topic '%s' and theme '%s'. " % [scene_index, topic, theme]
	user_prompt += "Set the scene_index property to %d in the JSON. " % scene_index
	if not history.is_empty():
		user_prompt += "Here is the full player history so far:\n%s" % history

	var http_request := HTTPRequest.new()
	add_child(http_request)

	var system_prompt := ""
	var prompt_file := FileAccess.open("res://scripts/system_prompt.txt", FileAccess.READ)
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

	http_request.request_completed.connect(_on_scene_response.bind(http_request))
	http_request.request(SCENE_REQUEST_URL, get_text_headers(), HTTPClient.METHOD_POST, JSON.stringify(body))

func _on_scene_response(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest):
	http_request.queue_free()

	if code != 200:
		print("❌ Scene request error (%d): %s" % [code, body.get_string_from_utf8()])
		return

	var response_text: String = body.get_string_from_utf8()
	var json_result: Dictionary = JSON.parse_string(response_text)

	if not json_result is Dictionary or not json_result.has("choices"):
		print("❌ Invalid GPT scene response structure. Raw text: ", response_text)
		return

	var content_text: String = json_result["choices"][0]["message"]["content"]
	var scene_json: Dictionary = JSON.parse_string(content_text)

	# Print scene JSON and locations for debugging
	print("===== SCENE JSON RECEIVED =====")
	print(content_text)

	if scene_json.has("npcs"):
		print("===== NPC LOCATIONS =====")
		for npc in scene_json["npcs"]:
			var npc_id = npc.get("id", "unknown")
			var npc_name = npc.get("name", "unknown")
			var loc = npc.get("location", null)
			var locs = npc.get("locations", null)
			if locs:
				print("NPC:", npc_name, "(id:", npc_id, ") locations:", locs)
			elif loc:
				print("NPC:", npc_name, "(id:", npc_id, ") location:", loc)
			else:
				print("NPC:", npc_name, "(id:", npc_id, ") has no location")

	if scene_json.has("objects"):
		print("===== OBJECT LOCATIONS =====")
		for obj in scene_json["objects"]:
			var obj_id = obj.get("id", "unknown")
			var obj_name = obj.get("name", "unknown")
			var loc = obj.get("location", null)
			var locs = obj.get("locations", null)
			if locs:
				print("Object:", obj_name, "(id:", obj_id, ") locations:", locs)
			elif loc:
				print("Object:", obj_name, "(id:", obj_id, ") location:", loc)
			else:
				print("Object:", obj_name, "(id:", obj_id, ") has no location")

	if not scene_json is Dictionary:
		print("❌ Scene content JSON parsing failed. Raw content was:\n", content_text)
		return

	_process_scene_json(scene_json)
	all_scene_jsons.append(scene_json)
	emit_signal("scene_json_ready", scene_json)

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

# --- Returns all image IDs expected for the scene and index ---
func get_expected_image_ids(scene_json: Dictionary, scene_index: int) -> Array:
	var ids := []
	var seen_ids := {}

	# Add background
	if scene_json.has("background_prompt"):
		var base_id = "background"
		if not seen_ids.has(base_id):
			var unique_id = "scene_%d_%s" % [scene_index, base_id]
			ids.append(unique_id)
			seen_ids[base_id] = true

	# Add player
	if scene_json.has("player") and scene_json["player"].has("sprite_prompt"):
		var base_id = "player"
		if not seen_ids.has(base_id):
			var unique_id = "scene_%d_%s" % [scene_index, base_id]
			ids.append(unique_id)
			seen_ids[base_id] = true

	# Add NPCs
	for npc in scene_json.get("npcs", []):
		var base_id = "npc_" + str(npc.get("id", ""))
		if not seen_ids.has(base_id):
			var unique_id = "scene_%d_%s" % [scene_index, base_id]
			ids.append(unique_id)
			seen_ids[base_id] = true

	# Add objects
	for obj in scene_json.get("objects", []):
		var base_id = "obj_" + str(obj.get("id", ""))
		if not seen_ids.has(base_id):
			var unique_id = "scene_%d_%s" % [scene_index, base_id]
			ids.append(unique_id)
			seen_ids[base_id] = true

	# highlight image (optional)
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

	# Store expected IDs for ready check
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

	# Request highlight image for ending slides
	if scene_json.has("highlight_prompt"):
		_request_image("scene_%d_highlight" % scene_index, scene_json["highlight_prompt"])

	for item in all_prompts:
		_request_image(item["id"], item["prompt"])

func _reset_state_for_new_scene():
	# No increment to current_scene_index here! (scene index is managed by game.gd)
	total_images_requested = 0
	images_finished = 0
	retry_counts.clear()
	rate_limit_retries.clear()
	# Do not clear highlight_summaries/all_scene_jsons here, only on full game reset

func _request_image(id: String, prompt: String, is_retry := false):
	var max_retries := 3
	if not retry_counts.has(id):
		retry_counts[id] = 0

	var http_request := HTTPRequest.new()
	add_child(http_request)

	var body := {
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
		func(result, code, headers, body):
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

			var response_text: String = body.get_string_from_utf8()
			var json_result: Dictionary = JSON.parse_string(response_text)
			if json_result.has("data"):
				var data0 = json_result["data"][0]
				if data0.has("b64_json"):
					# Image is base64, save it directly
					var image_bytes = Marshalls.base64_to_raw(data0["b64_json"])
					var path: String = "user://%s.png" % id
					var file := FileAccess.open(path, FileAccess.WRITE)
					file.store_buffer(image_bytes)
					file.close()
					emit_signal("image_ready", id, path)
					images_finished += 1
					_check_all_images_ready()
				elif data0.has("url"):
					# Fallback for url (old endpoint)
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
	# Use GPT-Image-1 endpoint and header for image requests
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
		func(result, code, headers, body):
			http_request.queue_free()
			if code != 200:
				print("❌ Image rephrase/retry failed for %s." % id)
				images_finished += 1
				_check_all_images_ready()
				return

			var response_text: String = body.get_string_from_utf8()
			var json_result: Dictionary = JSON.parse_string(response_text)
			# Use the rephrased prompt for another image retry if needed
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
		func(result, response_code, headers, body):
			http_request.queue_free()
			if response_code == 200:
				var path: String = "user://%s.png" % id
				var file := FileAccess.open(path, FileAccess.WRITE)
				file.store_buffer(body)
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
	# Call this when the game ends (trigger_end)
	highlight_summaries.clear()
	highlight_images.clear()
	var slides: Array = []

	for i in range(all_scene_jsons.size()):
		var scene = all_scene_jsons[i]
		var summary := ""
		var image_path := ""
		# Grab highlight_summary (or fallback to narrative)
		if scene.has("highlight_summary"):
			summary = scene["highlight_summary"]
		elif scene.has("narrative"):
			summary = scene["narrative"]
		else:
			summary = "No summary available."
		highlight_summaries.append(summary)

		# Image path must match what was used in request_all_images
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
	# Call this on game restart
	highlight_summaries.clear()
	highlight_images.clear()
	all_scene_jsons.clear()
	current_scene_index = -1
