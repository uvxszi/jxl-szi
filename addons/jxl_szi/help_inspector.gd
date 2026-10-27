@tool
extends EditorInspectorPlugin
## Puts each JXL-SZI setting's description (settings.gd) above it in Project Settings and Editor Settings: settings
## added by a plugin have no documentation there of their own.

const Settings := preload("settings.gd")


func _can_handle(object: Object) -> bool:
	return object != null and object.get_class() in ["SectionedInspectorFilter", "EditorSettings", "ProjectSettings"]


func _parse_property(object: Object, _type: Variant.Type, name: String, _hint_type: PropertyHint, _hint_string: String, _usage_flags: int, _wide: bool) -> bool:
	# the dialogs list a section's settings by their last part only (distance), plain inspectors by the full name
	var full := name if name.begins_with("jxl_szi/") else _ours(object, name)
	var text := Settings.description(full)
	if text == "":
		return false
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.custom_minimum_size = Vector2(120, 0)
	label.modulate = Color(1, 1, 1, 0.65)
	label.add_theme_font_size_override("font_size", maxi(10, EditorInterface.get_editor_theme().get_font_size("main_size", "EditorFonts") - 1))
	add_custom_control(label)
	return false


## The JXL-SZI setting that `name` in a dialog section is: one whose name ends in it and whose value is the one shown
## (another section can use the same last part); empty if none is.
func _ours(object: Object, name: String) -> String:
	var es := EditorInterface.get_editor_settings()
	var shown: Variant = object.get(name)
	for s: Dictionary in Settings.PROJECT + Settings.EDITOR:
		var full: String = s.name
		if not full.ends_with("/" + name):
			continue
		var value: Variant = es.get_setting(full) if es.has_setting(full) else ProjectSettings.get_setting(full, null)
		if value != null and typeof(shown) == typeof(value) and shown == value:
			return full
	return ""
