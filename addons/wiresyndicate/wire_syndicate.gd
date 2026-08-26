extends Node

@export var network_key: String = ""
@export var game_id: String = ""
@export var api_base_url: String = "https://api.wiresyndicate.com"

var _session_token: String = ""
var _handshake_secret: String = ""
var _is_authenticated: bool = false

func _ready():
	if network_key != "":
		authenticate(network_key)

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
	else:
		push_error("[WireSyndicate] FATAL: Handshake payload success flag missing or false.")

## Dispatches an impression to the telemetry endpoint.
func dispatch_impression(impression_token: String, placement_id: String, bid_id: String, duration_seconds: float, screen_coverage: float) -> void:
	if not _is_authenticated:
		push_error("[WireSyndicate] Cannot dispatch telemetry: SDK lacks a valid session token.")
		return
		
	var duration_ms: int = roundi(duration_seconds * 1000.0)
	
	var payload_dict = {
		"impression_token": impression_token,
		"placementId": placement_id,
		"bid_id": bid_id,
		"durationMs": duration_ms,
		"screenCoverage": screen_coverage
	}
	
	var json_payload = JSON.stringify(payload_dict)
	var signature = WSCryptography.generate_hmac(json_payload, _handshake_secret)
	
	var url = api_base_url.trim_suffix("/") + "/api/v1/telemetry/impressions"
	
	var headers = [
		"Authorization: Bearer " + _session_token,
		"X-WS-Signature: " + signature,
		"Content-Type: application/json"
	]
	
	var http_request = _get_available_http_request()
	var error = http_request.request(url, headers, HTTPClient.METHOD_POST, json_payload)
	if error != OK:
		push_error("[WireSyndicate] Failed to initiate telemetry HTTP request.")
		_release_http_request(http_request)

func _get_available_http_request() -> HTTPRequest:
	for child in get_children():
		if child is HTTPRequest and child.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
			return child
			
	var new_request = HTTPRequest.new()
	new_request.timeout = 10.0
	add_child(new_request)
	new_request.request_completed.connect(self._on_telemetry_completed.bind(new_request))
	return new_request

func _release_http_request(http_request: HTTPRequest) -> void:
	http_request.cancel_request()

func _on_telemetry_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http_request: HTTPRequest) -> void:
	# We leave the node in the tree to be reused by the pool
	
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_error("[WireSyndicate] Perimeter Rejected Telemetry. Error code: " + str(response_code))
		return
		
	print("[WireSyndicate] Signed Token burned. Financial clearing executed.")
