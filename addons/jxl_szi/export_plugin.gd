@tool
extends EditorExportPlugin
## JXL-SZI's export. For a preset with the custom feature `jxl-szi` (Export > Features > Custom), every texture
## imported VRAM-compressed (its .import says compress/mode=2) ships as JPEG XL instead of Godot's .ctex: converted once
## with the converter tools (cjxl + the stager, bin/<platform>/; cached in res://.jxl_cache/ by the image's content and
## import options), added as res://addons/jxl_szi/data/<name>.jxl, with data/manifest.json for the runtime
## (runtime/jxl_stream.gd): per texture its path, UID, size, normal-map flag, a 16x16 thumbnail and average colour
## (shown until it's decoded) and its boot rank (decoded from startup). The decoder's shaders and tables go in too.
## Every other preset exports as before.
##
## Boot set (Project Settings > jxl_szi/boot): rank 0 is the main scene's textures, then each entry of `paths` (a
## scene, a resource, or a folder of them) in order, then what `script` returns: a script with
## `static func jxl_boot_paths() -> Array` (entries: a path, or an Array of paths that share a rank).

const FEATURE := "jxl-szi"
const DATA := "res://addons/jxl_szi/data/"
const RUNTIME := "res://addons/jxl_szi/runtime/"
const BIN := "res://addons/jxl_szi/bin/"
const CACHE := "res://.jxl_cache"
const CACHE_VERSION := 2 # part of every cache key: bump when the converter's output changes
const Settings := preload("settings.gd") # every setting, its default and what it does
## Editor Settings: a folder with your own builds of cjxl and stager. Empty (the usual): the bundled bin/<platform>.
const TOOLS_SETTING := "jxl_szi/converter/custom_tools_dir"
const BOOT_PATHS := "jxl_szi/boot/paths"
const BOOT_SCRIPT := "jxl_szi/boot/boot_script"
const IMAGES := ["png", "jpg", "jpeg", "webp", "tga", "bmp"]
const SCENES := ["tscn", "scn", "tres", "res", "glb", "gltf", "fbx", "blend", "obj", "dae"]

var _skip := {} # res:// paths of the images whose .ctex stays out


func _get_name() -> String:
	return "JxlSzi"


func _export_begin(features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_skip.clear()
	if not FEATURE in features:
		return
	var t0 := Time.get_ticks_msec()
	if String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")) == "gl_compatibility":
		push_warning("JXL-SZI: the Compatibility renderer has no RenderingDevice, so the textures can't be decoded there (thumbnails only). Use Forward+ or Mobile.")
	if not ProjectSettings.has_setting("autoload/JxlSzi"):
		push_error("JXL-SZI: the JxlSzi autoload is missing (disable and enable the plugin); exporting the usual textures.")
		return
	var texs := _vram_textures()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE))
	var distance := float(Settings.value("jxl_szi/converter/distance"))
	var normal_distance := float(Settings.value("jxl_szi/converter/normal_map_distance"))
	var effort := clampi(int(Settings.value("jxl_szi/converter/effort")), 1, 7)
	var todo := []
	for t: Dictionary in texs:
		t.distance = normal_distance if t.normal else distance
		t.effort = effort
		var key := "%s|%s|%d" % [FileAccess.get_md5(t.path), t.normal, CACHE_VERSION]
		if t.process != "":
			key += "|" + t.process
		if not is_equal_approx(t.distance, 1.0):
			key += "|d%s" % t.distance
		if effort != 7:
			key += "|e%d" % effort
		t.file = "%s_%s.jxl" % [String(t.path).get_file().get_basename(), key.md5_text().left(8)]
		t.cached = "%s/%s" % [CACHE, t.file]
		if not FileAccess.file_exists(t.cached):
			todo.append(t)
	if not todo.is_empty():
		_convert(todo)
	var ranks := _boot_ranks()
	var man := []
	for t: Dictionary in texs:
		if not FileAccess.file_exists(t.cached):
			push_warning("JXL-SZI: %s could not be converted; it stays .ctex" % t.path)
			continue
		var img := _source_image(t)
		if img == null:
			continue
		var e := { path = t.path, file = t.file, normal = t.normal, uid = t.uid, w = img.get_width(), h = img.get_height() }
		img.convert(Image.FORMAT_RGBA8)
		var small := img
		while small.get_width() > 64 and small.get_height() > 64:
			small.shrink_x2()
		small.resize(16, 16, Image.INTERPOLATE_LANCZOS)
		e.thumb = Marshalls.raw_to_base64(small.get_data())
		small.resize(1, 1, Image.INTERPOLATE_BILINEAR)
		var c := small.get_pixel(0, 0)
		e.avg = [snappedf(c.r, 0.001), snappedf(c.g, 0.001), snappedf(c.b, 0.001), snappedf(c.a, 0.001)]
		if ranks.has(t.path):
			e.boot = ranks[t.path]
		man.append(e)
		add_file(DATA + String(t.file), FileAccess.get_file_as_bytes(t.cached), false)
		_skip[t.path] = true
	add_file(DATA + "manifest.json", JSON.stringify(man).to_utf8_buffer(), false)
	# cached files nothing uses any more (an image changed or went)
	var used := {}
	for t: Dictionary in texs:
		used[t.file] = true
	for f in DirAccess.get_files_at(CACHE):
		if f.ends_with(".jxl") and not used.has(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(CACHE).path_join(f))
	# the decoder's own files (not resources, so the export wouldn't take them on its own)
	for f in DirAccess.get_files_at(RUNTIME + "gpu/shaders"):
		if f.ends_with(".glslsrc"):
			add_file(RUNTIME + "gpu/shaders/" + f, FileAccess.get_file_as_bytes(RUNTIME + "gpu/shaders/" + f), false)
	add_file(RUNTIME + "gpu/consts.bin", FileAccess.get_file_as_bytes(RUNTIME + "gpu/consts.bin"), false)
	print("JXL-SZI export: %d textures as JPEG XL (%d converted now), in %d ms" % [man.size(), todo.size(), Time.get_ticks_msec() - t0])


func _export_file(path: String, _type: String, features: PackedStringArray) -> void:
	if FEATURE in features and _skip.has(path):
		skip()


# Textures ------------------------------------------------------------------------------------------------------------

## Every VRAM-compressed 8-bit image: { path, normal, uid, process } (process: the import options that change its
## pixels, as text; empty when there are none).
func _vram_textures() -> Array:
	var out := []
	_walk("res://", out)
	return out


func _walk(dir: String, out: Array) -> void:
	if FileAccess.file_exists(dir.path_join(".gdignore")):
		return
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with(".") and dir.path_join(d) != "res://addons/jxl_szi":
			_walk(dir.path_join(d), out)
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".import") or not f.trim_suffix(".import").get_extension().to_lower() in IMAGES:
			continue
		var cfg := ConfigFile.new()
		if cfg.load(dir.path_join(f)) != OK:
			continue
		if String(cfg.get_value("remap", "importer", "")) != "texture" or int(cfg.get_value("params", "compress/mode", 0)) != 2:
			continue
		var process := []
		var limit := int(cfg.get_value("params", "process/size_limit", 0))
		if limit > 0:
			process.append("limit%d" % limit)
		if bool(cfg.get_value("params", "process/normal_map_invert_y", false)):
			process.append("invert_y")
		if bool(cfg.get_value("params", "process/premult_alpha", false)):
			process.append("premult")
		if bool(cfg.get_value("params", "process/fix_alpha_border", false)):
			process.append("fix_border")
		out.append({ path = dir.path_join(f.trim_suffix(".import")), normal = int(cfg.get_value("params", "compress/normal_map", 0)) == 1,
			uid = String(cfg.get_value("remap", "uid", "")), process = ",".join(process) })


## The image as the import would see it: its import options that change pixels applied.
func _source_image(t: Dictionary) -> Image:
	var img := Image.load_from_file(ProjectSettings.globalize_path(t.path))
	if img == null or img.is_empty():
		return null
	var process := String(t.process)
	if process == "":
		return img
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	for p in process.split(","):
		if p.begins_with("limit"):
			var limit := int(p.trim_prefix("limit"))
			if img.get_width() > limit or img.get_height() > limit:
				var s := float(limit) / maxi(img.get_width(), img.get_height())
				img.resize(maxi(1, roundi(img.get_width() * s)), maxi(1, roundi(img.get_height() * s)), Image.INTERPOLATE_LANCZOS)
		elif p == "invert_y":
			for y in img.get_height():
				for x in img.get_width():
					var c := img.get_pixel(x, y)
					c.g = 1.0 - c.g
					img.set_pixel(x, y, c)
		elif p == "premult":
			img.premultiply_alpha()
		elif p == "fix_border":
			img.fix_alpha_edges()
	return img


# The converter -------------------------------------------------------------------------------------------------------

## Converts `todo` ({ path, cached, process, distance }) into the cache: cjxl (the patched libjxl 0.12: 3 AC passes, ANS only,
## faster decoding), then the stager adds the boxes the runtime reads (where each pass group ends, constant alpha
## groups, the staged job as sziZ). PNGs go to cjxl as they are; other formats and processed images as a temporary
## PNG.
func _convert(todo: Array) -> void:
	var tools := _tools_dir()
	var cjxl := tools.path_join("cjxl" + _exe())
	var stager := tools.path_join("stager" + _exe())
	for exe in [cjxl, stager]:
		if not FileAccess.file_exists(exe):
			push_error("JXL-SZI: %s is missing. Build the converter tools (tools/BUILDING.md in the JXL-SZI repository) or set Editor Settings > Jxl Szi > Converter > Custom Tools Dir to a folder with your builds." % exe)
			return
	var tmp := ProjectSettings.globalize_path(CACHE).path_join("tmp")
	for d in ["enc", "ann", "src"]:
		DirAccess.make_dir_recursive_absolute(tmp.path_join(d))
	var t0 := Time.get_ticks_msec()
	var cmds := []
	for t: Dictionary in todo:
		var src := ProjectSettings.globalize_path(t.path)
		if t.process != "" or src.get_extension().to_lower() != "png":
			var img := _source_image(t)
			if img == null:
				continue
			src = tmp.path_join("src").path_join(String(t.file).get_basename() + ".png")
			img.save_png(src)
		t.enc = tmp.path_join("enc").path_join(t.file)
		cmds.append([cjxl, [src, t.enc, "--quiet", "-d", str(t.distance), "-e", str(t.effort), "--faster_decoding=4", "--num_threads=2"]])
	var env := { JXL_SZI_PASSES = "3,5,8", JXL_SZI_ANS = "1", JXL_SZI_SIDE = "z" }
	var old := {}
	for k: String in env:
		old[k] = OS.get_environment(k)
		OS.set_environment(k, env[k])
	var jobs := int(Settings.value("jxl_szi/converter/parallel_jobs"))
	if jobs <= 0:
		jobs = maxi(1, OS.get_processor_count() / 2)
	_run_all(cmds, jobs)
	var encoded := []
	for t: Dictionary in todo:
		if t.has("enc") and FileAccess.file_exists(t.enc):
			encoded.append(t)
	cmds = []
	for c in range(0, encoded.size(), 8):
		var args := PackedStringArray(["--annotate", tmp.path_join("ann")])
		for t: Dictionary in encoded.slice(c, c + 8):
			args.append(t.enc)
		cmds.append([stager, args])
	_run_all(cmds, jobs)
	for k: String in env:
		if old[k] != "":
			OS.set_environment(k, old[k])
		else:
			OS.unset_environment(k)
	var done := 0
	for t: Dictionary in encoded:
		var ann := tmp.path_join("ann").path_join(t.file)
		if FileAccess.file_exists(ann) and DirAccess.rename_absolute(ann, ProjectSettings.globalize_path(t.cached)) == OK:
			done += 1
	for d in ["enc", "ann", "src"]:
		for f in DirAccess.get_files_at(tmp.path_join(d)):
			DirAccess.remove_absolute(tmp.path_join(d).path_join(f))
	print("JXL-SZI export: converted %d of %d textures in %d ms" % [done, todo.size(), Time.get_ticks_msec() - t0])


## Runs `cmds` ([path, args]) at most `jobs` at a time, without console windows; returns how many failed.
func _run_all(cmds: Array, jobs: int) -> int:
	var running := {}
	var next := 0
	var failed := 0
	while next < cmds.size() or not running.is_empty():
		while next < cmds.size() and running.size() < jobs:
			var pid := OS.create_process(cmds[next][0], cmds[next][1])
			if pid <= 0:
				failed += 1
			else:
				running[pid] = true
			next += 1
		for pid: int in running.keys():
			if not OS.is_process_running(pid):
				if OS.get_process_exit_code(pid) != 0:
					failed += 1
				running.erase(pid)
		OS.delay_msec(5)
	return failed


## The custom tools folder when it holds both tools, else the bundled bin/<platform>-<arch>.
func _tools_dir() -> String:
	var es := EditorInterface.get_editor_settings()
	var dir := String(es.get_setting(TOOLS_SETTING)) if es.has_setting(TOOLS_SETTING) else ""
	if dir != "":
		if FileAccess.file_exists(dir.path_join("cjxl" + _exe())) and FileAccess.file_exists(dir.path_join("stager" + _exe())):
			return dir
		push_warning("JXL-SZI: Custom Tools Dir (%s) has no cjxl%s and stager%s in it; using the bundled tools. Clear the setting to use them without this warning." % [dir, _exe(), _exe()])
	var arch := Engine.get_architecture_name()
	var platform := { Windows = "windows", Linux = "linux", macOS = "macos" }.get(OS.get_name(), OS.get_name().to_lower())
	return ProjectSettings.globalize_path(BIN + "%s-%s" % [platform, arch])


func _exe() -> String:
	return ".exe" if OS.get_name() == "Windows" else ""


# The boot set --------------------------------------------------------------------------------------------------------

## Boot ranks by res:// path of the image (the first group that uses it).
func _boot_ranks() -> Dictionary:
	var groups := []
	var main := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main.begins_with("uid://"):
		main = ResourceUID.get_id_path(ResourceUID.text_to_id(main))
	if main != "":
		groups.append([main])
	for p in ProjectSettings.get_setting(BOOT_PATHS, PackedStringArray()):
		groups.append([String(p)])
	var script_path := String(ProjectSettings.get_setting(BOOT_SCRIPT, ""))
	if script_path != "":
		var sc: Script = load(script_path)
		if sc and sc.get_script_method_list().any(func(m: Dictionary) -> bool: return m.name == "jxl_boot_paths"):
			for g: Variant in sc.call("jxl_boot_paths"):
				groups.append(g if g is Array else [g])
		else:
			push_warning("JXL-SZI: %s has no static func jxl_boot_paths() -> Array" % script_path)
	var ranks := {}
	var seen := {}
	for r in groups.size():
		var paths := {}
		for p: String in groups[r]:
			for f in _files_in(p):
				_deps(f, paths, seen)
		for p in paths:
			if not ranks.has(p):
				ranks[p] = r
	return ranks


## `path` itself, or the scenes and resources in it (a folder, recursively).
func _files_in(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	if DirAccess.dir_exists_absolute(path):
		for d in DirAccess.get_directories_at(path):
			if not d.begins_with("."):
				out.append_array(_files_in(path.path_join(d)))
		for f in DirAccess.get_files_at(path):
			if f.get_extension() in SCENES:
				out.append(path.path_join(f))
	elif ResourceLoader.exists(path):
		out.append(path)
	return out


func _deps(path: String, into: Dictionary, seen: Dictionary) -> void:
	if seen.has(path):
		for p in seen[path]:
			into[p] = true
		return
	var mine := {}
	seen[path] = mine
	for d in ResourceLoader.get_dependencies(path):
		var p := String(d).get_slice("::", 2) if String(d).contains("::") else String(d)
		if p.begins_with("uid://"):
			p = ResourceUID.get_id_path(ResourceUID.text_to_id(p))
		if p == "":
			continue
		mine[p] = true
		if p.get_extension() in SCENES:
			_deps(p, mine, seen)
	for p in mine:
		into[p] = true
