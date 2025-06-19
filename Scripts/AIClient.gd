extends Node

signal scene_json_ready(scene_data: Dictionary)
signal image_ready(id: String, path: String)
signal all_images_ready()
signal background_ready(path: String)

var current_scene_id: String = ""
const SCENE_REQUEST_URL := "https://mersbot.openai.azure.com/openai/deployments/gpt-4o-mini/chat/completions?api-version=2025-01-01-preview"
const IMAGE_REQUEST_URL := "https://mersbot.openai.azure.com/openai/deployments/dall-e-3/images/generations?api-version=2024-04-01-preview"
const GPT_REPHRASE_URL := "https://mersbot.openai.azure.com/openai/deployments/gpt-35-turbo/chat/completions?api-version=2025-01-01-preview"

const HEADERS: PackedStringArray = [
	"Content-Type: application/json",
	"api-key: "
]

var total_images_requested: int = 0
var images_finished: int = 0
var current_scene_index: int = -1
var retry_counts: Dictionary = {}
var rate_limit_retries: Dictionary = {}

func request_scene_json(topic: String, theme: String, history: String = ""):
	_reset_state_for_new_scene()

	var user_prompt := "Generate scene for topic '%s' and theme '%s'. " % [topic, theme]
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
		"max_tokens": 4096
	}

	http_request.request_completed.connect(_on_scene_response.bind(http_request))
	http_request.request(SCENE_REQUEST_URL, HEADERS, HTTPClient.METHOD_POST, JSON.stringify(body))
	
func _request_all_images(scene_json: Dictionary) -> void:
	var all_prompts := []
	var seen_ids := {}

	var add_prompt = func(base_id: String, prompt: String):
		if not seen_ids.has(base_id):
			var unique_id: String = "scene_%d_%s" % [current_scene_index, base_id]
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

	total_images_requested = all_prompts.size()
	if total_images_requested == 0:
		emit_signal("all_images_ready")
		return

	# Request highlight separately so it doesn't block scene building
	if scene_json.has("highlight_prompt"):
		_request_image("highlight", scene_json["highlight_prompt"])

	for item in all_prompts:
		_request_image(item["id"], item["prompt"])

func _reset_state_for_new_scene():
	current_scene_index += 1
	total_images_requested = 0
	images_finished = 0
	retry_counts.clear()
	rate_limit_retries.clear()
	print("--- Requesting New Scene (Index: %d) ---" % current_scene_index)

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
	print("🧠 Scene JSON Content:\n", content_text)

	var scene_json: Dictionary = JSON.parse_string(content_text)

	if not scene_json is Dictionary:
		print("❌ Scene content JSON parsing failed. Raw content was:\n", content_text)
		return

	_process_scene_json(scene_json)
	emit_signal("scene_json_ready", scene_json)
	call_deferred("_request_all_images", scene_json)

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

func request_all_images(scene_json: Dictionary, scene_index: int) -> void:
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

	total_images_requested = all_prompts.size()
	if total_images_requested == 0:
		emit_signal("all_images_ready")
		return

	if scene_json.has("highlight_prompt"):
		_request_image("highlight", scene_json["highlight_prompt"])

	for item in all_prompts:
		_request_image(item["id"], item["prompt"])

func _rephrase_prompt(original_prompt: String, id: String):
	var http := HTTPRequest.new()
	add_child(http)

	var rephrase_body := {
		"messages": [
			{"role": "system", "content": "Rephrase this prompt to comply with image generation safety filters, while keeping its visual meaning and detail."},
			{"role": "user", "content": original_prompt}
		],
		"max_tokens": 200
	}

	http.request_completed.connect(func(result, code, headers, body):
		if code == 200:
			var json: Dictionary = JSON.parse_string(body.get_string_from_utf8())
			if json.has("choices"):
				var new_prompt: String = json["choices"][0]["message"]["content"]
				print("🔄 Rephrased prompt for", id, "→", new_prompt)
				_request_image(id, new_prompt, true)
			else:
				print("❌ GPT rephrase failed for", id)
		else:
			print("❌ GPT rephrase HTTP error for", id, "Code:", code)
	)

	http.request(GPT_REPHRASE_URL, HEADERS, HTTPClient.METHOD_POST, JSON.stringify(rephrase_body))

func _request_image(id: String, prompt: String, is_retry := false):
	if not is_retry:
		print("🧾 Requesting image '%s' with prompt: '%s'" % [id, prompt])

	var http_request := HTTPRequest.new()
	add_child(http_request)

	var body := {
		"prompt": prompt,
		"size": "1024x1024",
		"n": 1
	}

	http_request.request_completed.connect(
		func(result, code, headers, body):
			http_request.queue_free()
			if code != 200:
				print("❌ Image generation failed for %s." % id)
				if not is_retry:
					_rephrase_prompt(prompt, id)
				return

			var response_text: String = body.get_string_from_utf8()
			var json_result: Dictionary = JSON.parse_string(response_text)
			if json_result.has("data"):
				var image_url = json_result["data"][0]["url"]
				_download_image(id, image_url)
			else:
				print("❌ No image URL found in response for:", id)
	)

	http_request.request(IMAGE_REQUEST_URL, HEADERS, HTTPClient.METHOD_POST, JSON.stringify(body))

func _download_image(id: String, url: String):
	var http_request := HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(
		func(result, response_code, headers, body):
			if response_code == 200:
				var path: String = "user://%s.png" % id
				var file := FileAccess.open(path, FileAccess.WRITE)
				file.store_buffer(body)
				file.close()
				emit_signal("image_ready", id, path)
				if id.ends_with("player"):
					print("🎯 Background-ready for player image: ", path)
				elif id.ends_with("background"):
					emit_signal("background_ready", path)
				images_finished += 1
				if images_finished >= total_images_requested:
					emit_signal("all_images_ready")
			else:
				print("❌ Failed to download image for:", id)
	)

	http_request.request(url)
