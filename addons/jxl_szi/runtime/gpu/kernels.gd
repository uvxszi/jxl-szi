extends RefCounted
## The decoder's compute kernels on one RenderingDevice: compiled from shaders/*.glslsrc (vd_common / vd_t8 /
## vd_afv_basis put in where a kernel asks for them), with "name:DEF1,DEF2" building a variant with those defines.
## Compiled kernels are cached in user://jxl_szi_kernels/ per GPU, driver and engine build, so later launches skip
## both compiles (GLSL to SPIR-V, SPIR-V to the driver's form).

const SHADERS := "res://addons/jxl_szi/runtime/gpu/shaders/"
static var cache_dir := "user://jxl_szi_kernels"

var rd: RenderingDevice
var kernels := {}
var compiled := 0 # kernels compiled this session (not from the cache)


func _init(device: RenderingDevice) -> void:
	rd = device


func kernel(name: String) -> Dictionary:
	if not kernels.has(name):
		var parts := name.split(":")
		var code := load_shader(parts[0])
		if parts.size() > 1:
			var defs := ""
			for d in parts[1].split(","):
				defs += "#define %s\n" % d
			if not code.contains("#version 450\n"):
				push_error("JXL-SZI: kernel %s has no \"#version 450\" line to put the defines after" % name)
				return {}
			code = code.replace("#version 450\n", "#version 450\n" + defs)
		var key := "%s|%s|%s|%s|%s" % [code, rd.get_device_name(), rd.get_device_vendor_name(),
			RenderingServer.get_current_rendering_driver_name(), Engine.get_version_info().hash]
		var path := "%s/%s.bin" % [cache_dir, key.md5_text()]
		var shader := RID()
		if FileAccess.file_exists(path):
			shader = rd.shader_create_from_bytecode(FileAccess.get_file_as_bytes(path))
		if not shader.is_valid():
			var src := RDShaderSource.new()
			src.source_compute = code
			var spirv := rd.shader_compile_spirv_from_source(src)
			if spirv.compile_error_compute != "":
				push_error("JXL-SZI: kernel %s: %s" % [name, spirv.compile_error_compute])
			var bin := rd.shader_compile_binary_from_spirv(spirv, name)
			shader = rd.shader_create_from_bytecode(bin)
			compiled += 1
			if shader.is_valid():
				DirAccess.make_dir_recursive_absolute(cache_dir)
				var f := FileAccess.open(path, FileAccess.WRITE)
				if f:
					f.store_buffer(bin)
					f.close()
		kernels[name] = { shader = shader, pipe = rd.compute_pipeline_create(shader) }
	return kernels[name]


## Frees the compiled kernels (before the device goes).
func release() -> void:
	for k: Dictionary in kernels.values():
		if k.pipe.is_valid():
			rd.free_rid(k.pipe)
		if k.shader.is_valid():
			rd.free_rid(k.shader)
	kernels.clear()


func buf(bytes: PackedByteArray) -> RID:
	return rd.storage_buffer_create(bytes.size(), bytes)


## A uniform set of storage buffers (bindings 0, 1, ...) for kernel `name`.
func uset(bufs: Array, name: String) -> RID:
	var us := []
	for i in bufs.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = i
		u.add_id(bufs[i])
		us.append(u)
	return rd.uniform_set_create(us, kernel(name).shader, 0)


## A varblock-list kernel (vd8 / vdl2) over `count` entries starting at word `list` of the input buffer (vd8 takes
## 4 entries per workgroup).
func dispatch_list(cl: int, name: String, us: RID, list: int, count: int) -> void:
	var row := 32768
	var per := 4 if name.begins_with("vd8") else 1
	var groups := (count + per - 1) / per
	rd.compute_list_bind_compute_pipeline(cl, kernel(name).pipe)
	rd.compute_list_bind_uniform_set(cl, us, 0)
	var pc := PackedInt32Array([list, count, row, 0]).to_byte_array()
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, mini(groups, row), (groups + row - 1) / row, 1)


## A kernel's source with vd_common / vd_t8 / vd_afv_basis put in at //COMMON, //T8, //AFV. CRs are dropped (a file
## saved with CRLF endings would defeat the "#version 450\n" match the defines rely on).
static func load_shader(name: String) -> String:
	var code := _src(name)
	code = code.replace("//COMMON", _src("vd_common"))
	code = code.replace("//T8", _src("vd_t8"))
	return code.replace("//AFV", _src("vd_afv_basis"))


static func _src(name: String) -> String:
	return FileAccess.get_file_as_string(SHADERS + name + ".glslsrc").replace("\r", "")
