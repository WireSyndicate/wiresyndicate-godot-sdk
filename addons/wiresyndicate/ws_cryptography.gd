class_name WSCryptography

## Generates an HMAC-SHA256 signature for the given payload and secret.
## Matches the existing Unity SDK WSCryptography signature logic.
static func generate_hmac(payload: String, secret: String) -> String:
	var context = HMACContext.new()
	var error = context.start(HashingContext.HASH_SHA256, secret.to_utf8_buffer())
	if error != OK:
		push_error("[WireSyndicate] Cryptography Error: Failed to start HMAC context.")
		return ""
	
	error = context.update(payload.to_utf8_buffer())
	if error != OK:
		push_error("[WireSyndicate] Cryptography Error: Failed to update HMAC context with payload.")
		return ""
	
	var hmac_bytes = context.finish()
	# Convert byte array to hexadecimal string manually or using packed byte array hex string encode
	return hmac_bytes.hex_encode()
