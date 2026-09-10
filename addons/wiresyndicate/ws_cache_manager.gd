class_name WSCacheManager
extends RefCounted

const CACHE_DIR = "user://ws_asset_cache/"
const MAX_CACHE_SIZE_BYTES = 50 * 1024 * 1024 # 50MB

static func _ensure_cache_dir() -> void:
	var dir = DirAccess.open("user://")
	if dir and not dir.dir_exists(CACHE_DIR):
		dir.make_dir_recursive(CACHE_DIR)

static func get_cached_asset_path(asset_hash: String) -> String:
	if asset_hash.is_empty():
		return ""
		
	var file_path = CACHE_DIR + asset_hash + ".glb"
	if FileAccess.file_exists(file_path):
		return file_path
	
	# Godot 4 doesn't have an easy way to update last access time natively in GDScript,
	# so we rely on file modification time during GC, which means LRU might be approximated 
	# to least recently updated/downloaded unless we store metadata.
	return ""

static func cache_asset(asset_hash: String, data: PackedByteArray) -> String:
	if asset_hash.is_empty() or data.size() == 0:
		return ""
		
	_ensure_cache_dir()
	
	var file_path = CACHE_DIR + asset_hash + ".glb"
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if file:
		file.store_buffer(data)
		file.close()
		
		run_garbage_collection()
		return file_path
		
	return ""

static func run_garbage_collection() -> void:
	_ensure_cache_dir()
	
	var dir = DirAccess.open(CACHE_DIR)
	if not dir:
		return
		
	var files: Array[Dictionary] = []
	var total_size: int = 0
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".glb"):
			var file_path = CACHE_DIR + file_name
			var f = FileAccess.open(file_path, FileAccess.READ)
			if f:
				var size = f.get_length()
				var modified_time = FileAccess.get_modified_time(file_path)
				files.append({
					"name": file_name,
					"path": file_path,
					"size": size,
					"modified_time": modified_time
				})
				total_size += size
		file_name = dir.get_next()
	
	dir.list_dir_end()
	
	# Sort files by modified time (oldest first)
	files.sort_custom(func(a, b): return a["modified_time"] < b["modified_time"])
	
	for file_info in files:
		if total_size <= MAX_CACHE_SIZE_BYTES:
			break
			
		var err = dir.remove(file_info["name"])
		if err == OK:
			total_size -= file_info["size"]
		else:
			push_warning("[WireSyndicate] Failed to delete cache file: " + file_info["name"])
