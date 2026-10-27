@tool
extends EditorPlugin
## JXL-SZI: ship your VRAM textures as JPEG XL, decoded on the GPU at runtime. Enabling the plugin adds the JxlSzi
## autoload (kept first, so it hands out textures before anything else loads one) and the export (export_plugin.gd),
## which only acts on presets with the custom feature `jxl-szi`.
## Settings (settings.gd, each shown with its description by help_inspector.gd): Project Settings > General > Jxl Szi
## (converter, boot set, block formats, runtime); Editor Settings > Jxl Szi > Converter > Custom Tools Dir (Advanced
## Settings on; only for your own builds of the tools).

const AUTOLOAD := "JxlSzi"
const AUTOLOAD_PATH := "res://addons/jxl_szi/runtime/jxl_stream.gd"
const Settings := preload("settings.gd")

var export_plugin: EditorExportPlugin
var help: EditorInspectorPlugin


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD, AUTOLOAD_PATH)
	_autoload_first()


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD)


func _enter_tree() -> void:
	export_plugin = preload("res://addons/jxl_szi/export_plugin.gd").new()
	add_export_plugin(export_plugin)
	help = preload("res://addons/jxl_szi/help_inspector.gd").new()
	add_inspector_plugin(help)
	_settings()
	if ProjectSettings.has_setting("autoload/" + AUTOLOAD):
		_autoload_first()


func _exit_tree() -> void:
	if export_plugin:
		remove_export_plugin(export_plugin)
		export_plugin = null
	if help:
		remove_inspector_plugin(help)
		help = null


## The settings (settings.gd), registered so they show in the dialogs (with their defaults; a default isn't written to
## the file). The project settings show without Advanced Settings; the editor one (rarely needed) only with it.
func _settings() -> void:
	for old: String in Settings.RENAMED:
		var new: String = Settings.RENAMED[old]
		if ProjectSettings.has_setting(old):
			if not ProjectSettings.has_setting(new) or str(ProjectSettings.get_setting(new)) == "":
				ProjectSettings.set_setting(new, ProjectSettings.get_setting(old))
			ProjectSettings.set_setting(old, null)
			ProjectSettings.save()
	var es := EditorInterface.get_editor_settings()
	for st: Dictionary in Settings.EDITOR:
		if not es.has_setting(st.name):
			es.set_setting(st.name, st.default)
		es.set_initial_value(st.name, st.default, false)
		es.add_property_info({ name = st.name, type = st.type, hint = st.get("hint", PROPERTY_HINT_NONE), hint_string = st.get("hint_string", "") })
	for st: Dictionary in Settings.PROJECT:
		_project_setting(st.name, st.default, { type = st.type, hint = st.get("hint", PROPERTY_HINT_NONE), hint_string = st.get("hint_string", "") })


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
