extends Node3D

@export var placement_id: String = ""
@export var target_mesh_path: NodePath
@export var surface_index: int = 0

var _wire_syndicate: Node
var _is_resolving: bool = false
var active_bid_id: String = ""

# Live-Ops Delivery State
var _resolved_content_type: String = ""
var _resolved_tracking: Variant = null
var _resolved_click_url: String = ""
var _resolved_format: String = ""

# VRAM & Material Reuse Cache
var _active_material: StandardMaterial3D = null
var _active_texture: ImageTexture = null

func _ready():
	_wire_syndicate = get_node_or_null("/root/WireSyndicate")
	if _wire_syndicate == null:
		push_error("[WireSyndicate] WSPlacementNode requires the WireSyndicate AutoLoad to be active.")
		return
		
	if placement_id != "":
		resolve_placement()

func _exit_tree() -> void:
	_active_texture = null
	_active_material = null

## Hits the edge delivery API (Section 14 API_CONTRACTS.md) to get the asset URL for this placement.
func resolve_placement() -> void:
	if _is_resolving or placement_id.is_empty():
		return
		
	_is_resolving = true
	var url = _wire_syndicate.api_base_url.trim_suffix("/") + "/api/v1/sdk/delivery?placement_id=" + placement_id.uri_encode()
	
	var headers = [
		"Authorization: Bearer " + _wire_syndicate.network_key,
		"Accept: application/json"
	]
	
	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(self._on_resolve_completed.bind(http_request))
	
	var error = http_request.request(url, headers, HTTPClient.METHOD_GET)
	if error != OK:
		push_error("[WireSyndicate] Failed to request placement delivery.")
		http_request.queue_free()
		_is_resolving = false

func _on_resolve_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest) -> void:
	http_request.queue_free()
	_is_resolving = false
	
	if response_code == 204:
		print("[WireSyndicate] 204 No Content for " + placement_id + ": No active creative available.")
		return
		
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_error("[WireSyndicate] Failed to resolve placement delivery. Status: " + str(response_code))
		return
		
	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		push_error("[WireSyndicate] Invalid JSON response for placement delivery.")
		return
		
	var response = json.get_data()
	if typeof(response) != TYPE_DICTIONARY:
		push_error("[WireSyndicate] Unexpected delivery response format.")
		return
		
	var asset_url = response.get("asset_url", "")
	_resolved_content_type = response.get("content_type", "house")
	_resolved_click_url = response.get("click_url", "")
	_resolved_format = response.get("format", "").to_lower()
	_resolved_tracking = response.get("tracking", null)
	active_bid_id = response.get("placement_id", "")
	
	if not asset_url.is_empty():
		# Compute deterministic hash for local disk cache lookup
		var asset_hash = asset_url.sha256_text()
		var cached_path = WSCacheManager.get_cached_asset_path(asset_hash)
		if cached_path != "":
			_load_asset_from_cache(cached_path, _resolved_format, asset_hash)
			return
		download_asset(asset_url, asset_hash, _resolved_format)
	else:
		print("[WireSyndicate] No asset URL provided for placement: " + placement_id)

func _load_asset_from_cache(cached_path: String, format: String, asset_hash: String) -> void:
	if "3d" in format or cached_path.ends_with(".glb"):
		_apply_gltf_model(cached_path, true, asset_hash)
	else:
		var file = FileAccess.open(cached_path, FileAccess.READ)
		if file:
			var body = file.get_buffer(file.get_length())
			WorkerThreadPool.add_task(self._decode_image_task.bind(body, "image/png", true, asset_hash), true)

## Downloads the raw bytes.
func download_asset(asset_url: String, asset_hash: String, format: String) -> void:
	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(self._on_asset_download_completed.bind(http_request, asset_hash, format))
	
	var error = http_request.request(asset_url, [], HTTPClient.METHOD_GET)
	if error != OK:
		push_error("[WireSyndicate] Failed to initiate asset download.")
		http_request.queue_free()

func _on_asset_download_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest, asset_hash: String, format: String) -> void:
	http_request.queue_free()
	
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_error("[WireSyndicate] Asset download failed. Status: " + str(response_code))
		return
		
	if asset_hash != "":
		WSCacheManager.cache_asset(asset_hash, body)

	if "3d" in format or format == "":
		var cached_path = WSCacheManager.get_cached_asset_path(asset_hash)
		if cached_path != "":
			_apply_gltf_model(cached_path, false, asset_hash)
		return
			
	# Determine image type based on headers
	var content_type = ""
	for header in headers:
		var h = header.to_lower()
		if h.begins_with("content-type:"):
			content_type = h.split(":")[1].strip_edges()
			break
			
	# Offload decoding to worker thread
	WorkerThreadPool.add_task(self._decode_image_task.bind(body, content_type, false, asset_hash), true)

## Executed on a background thread.
func _decode_image_task(body: PackedByteArray, content_type: String, is_cache_hit: bool = false, asset_hash: String = "") -> void:
	var image = Image.new()
	var err = FAILED
	
	if "png" in content_type:
		err = image.load_png_from_buffer(body)
	elif "webp" in content_type:
		err = image.load_webp_from_buffer(body)
	else:
		err = image.load_jpg_from_buffer(body)
		
	if err == OK:
		Callable(self, "_apply_texture").call_deferred(image, is_cache_hit, asset_hash)
	else:
		push_error("[WireSyndicate] Failed to decode downloaded image buffer.")

func _apply_gltf_model(file_path: String, is_cache_hit: bool = false, asset_hash: String = "") -> void:
	var gltf_doc = GLTFDocument.new()
	var gltf_state = GLTFState.new()
	
	var error = gltf_doc.append_from_file(file_path, gltf_state)
	if error != OK:
		push_error("[WireSyndicate] Failed to load GLTF document from cache: " + str(error))
		return
		
	var generated_node = gltf_doc.generate_scene(gltf_state)
	if generated_node != null:
		add_child(generated_node)
		
		# Hide the fallback mesh if one is provided
		if not target_mesh_path.is_empty():
			var target_node = get_node_or_null(target_mesh_path)
			if target_node is VisualInstance3D:
				(target_node as VisualInstance3D).hide()
				
		print("[WireSyndicate] Successfully instantiated GLTF model.")
		_handle_telemetry_dispatch()

## Executed on the main thread.
## Manages VRAM and material reuse for MeshInstance3D and Sprite3D.
func _apply_texture(image: Image, is_cache_hit: bool = false, asset_hash: String = "") -> void:
	if target_mesh_path.is_empty():
		push_error("[WireSyndicate] Target node path is not set for WSPlacementNode.")
		return
		
	var target_node = get_node_or_null(target_mesh_path)
	if target_node == null:
		push_error("[WireSyndicate] Target node could not be resolved from path: " + str(target_mesh_path))
		return
		
	_active_texture = ImageTexture.create_from_image(image)
	if _active_texture == null:
		push_error("[WireSyndicate] Failed to create ImageTexture from Image.")
		return
		
	if target_node is MeshInstance3D:
		var mesh_instance = target_node as MeshInstance3D
		if _active_material == null:
			var existing_mat = mesh_instance.get_surface_override_material(surface_index) as StandardMaterial3D
			if existing_mat != null:
				_active_material = existing_mat
			else:
				_active_material = StandardMaterial3D.new()
				_active_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNLIT
				mesh_instance.set_surface_override_material(surface_index, _active_material)
		_active_material.albedo_texture = _active_texture
	elif target_node is Sprite3D:
		var sprite_instance = target_node as Sprite3D
		sprite_instance.texture = _active_texture
	else:
		push_error("[WireSyndicate] Target node is neither MeshInstance3D nor Sprite3D: " + target_node.get_class())
		return
		
	_handle_telemetry_dispatch()

## Strict telemetry guard: Only dispatch telemetry when sponsored and impression_token is present.
func _handle_telemetry_dispatch() -> void:
	if _wire_syndicate == null:
		return
		
	if _resolved_content_type == "sponsored" and _resolved_tracking is Dictionary:
		var token = str(_resolved_tracking.get("impression_token", "")).strip_edges()
		if not token.is_empty():
			var origin = global_transform.origin
			var frustum = []
			var cam = get_viewport().get_camera_3d()
			if cam != null:
				var z_far = cam.far
				var p = cam.global_position
				var vp_size = get_viewport().get_visible_rect().size
				var c1 = cam.project_position(Vector2(0, 0), z_far)
				var c2 = cam.project_position(Vector2(vp_size.x, 0), z_far)
				var c3 = cam.project_position(Vector2(vp_size.x, vp_size.y), z_far)
				var c4 = cam.project_position(Vector2(0, vp_size.y), z_far)
				frustum = [c1, c2, c3, c4]
			_wire_syndicate.dispatch_impression(placement_id, "", active_bid_id, origin, frustum, token)
			return
			
	print("[WireSyndicate] Telemetry suppressed for house placement: ", placement_id)
