extends Node

@export var network_key: String = ""
@export var game_id: String = ""
@export var api_base_url: String = "https://api.wiresyndicate.com"

var _session_token: String = ""
var _handshake_secret: String = ""
var _is_authenticated: bool = false
var session_id: String = "00000000-0000-0000-0000-000000000000"

var telemetry_batch: Array = []
var _batch_timer: float = 0.0

func _ready():
	# Attempt to generate a pseudo-UUID for session
	session_id = str(hash(Time.get_unix_time_from_system())) + "-" + str(randi())
	
	if network_key != "":
		authenticate(network_key)

func _process(delta: float) -> void:
	_batch_timer += delta
	if telemetry_batch.size() > 0 and (_batch_timer >= 5.0 or telemetry_batch.size() >= 500):
		_flush_telemetry_batch()

## Performs the zero-trust handshake with the WireSyndicate Edge Delivery Node.
func authenticate(key: String) -> void:
	if key.is_empty():
		push_error("[WireSyndicate] Network Key is empty. Aborting handshake.")
		return
		
	network_key = key
	var url = api_base_url.trim_suffix("/") + "/api/v1/network/handshake"
	
	var http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(self._on_handshake_completed.bind(http_request))
	
	var headers = [
		"Authorization: Bearer " + network_key,
		"Content-Type: application/json"
	]
	
	var error = http_request.request(url, headers, HTTPClient.METHOD_GET)
	if error != OK:
		push_error("[WireSyndicate] Failed to initiate handshake HTTP request.")
		http_request.queue_free()

func _on_handshake_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest) -> void:
	http_request.queue_free() # Ephemeral cleanup
	
	if result != HTTPRequest.RESULT_SUCCESS:
		push_error("[WireSyndicate] FATAL: Zero-Trust Handshake Failed (Network Error).")
		return
		
	if response_code == 403:
		push_error("[WireSyndicate] FATAL: Handshake rejected. Organization account is suspended or banned. Edge delivery halted.")
		return
	elif response_code != 200:
		push_error("[WireSyndicate] FATAL: Zero-Trust Handshake Failed with status code " + str(response_code))
		return
		
	var json = JSON.new()
	var parse_result = json.parse(body.get_string_from_utf8())
	if parse_result != OK:
		push_error("[WireSyndicate] FATAL: Handshake response invalid JSON.")
		return
		
	var response = json.get_data()
	if response.has("success") and response["success"]:
		_session_token = response.get("session_token", "")
		_handshake_secret = response.get("handshake_secret", "")
		_is_authenticated = true
		print("[WireSyndicate] Zero-Trust Handshake successful. Edge network synced.")
		_drain_dlq()
	else:
		push_error("[WireSyndicate] FATAL: Handshake payload success flag missing or false.")

const DLQ_PATH = "user://ws_telemetry_dlq.json"

## Dispatches an impression to the telemetry endpoint via batching
func dispatch_impression(placement_id: String, campaign_id: String, bid_id: String, origin: Vector3, frustum: Array) -> void:
	if not _is_authenticated:
		push_error("[WireSyndicate] Cannot dispatch telemetry: SDK lacks a valid session token.")
		return
		
	var impression_id = str(randi()) + str(Time.get_ticks_msec())
	var rendered_at = Time.get_datetime_string_from_system(true, true) + "Z"
	
	var player_origin_geom = "SRID=0;POINT Z(%f %f %f)" % [origin.x, origin.y, origin.z]
	var frustum_geom = "SRID=0;POLYGON Z(("
	if frustum.size() >= 3:
		for i in range(frustum.size()):
			frustum_geom += "%f %f %f, " % [frustum[i].x, frustum[i].y, frustum[i].z]
		frustum_geom += "%f %f %f" % [frustum[0].x, frustum[0].y, frustum[0].z]
	else:
		frustum_geom += "0 0 0, 1 0 0, 1 1 0, 0 1 0, 0 0 0"
	frustum_geom += "))"
	
	var payload_to_sign = impression_id + ":" + placement_id + ":" + campaign_id + ":" + bid_id + ":" + rendered_at
	var client_signature = WSCryptography.generate_hmac_sha256(payload_to_sign, _handshake_secret)
	
	var payload_dict = {
		"impression_id": impression_id,
		"placement_id": placement_id,
		"campaign_id": campaign_id,
		"bid_id": bid_id,
		"session_id": session_id,
		"rendered_at": rendered_at,
		"player_origin_geom": player_origin_geom,
		"camera_frustum_geom": frustum_geom,
		"client_signature": client_signature
	}
	
	telemetry_batch.append(payload_dict)

func _flush_telemetry_batch() -> void:
	if not _is_authenticated:
		return
		
	var batch_copy = telemetry_batch.duplicate(true)
	telemetry_batch.clear()
	_batch_timer = 0.0
	
	var final_json_payload = JSON.stringify(batch_copy)
	var transport_signature = WSCryptography.generate_hmac_sha256(final_json_payload, _handshake_secret)
	
	var url = api_base_url.trim_suffix("/") + "/api/v1/telemetry/impressions"
	
	var headers = [
		"Authorization: Bearer " + _session_token,
		"Content-Type: application/json",
		"X-WS-Signature: " + transport_signature
	]
	
	var http_request = _get_available_http_request()
	var callable = Callable(self, "_on_telemetry_completed").bind(http_request, batch_copy)
	
	if not http_request.request_completed.is_connected(callable):
		for conn in http_request.request_completed.get_connections():
			http_request.request_completed.disconnect(conn.callable)
		http_request.request_completed.connect(callable, CONNECT_ONE_SHOT)
	
	var error = http_request.request(url, headers, HTTPClient.METHOD_POST, final_json_payload)
	if error != OK:
		printerr("[WireSyndicate] Failed to initiate telemetry HTTP request. Caching payload.")
		for item in batch_copy:
			_cache_failed_payload(item)
		_release_http_request(http_request)

func _get_available_http_request() -> HTTPRequest:
	for child in get_children():
		if child is HTTPRequest and child.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
			return child
			
	var new_request = HTTPRequest.new()
	new_request.timeout = 10.0
	add_child(new_request)
	return new_request

func _release_http_request(http_request: HTTPRequest) -> void:
	http_request.cancel_request()

func _on_telemetry_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest, original_batch: Array) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 202:
		print("[WireSyndicate] Telemetry batch queued successfully at Edge (202 Accepted).")
	else:
		printerr("[WireSyndicate] Edge Ingestion Failed (HTTP ", response_code, "). Triggering local fallback queue.")
		for item in original_batch:
			_cache_failed_payload(item)

# --- Offline Dead Letter Queue (DLQ) Architecture ---

func _cache_failed_payload(payload: Dictionary):
	var cache: Array = _load_dlq()
	cache.append(payload)
	_save_dlq(cache)
	print("[WireSyndicate] Payload safely cached to local offline queue.")

func _load_dlq() -> Array:
	if not FileAccess.file_exists(DLQ_PATH):
		return []
		
	var file := FileAccess.open(DLQ_PATH, FileAccess.READ)
	if not file:
		return []
		
	var content := file.get_as_text()
	var parsed = JSON.parse_string(content)
	
	if typeof(parsed) == TYPE_ARRAY:
		return parsed as Array
	return []

func _save_dlq(cache: Array):
	var file := FileAccess.open(DLQ_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(cache))
		file.close()

func _drain_dlq():
	var cache = _load_dlq()
	if cache.size() > 0:
		print("[WireSyndicate] Draining ", cache.size(), " items from DLQ.")
		for item in cache:
			telemetry_batch.append(item)
		_save_dlq([])
