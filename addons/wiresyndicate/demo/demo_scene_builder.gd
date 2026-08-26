extends Node3D

# Note to Developers:
# Before running this demo scene, ensure that you have configured the 
# WireSyndicate AutoLoad singleton. You can do this in your startup script:
#
# WireSyndicate.network_key = "00000000-0000-0000-0000-000000000000"
# WireSyndicate.game_id = "11111111-1111-1111-1111-111111111111"
# WireSyndicate.authenticate(WireSyndicate.network_key)

func _ready():
	# 1. Instantiate basic environment
	var env = WorldEnvironment.new()
	var env_res = Environment.new()
	env_res.background_mode = Environment.BG_COLOR
	env_res.background_color = Color(0.2, 0.2, 0.2)
	env.environment = env_res
	add_child(env)
	
	var light = DirectionalLight3D.new()
	light.position = Vector3(0, 5, 5)
	light.look_at(Vector3.ZERO)
	add_child(light)
	
	var camera = Camera3D.new()
	camera.position = Vector3(0, 0, 3)
	camera.look_at(Vector3.ZERO)
	add_child(camera)
	
	# 2. Instantiate 3D billboard target
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "BillboardMesh"
	
	var quad = QuadMesh.new()
	quad.size = Vector2(2, 1) # Standard billboard aspect ratio
	mesh_instance.mesh = quad
	
	add_child(mesh_instance)
	
	# 3. Instantiate and attach WSPlacementNode
	var ws_node = preload("res://addons/wiresyndicate/ws_placement_node.gd").new()
	ws_node.name = "WSPlacementNode"
	add_child(ws_node)
	
	# 4. Configure WSPlacementNode properties
	ws_node.target_mesh_path = ws_node.get_path_to(mesh_instance)
	ws_node.surface_index = 0
	ws_node.placement_id = "22222222-2222-2222-2222-222222222222"
