class_name WireSyndicateContracts

# Response payload for successful authentication
class AuthResponse:
	var token: String
	var expires_in: float
	var user_id: String

# Request payload from a DSP for an ad placement
class DspBidRequest:
	var placement_id: String
	var floor_price: float
	var device_type: String
	var user_agent: String
	var context: Dictionary

# Response payload from a DSP with the winning bid
class DspBidResponse:
	var bid_id: String
	var price: float
	var ad_markup: String
	var creative_id: String

# Cryptographic tracking tokens for impressions and clicks (null for house assets)
class SDKTrackingData:
	var impression_token: String
	var click_token: String

# Edge delivery waterfall payload matching Section 14 of API_CONTRACTS.md
class SDKDeliveryResponse:
	var placement_id: String
	var content_type: String
	var asset_url: String
	var click_url: String
	var promo_code: String
	var cta_overlay_text: String
	var format: String
	var prominence: String
	var monetization_mode: String
	var tracking: Variant

