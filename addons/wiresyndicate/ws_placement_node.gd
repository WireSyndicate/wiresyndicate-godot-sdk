extends Node3D

@export var placement_id: String = ""
@export var target_mesh_path: NodePath
@export var surface_index: int = 0

var _wire_syndicate: Node
var _is_resolving: bool = false
var active_bid_id: String = ""

func _ready():
	_wire_syndicate = get_node_or_null("/root/WireSyndicate")
	if _wire_syndicate == null:
		push_error("[WireSyndicate] WSPlacementNode requires the WireSyndicate AutoLoad to be active.")
		return
		
	if placement_id != "":
		resolve_placement()

## Hits the resolve API to get the asset URL for this placement.
func resolve_placement() -> void:
	if _is_resolving or placement_id.is_empty():
		return
		
	_is_resolving = true
	var url = _wire_syndicate.api_base_url.trim_suffix("/") + "/api/v1/delivery/resolve"
	
	# Calculate AABB bounds on XZ plane
	var bounds_geom = "SRID=0;POLYGON Z((0 0 0, 1 0 0, 1 1 0, 0 1 0, 0 0 0))" # default
	var target_mesh = get_node_or_null(target_mesh_path) as VisualInstance3D
	if target_mesh != null:
		var aabb = target_mesh.get_aabb()
		var p1 = aabb.position
		var p2 = p1 + Vector3(aabb.size.x, 0, 0)
		var p3 = p1 + Vector3(aabb.size.x, 0, aabb.size.z)
		var p4 = p1 + Vector3(0, 0, aabb.size.z)
		bounds_geom = "SRID=0;POLYGON Z((%f %f %f, %f %f %f, %f %f %f, %f %f %f, %f %f %f))" % [p1.x, p1.y, p1.z, p2.x, p2.y, p2.z, p3.x, p3.y, p3.z, p4.x, p4.y, p4.z, p1.x, p1.y, p1.z]
	
	var origin = global_transform.origin
	var origin_geom = "SRID=0;POINT Z(%f %f %f)" % [origin.x, origin.y, origin.z]
	
	var frustum_geom = "SRID=0;POLYGON Z(("
	var cam = get_viewport().get_camera_3d()
	if cam != null:
		var z_far = cam.far
		var p = cam.global_position
		var vp_size = get_viewport().get_visible_rect().size
		var c1 = cam.project_position(Vector2(0, 0), z_far)
		var c2 = cam.project_position(Vector2(vp_size.x, 0), z_far)
		var c3 = cam.project_position(Vector2(vp_size.x, vp_size.y), z_far)
		var c4 = cam.project_position(Vector2(0, vp_size.y), z_far)
		frustum_geom += "%f %f %f, %f %f %f, %f %f %f, %f %f %f, %f %f %f, %f %f %f" % [p.x, p.y, p.z, c1.x, c1.y, c1.z, c2.x, c2.y, c2.z, c3.x, c3.y, c3.z, c4.x, c4.y, c4.z, p.x, p.y, p.z]
	else:
		frustum_geom += "0 0 0, 1 0 0, 1 1 0, 0 1 0, 0 0 0"
	frustum_geom += "))"
	
	var payload_dict = {
		"placement_id": placement_id,
		"session_id": _wire_syndicate.get("session_id") if _wire_syndicate.get("session_id") else "00000000-0000-0000-0000-000000000000",
		"origin_geom": origin_geom,
		"bounds_geom": bounds_geom,
		"camera_frustum_geom": frustum_geom
	}
	var json_payload = JSON.stringify(payload_dict)
	
	var secret = _wire_syndicate.get("_handshake_secret")
	if secret == null: secret = ""
	var transport_signature = WSCryptography.generate_hmac_sha256(json_payload, secret)
	
	var headers = [
		"Content-Type: application/json",
		"X-WS-Signature: " + transport_signature
	]
	
	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(self._on_resolve_completed.bind(http_request))
	
	var error = http_request.request(url, headers, HTTPClient.METHOD_POST, json_payload)
	if error != OK:
		push_error("[WireSyndicate] Failed to request placement resolve.")
		http_request.queue_free()
		_is_resolving = false

func _on_resolve_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest) -> void:
	http_request.queue_free()
	_is_resolving = false
	
	if response_code == 204:
		print("[WireSyndicate] 204 No Content for " + placement_id + ": No active campaigns won the waterfall.")
		return
		
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_error("[WireSyndicate] Failed to resolve placement. Status: " + str(response_code))
		return
		
	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		push_error("[WireSyndicate] Invalid JSON response for placement resolve.")
		return
		
	var response = json.get_data()
	if response.has("data"):
		var data = response["data"]
		var asset_url = data.get("asset_url", "")
		var asset_hash = data.get("asset_hash", "")
		var format = data.get("format", "").to_lower()
		active_bid_id = data.get("bid_id", "")
		if asset_url != "":
			if asset_hash != "":
				var cached_path = WSCacheManager.get_cached_asset_path(asset_hash)
				if cached_path != "":
					_load_asset_from_cache(cached_path, format, asset_hash)
					return
			download_asset(asset_url, asset_hash, format)
	else:
		push_error("[WireSyndicate] Failed to parse delivery resolve response.")

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
		# If it's a 3D model, we might have cached it just now, we can load from cache or memory.
		# GLTFDocument doesn't have a built-in memory buffer loader in standard GDScript as easily as load_png_from_buffer
		# So if it was cached, load it from the cached file path.
		var cached_path = WSCacheManager.get_cached_asset_path(asset_hash)
		if cached_path != "":
			_apply_gltf_model(cached_path, false, asset_hash)
		return
			
	# Determine image type based on headers (fallback to sniffing or assuming standard formats if necessary)
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
		# Fallback to JPG, commonly used
		err = image.load_jpg_from_buffer(body)
		
	if err == OK:
		# Handoff to main thread for Texture creation and RenderingServer interaction
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
			var target_mesh = get_node_or_null(target_mesh_path) as MeshInstance3D
			if target_mesh != null:
				target_mesh.hide()
				
		print("[WireSyndicate] Successfully instantiated GLTF model.")

## Executed on the main thread.
func _apply_texture(image: Image, is_cache_hit: bool = false, asset_hash: String = "") -> void:
	if target_mesh_path.is_empty():
		push_error("[WireSyndicate] Target mesh path is not set for WSPlacementNode.")
		return
		
	var target_mesh = get_node_or_null(target_mesh_path) as MeshInstance3D
	if target_mesh == null:
		push_error("[WireSyndicate] Resolved node is not a MeshInstance3D.")
		return
		
	var texture = ImageTexture.create_from_image(image)
	if texture == null:
		push_error("[WireSyndicate] Failed to create ImageTexture from Image.")
		return
		
	var material = StandardMaterial3D.new()
	material.albedo_texture = texture
	# Standard configurations for unlit or basic ad display
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNLIT
	
	target_mesh.set_surface_override_material(surface_index, material)
# Removed legacy _dispatch_telemetry
