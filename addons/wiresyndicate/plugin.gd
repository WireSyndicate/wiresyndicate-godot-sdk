@tool
extends EditorPlugin

func _enter_tree():
	add_autoload_singleton("WireSyndicate", "res://addons/wiresyndicate/wire_syndicate.gd")

func _exit_tree():
	remove_autoload_singleton("WireSyndicate")
