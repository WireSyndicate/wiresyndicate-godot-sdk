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
	var url = _wire_syndicate.api_base_url.trim_suffix("/") + "/api/v1/delivery/resolve?placement_id=" + placement_id
	
	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(self._on_resolve_completed.bind(http_request))
	
	var error = http_request.request(url, [], HTTPClient.METHOD_GET)
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
	if response.has("creative"):
		var creative = response["creative"]
		var asset_url = creative.get("asset_url", "")
		active_bid_id = creative.get("bid_id", "")
		if asset_url != "":
			download_asset(asset_url)
	else:
		push_error("[WireSyndicate] Failed to parse delivery resolve response.")

## Downloads the raw image bytes.
func download_asset(asset_url: String) -> void:
	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(self._on_asset_download_completed.bind(http_request))
	
	var error = http_request.request(asset_url, [], HTTPClient.METHOD_GET)
	if error != OK:
		push_error("[WireSyndicate] Failed to initiate asset download.")
		http_request.queue_free()

func _on_asset_download_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest) -> void:
	http_request.queue_free()
	
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_error("[WireSyndicate] Asset download failed. Status: " + str(response_code))
		return
		
	# Determine image type based on headers (fallback to sniffing or assuming standard formats if necessary)
	var content_type = ""
	for header in headers:
		var h = header.to_lower()
		if h.begins_with("content-type:"):
			content_type = h.split(":")[1].strip_edges()
			break
			
	# Offload decoding to worker thread
	WorkerThreadPool.add_task(self._decode_image_task.bind(body, content_type), true)

## Executed on a background thread.
func _decode_image_task(body: PackedByteArray, content_type: String) -> void:
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
		Callable(self, "_apply_texture").call_deferred(image)
	else:
		push_error("[WireSyndicate] Failed to decode downloaded image buffer.")

## Executed on the main thread.
func _apply_texture(image: Image) -> void:
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
	print("[WireSyndicate] Successfully applied dynamic texture to surface ", surface_index)
