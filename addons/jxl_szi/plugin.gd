@tool
extends EditorPlugin
## JXL-SZI: ship your VRAM textures as JPEG XL, decoded on the GPU at runtime. Enabling the plugin adds the JxlSzi
## autoload (kept first, so it hands out textures before anything else loads one) and the export (export_plugin.gd),
## which only acts on presets with the custom feature `jxl-szi`.
## Settings: Project Settings > General > Jxl Szi (converter distances, boot paths and script); Editor Settings > Jxl
## Szi > Converter > Custom Tools Dir (Advanced Settings on; only for your own builds of the tools).

const AUTOLOAD := "JxlSzi"
const AUTOLOAD_PATH := "res://addons/jxl_szi/runtime/jxl_stream.gd"

var export_plugin: EditorExportPlugin


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD, AUTOLOAD_PATH)
	_autoload_first()


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD)


func _enter_tree() -> void:
	export_plugin = preload("res://addons/jxl_szi/export_plugin.gd").new()
	add_export_plugin(export_plugin)
	_settings()
	if ProjectSettings.has_setting("autoload/" + AUTOLOAD):
		_autoload_first()


func _exit_tree() -> void:
	if export_plugin:
		remove_export_plugin(export_plugin)
		export_plugin = null


## The settings, registered so they show in the dialogs (with their defaults; a default isn't written to the file).
## The project settings show without Advanced Settings; the editor one (rarely needed) only with it.
func _settings() -> void:
	var es := EditorInterface.get_editor_settings()
	var tools: String = export_plugin.TOOLS_SETTING
	if not es.has_setting(tools):
		es.set_setting(tools, "")
	es.set_initial_value(tools, "", false)
	es.add_property_info({ name = tools, type = TYPE_STRING, hint = PROPERTY_HINT_GLOBAL_DIR })
	_project_setting(export_plugin.DISTANCE_SETTING, 1.0, { type = TYPE_FLOAT, hint = PROPERTY_HINT_RANGE, hint_string = "0.05,5.0,0.05" })
	_project_setting(export_plugin.NORMAL_DISTANCE_SETTING, 0.35, { type = TYPE_FLOAT, hint = PROPERTY_HINT_RANGE, hint_string = "0.05,5.0,0.05" })
	_project_setting(export_plugin.BOOT_PATHS, PackedStringArray(), { type = TYPE_PACKED_STRING_ARRAY,
		hint = PROPERTY_HINT_TYPE_STRING, hint_string = "%d/%d:" % [TYPE_STRING, PROPERTY_HINT_FILE] })
	_project_setting(export_plugin.BOOT_SCRIPT, "", { type = TYPE_STRING, hint = PROPERTY_HINT_FILE, hint_string = "*.gd" })


func _project_setting(name: String, value: Variant, info: Dictionary) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, value)
	ProjectSettings.set_initial_value(name, value)
	ProjectSettings.set_as_basic(name, true)
	info.name = name
	ProjectSettings.add_property_info(info)


## Moves the autoload before every other one (they may load textures: those must come from JxlSzi in an export).
func _autoload_first() -> void:
	var key := "autoload/" + AUTOLOAD
	if not ProjectSettings.has_setting(key):
		return
	var first := ProjectSettings.get_order(key)
	for p in ProjectSettings.get_property_list():
		var n := String(p.name)
		if n.begins_with("autoload/") and n != key:
			first = mini(first, ProjectSettings.get_order(n) - 1)
	if first < ProjectSettings.get_order(key):
		ProjectSettings.set_order(key, first)
		ProjectSettings.save()
