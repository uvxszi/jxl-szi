extends Node
## JXL-SZI's runtime, the autoload JxlSzi (first of all): in an export made with the `jxl-szi` feature
## (export_plugin.gd writes res://addons/jxl_szi/data/: the textures as .jxl and manifest.json) it hands out the
## VRAM-compressed textures itself and decodes them on the GPU in the background from the moment the engine starts. Without the
## manifest (the editor, every other export) it does nothing and Godot's own textures load.
##
## - A worker thread decodes on its own local RenderingDevice (a second device on the same GPU, with its own queue):
##   stage on the CPU (jxl_stage.gd), then on the GPU entropy decode, transforms, mips and BC / ETC2 blocks
##   (gpu/decoder.gd, gpu/blocks.gd), read the blocks back; the main thread makes the final textures with that data,
##   as Godot's own .ctex loading does, at most UPLOAD_FRAME bytes a frame (or at once, for a texture the main
##   thread asks for while it loads a scene).
## - At startup the worker starts on the boot set (manifest "boot": the main scene's textures and whatever the
##   project listed, in rank order), BOOT_PART pixels at a time, while the engine loads the main scene. Every other
##   texture is decoded once something loads it.
## - Until then a texture shows its 16x16 thumbnail (manifest "thumb"): a Texture2DRD handed out for the PNG's path
##   and UID by a ResourceFormatLoader (the export leaves the PNGs' .ctex out), so scenes hold it from the start and
##   it fills in where it is.
## - The local device, and every scratch buffer with it, goes after IDLE_FREE s with nothing to do: once the boot set
##   is in, the game runs with no more memory than the textures themselves.
## - Formats: BC1 or BC7 / BC3 or BC7 / BC5 where the GPU samples BC (desktops), else ETC2 RGB8 / RGBA8 and EAC RG11
##   (phones).
## The settings are the project's (settings.gd: Project Settings > Jxl Szi > Blocks / Runtime). Switches (after `--`
## on the command line) override them for a run: --jxl-off (thumbnails only), --jxl-log (a line per part),
## --jxl-part-mp=<n> (boot part size), --jxl-threads=<n> (staging threads), --jxl-etc (ETC2 even where BC works),
## --jxl-opaque=bc1|bc7, --jxl-alpha=bc3|bc7, --jxl-bc7=0|1|2 (fast, balanced, best), --jxl-detail (detail by
## distance: lower mips for what's far away, decoded again as it comes closer).

const Settings := preload("res://addons/jxl_szi/settings.gd")
## Pixels per boot part: the scratch buffers hold one part (16 bytes a pixel), so phones take smaller ones.
static var BOOT_PART := (int(_arg("--jxl-part-mp=", str(Settings.value("jxl_szi/runtime/boot_part_megapixels_mobile" if OS.has_feature("mobile") else "jxl_szi/runtime/boot_part_megapixels")))) << 20)
## Detail that follows the camera: off by default. Each change is a decode on the worker's device, which keeps that
## device (and its memory) alive for as long as the camera moves, for a few MB of textures saved.
static var DETAIL: bool = "--jxl-detail" in OS.get_cmdline_user_args() or bool(Settings.value("jxl_szi/runtime/detail_by_distance"))
## The final textures are made on the main thread (Godot keeps an upload buffer per thread that makes textures, as big
## as its largest upload ever: a worker making them kept ~0.4 GB more memory on D3D12), at most this many bytes a frame.
static var UPLOAD_FRAME := maxi(1, int(Settings.value("jxl_szi/runtime/upload_megabytes_per_frame"))) << 20
static var STREAM_PART := 8 << 20
static var LOG: bool = "--jxl-log" in OS.get_cmdline_user_args() or bool(Settings.value("jxl_szi/runtime/log"))
static var OFF := "--jxl-off" in OS.get_cmdline_user_args()
const DATA := "res://addons/jxl_szi/data/" # what the export adds (export_plugin.gd)
const GPU := "res://addons/jxl_szi/runtime/gpu/"
const MANIFEST := DATA + "manifest.json"
static var START := _arg("--jxl-start=", "init") # when the worker starts: init (the first autoload) / frame (the first frame)
static var PRIORITY: int = { low = Thread.PRIORITY_LOW, normal = Thread.PRIORITY_NORMAL, high = Thread.PRIORITY_HIGH }.get(_arg("--jxl-priority=", "high"), Thread.PRIORITY_HIGH)

const STEP := 0.25
const FULL := 22.0
const HALF := 50.0
const NEAR := 12.0 # closer than this, out of view counts as in view (it's right behind you)
const KEEP := 8.0
## Seconds with nothing to decode before the worker's device and scratch memory go.
static var IDLE_FREE := float(Settings.value("jxl_szi/runtime/free_device_after_seconds"))


static func _arg(prefix: String, default: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.trim_prefix(prefix)
	return default


class Tex:
	var e: Dictionary # manifest entry: path, file, normal, uid, w, h, avg, boot
	var tex: Texture2D # what scenes and materials hold, all session long (a Texture2DRD; headless: a placeholder)
	var placeholder: RID
	var rid := RID() # the decoded texture (empty: the placeholder shows)
	var level := 99 # top mip levels `rid` leaves out (99: the placeholder)
	var want := 0
	var loaded := false # something in the game loaded it
	var busy := false # queued or decoding
	var ready_rid := RID() # decoded by the worker, not swapped in yet
	var ready_data := PackedByteArray() # or its blocks, for the main thread to make the texture with
	var ready_info := {}
	var ready_level := 99
	var users: Array = [] # WeakRefs to the GeometryInstance3Ds drawing it (--jxl-detail only)
	var in_finished := false # in _finished
	var important := false # on a character or in a hand: always full
	var over_since := -1.0 # since when it has had more detail than it needs


var texs := {} # res:// path of the PNG -> Tex
var stats := { textures = 0, loaded = 0, decoded = 0, parts = 0, decode_pixels = 0, upgrades = 0, downgrades = 0,
	read_ms = 0.0, stage_ms = 0.0, gpu_ms = 0.0, boot_done_ms = -1.0, first_all_ms = -1.0, device_ms = 0.0,
	kernels_compiled = 0, vram_mb = 0.0, swaps_on_request = 0 }
var parts_log := [] # per part: [queued, started, staged, decoded (textures made), MP, textures] ms since _init
var _lock := Mutex.new()
var _sem := Semaphore.new()
var _jobs: Array = [] # [{ texs: Array[Tex], levels: Array[int], queued: ms }] or { free = true }
var _done: Array = [] # superseded textures to free on the main thread: [null, rid, 99]
var _finished: Array[Tex] = [] # decoded by the worker, to swap in (the main thread)
var _dirty := false # something was loaded since the last _schedule
var _quit := false
var _working := false # the worker has a job
var _thread: Thread
var _loader: StreamLoader
var _rd: RenderingDevice
var _t := 0.0
var _t0 := 0
var _idle := 0.0
var _local_alive := false
var _new_nodes: Array = []
var _main_thread := 0
# the worker's own (only it touches these)
var _local: RenderingDevice
var _gpu: RefCounted # a decoder (gpu/decoder.gd)
var _stage: GDScript # jxl_stage.gd
var _blocks: GDScript # gpu/blocks.gd
var _decoder: GDScript # gpu/decoder.gd
var _scratch := {}


## Placeholders, the loader and the worker with the boot set, before any scene loads (the first autoload).
func _init() -> void:
	_t0 = Time.get_ticks_msec()
	_main_thread = OS.get_thread_caller_id()
	_rd = RenderingServer.get_rendering_device()
	if not FileAccess.file_exists(MANIFEST):
		OFF = true
		return # not a JPEG XL export: Godot's own textures
	var man: Array = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	for e: Dictionary in man:
		var t := Tex.new()
		t.e = e
		if _rd:
			t.placeholder = _placeholder(e)
			var rd_tex := Texture2DRD.new()
			rd_tex.texture_rd_rid = t.placeholder
			t.tex = rd_tex
		else: # headless (a dedicated server): nothing is drawn, a texture only needs its size
			var ph := PlaceholderTexture2D.new()
			ph.size = Vector2(int(e.w), int(e.h))
			t.tex = ph
		texs[e.path] = t
		# scenes refer to the PNG by its UID first, and the export left the PNG out: point the UID at the path
		var uid := ResourceUID.text_to_id(String(e.get("uid", "")))
		if uid != ResourceUID.INVALID_ID:
			if ResourceUID.has_id(uid):
				ResourceUID.set_id(uid, e.path)
			else:
				ResourceUID.add_id(uid, e.path)
	stats.textures = texs.size()
	_loader = StreamLoader.new()
	_loader.stream = self
	ResourceLoader.add_resource_format_loader(_loader, true)
	if OFF or _rd == null:
		print("JXL-SZI %s: thumbnails only" % ("off" if OFF else "headless"))
		return
	_stage = load("res://addons/jxl_szi/runtime/jxl_stage.gd")
	_blocks = load(GPU + "blocks.gd")
	_decoder = load(GPU + "decoder.gd")
	_stage.set("THREADS", clampi(int(_arg("--jxl-threads=", str(Settings.value("jxl_szi/runtime/staging_threads")))), 1, 16))
	_blocks.set("opaque_bc7", _arg("--jxl-opaque=", "bc7" if int(Settings.value("jxl_szi/blocks/opaque_format")) == 1 else "bc1") == "bc7")
	_blocks.set("alpha_bc7", _arg("--jxl-alpha=", "bc7" if int(Settings.value("jxl_szi/blocks/alpha_format")) == 1 else "bc3") == "bc7")
	_blocks.set("bc7_quality", clampi(int(_arg("--jxl-bc7=", str(Settings.value("jxl_szi/blocks/encoder_search")))), 0, 2))
	_blocks.set("refine", clampi(int(Settings.value("jxl_szi/blocks/refinement_passes")), 0, 3))
	_blocks.set("bc4_search", bool(Settings.value("jxl_szi/blocks/single_channel_search")))
	if not _blocks.call("choose_formats", _rd):
		push_error("JXL-SZI: this GPU samples neither BC nor ETC2 textures: thumbnails only")
		OFF = true
		return
	# the boot set, in rank order, in parts
	var boot: Array[Tex] = []
	for t: Tex in texs.values():
		if t.e.has("boot"):
			boot.append(t)
	boot.sort_custom(func(a: Tex, b: Tex) -> bool:
		return int(a.e.boot) < int(b.e.boot) if int(a.e.boot) != int(b.e.boot) else String(a.e.path) < String(b.e.path))
	var part: Array[Tex] = []
	var px := 0
	for t in boot:
		var n := int(t.e.w) * int(t.e.h)
		if not part.is_empty() and px + n > BOOT_PART:
			_queue(part, 0)
			part = []
			px = 0
		part.append(t)
		px += n
	if not part.is_empty():
		_queue(part, 0)
	if START == "init":
		_start_worker()
	print("JXL-SZI ready: %d textures, %d to decode from the start, in %d ms" % [texs.size(), boot.size(), Time.get_ticks_msec() - _t0])


func _start_worker() -> void:
	_thread = Thread.new()
	_thread.start(_work, PRIORITY)


func _ready() -> void:
	if OFF or _rd == null:
		set_process(false)
		return
	if DETAIL: # who draws what, for the detail by distance
		get_tree().node_added.connect(func(n: Node) -> void:
			if n is GeometryInstance3D:
				_new_nodes.append(n))
	process_priority = 100


## The texture's 16x16 thumbnail (manifest "thumb", alpha included; without one a 4x4 of its average colour, flat for
## a normal map), with the sRGB view materials sample colour through.
func _placeholder(e: Dictionary) -> RID:
	var tf := RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	tf.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	tf.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB)
	var px := Marshalls.base64_to_raw(String(e.get("thumb", "")))
	if px.size() == 16 * 16 * 4:
		tf.width = 16
		tf.height = 16
		return _rd.texture_create(tf, RDTextureView.new(), [px])
	var c: Array = e.get("avg", [0.5, 0.5, 0.5, 1.0])
	if e.get("normal", false):
		c = [0.5, 0.5, 1.0, 1.0]
	tf.width = 4
	tf.height = 4
	px = PackedByteArray()
	for i in 16:
		for k in 4:
			px.append(clampi(roundi(float(c[k]) * 255.0), 0, 255))
	return _rd.texture_create(tf, RDTextureView.new(), [px])


## The loader's hand-out (any thread): the texture's Texture2DRD, now wanted. On the main thread a texture the
## worker has finished is swapped in at once (the main scene's textures, as it loads).
func request(path: String) -> Resource:
	var t: Tex = texs.get(path)
	if t == null:
		return null
	var swap := RID()
	var level := 99
	_lock.lock()
	if not t.loaded:
		t.loaded = true
		stats.loaded += 1
		_dirty = true
	if OS.get_thread_caller_id() == _main_thread:
		if t.ready_rid.is_valid():
			swap = t.ready_rid
			level = t.ready_level
			t.ready_rid = RID()
		elif not t.ready_data.is_empty():
			swap = _make(t)
			level = t.ready_level
	_lock.unlock()
	if swap.is_valid():
		_swap(t, swap, level)
		t.busy = false
		stats.swaps_on_request += 1
		_milestones()
	return t.tex


# The worker ---------------------------------------------------------------------------------------------------------

func _queue(part: Array[Tex], level: int) -> void:
	var levels: Array[int] = []
	for t in part:
		t.busy = true
		levels.append(level)
	_lock.lock()
	_jobs.append({ texs = part, levels = levels, queued = Time.get_ticks_msec() - _t0 })
	_lock.unlock()
	_sem.post()


func _work() -> void:
	while true:
		_sem.wait()
		_lock.lock()
		if _quit:
			_lock.unlock()
			break
		var job: Dictionary = _jobs.pop_front() if not _jobs.is_empty() else {}
		_working = not job.is_empty()
		_lock.unlock()
		if job.is_empty():
			continue
		if job.get("free", false):
			_free_local()
		else:
			_decode(job)
		_lock.lock()
		_working = false
		_lock.unlock()
	_free_local()


func _ensure_local() -> bool:
	if _local:
		return true
	var t0 := Time.get_ticks_usec()
	_local = RenderingServer.create_local_rendering_device()
	if _local == null:
		return false
	_gpu = _decoder.new()
	_lock.lock()
	_local_alive = true
	_lock.unlock()
	stats.device_ms += (Time.get_ticks_usec() - t0) / 1000.0
	return true


func _free_local() -> void:
	if _local == null:
		return
	for k: String in ["coeffs", "rgba", "alpha"]:
		if _scratch.has(k):
			_local.free_rid(_scratch[k])
	_scratch = {}
	if _gpu:
		var g: Variant = _gpu.get("g")
		stats.kernels_compiled += int(g.get("compiled")) if g else 0
		_gpu.call("release")
		_gpu = null
	_local.free()
	_local = null
	_lock.lock()
	_local_alive = false
	_lock.unlock()


func _decode(job: Dictionary) -> void:
	var started := Time.get_ticks_msec() - _t0
	var part: Array = job.texs
	if not _ensure_local():
		return
	var t0 := Time.get_ticks_usec()
	var blobs := []
	var names := PackedStringArray()
	var by := {}
	for i in part.size():
		var t: Tex = part[i]
		blobs.append(FileAccess.get_file_as_bytes(DATA + String(t.e.file)))
		var stem := String(t.e.file).get_basename()
		names.append(stem)
		by[stem] = [t, job.levels[i]]
	var t1 := Time.get_ticks_usec()
	var st: Dictionary = _stage.stage_blobs(blobs, names, 96)
	var t2 := Time.get_ticks_usec()
	var out := []
	var infos: Array = st.get("textures", [])
	if not infos.is_empty():
		for info: Dictionary in infos:
			info.normal = by[info.name][0].e.normal # the import's normal-map flag, not the name guess
			info.skip = by[info.name][1]
		_ensure_scratch(st)
		st.pre = _scratch
		# waits for the GPU: each texture's blocks, read back
		var made: Array = _gpu.call("decode", _local, st)
		for i in made.size():
			out.append([by[infos[i].name][0], made[i], _blocks.skip_for(infos[i]), infos[i]])
	var t3 := Time.get_ticks_usec()
	stats.read_ms += (t1 - t0) / 1000.0
	stats.stage_ms += (t2 - t1) / 1000.0
	stats.gpu_ms += (t3 - t2) / 1000.0
	stats.parts += 1
	var px := 0
	for t: Tex in part:
		px += int(t.e.w) * int(t.e.h)
	parts_log.append([job.queued, started, started + (t2 - t0) / 1000.0, Time.get_ticks_msec() - _t0, snappedf(px / 1048576.0, 0.1), part.size()])
	_lock.lock()
	for o in out:
		var t: Tex = o[0]
		if t.ready_rid.is_valid(): # superseded before it was swapped in
			_done.append([null, t.ready_rid, 99])
			t.ready_rid = RID()
		t.ready_data = o[1]
		t.ready_info = o[3]
		t.ready_level = o[2]
		if not t.in_finished:
			t.in_finished = true
			_finished.append(t)
	for t: Tex in part:
		if not t.ready_rid.is_valid() and t.ready_data.is_empty():
			t.busy = false # not staged (unreadable): left as it is
	_lock.unlock()
	if LOG:
		print("JXL-SZI part %d: %d textures, %.1f MP, read %.1f ms, staged %.1f ms, GPU + textures %.1f ms" % [stats.parts, part.size(), px / 1048576.0, (t1 - t0) / 1000.0, (t2 - t1) / 1000.0, (t3 - t2) / 1000.0])


func _ensure_scratch(st: Dictionary) -> void:
	var need := { coeff_words = int(st.coeff_words), rgba_words = int(st.rgba_words), alpha_words = maxi(1, int(st.alpha_words)) }
	if not _scratch.is_empty():
		var s: Dictionary = _scratch.sizes
		if s.coeff_words >= need.coeff_words and s.rgba_words >= need.rgba_words and s.alpha_words >= need.alpha_words:
			return
		for k: String in ["coeffs", "rgba", "alpha"]:
			_local.free_rid(_scratch[k])
	# room for a whole boot part (16 bytes a pixel), so it's made once
	need.coeff_words = maxi(need.coeff_words, BOOT_PART * 3)
	need.rgba_words = maxi(need.rgba_words, BOOT_PART)
	_scratch = { coeffs = _local.storage_buffer_create(need.coeff_words * 4), rgba = _local.storage_buffer_create(need.rgba_words * 4),
		alpha = _local.storage_buffer_create(need.alpha_words * 4), sizes = need }


# The main thread ----------------------------------------------------------------------------------------------------

func _process(dt: float) -> void:
	if OFF or _rd == null:
		return
	if _thread == null:
		_start_worker()
	_swap_ready()
	if DETAIL:
		_find_users()
	_t += dt
	if _t >= STEP:
		_t = 0.0
		if DETAIL:
			_update_wants()
		if DETAIL or _dirty:
			_schedule()
	_lock.lock()
	var idle := _jobs.is_empty() and not _working and _local_alive
	_lock.unlock()
	_idle = _idle + dt if idle else 0.0
	if _idle > IDLE_FREE:
		_idle = 0.0
		_lock.lock()
		_jobs.append({ free = true })
		_lock.unlock()
		_sem.post()


## The worker's finished textures go in (and superseded ones out); textures to make from blocks, UPLOAD_FRAME bytes
## of them a frame (the ones something asked for first).
func _swap_ready() -> void:
	_lock.lock()
	if _finished.is_empty() and _done.is_empty():
		_lock.unlock()
		return
	var got := []
	var budget := UPLOAD_FRAME
	var left: Array[Tex] = []
	for pass_loaded in [true, false]:
		for t: Tex in _finished:
			if t.loaded != pass_loaded:
				continue
			if t.ready_rid.is_valid():
				got.append([t, t.ready_rid, t.ready_level])
				t.ready_rid = RID()
			elif not t.ready_data.is_empty():
				if budget <= 0:
					left.append(t)
					continue
				budget -= t.ready_data.size()
				got.append([t, _make(t), t.ready_level])
			t.in_finished = false # swapped in, or already on request
	_finished = left
	var stale := _done
	_done = []
	_lock.unlock()
	for g in got:
		_swap(g[0], g[1], g[2])
		(g[0] as Tex).busy = false
	for s in stale:
		_rd.free_rid(s[1])
	if not got.is_empty():
		_milestones()


func _milestones() -> void:
	if stats.boot_done_ms < 0.0 and _boot_in():
		stats.boot_done_ms = Time.get_ticks_msec() - _t0
		print("JXL-SZI boot set in at %d ms: %s" % [stats.boot_done_ms, JSON.stringify(stats)])
	if stats.first_all_ms < 0.0 and _all_decoded():
		stats.first_all_ms = Time.get_ticks_msec() - _t0


## Makes `t`'s texture on the main device from the blocks the worker read back (the main thread, under _lock).
func _make(t: Tex) -> RID:
	var tf: RDTextureFormat = _blocks.texture_format(t.ready_info)
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var rid := _rd.texture_create(tf, RDTextureView.new(), [t.ready_data])
	t.ready_data = PackedByteArray()
	t.ready_info = {}
	return rid


func _boot_in() -> bool:
	for t: Tex in texs.values():
		if t.e.has("boot") and t.level == 99:
			return false
	return true


func _all_decoded() -> bool:
	for t: Tex in texs.values():
		if t.loaded and t.level == 99:
			return false
	return true


## `t` shows `rid` (with `level` top mip levels left out) from now on; its old texture goes once the frame is done.
func _swap(t: Tex, rid: RID, level: int) -> void:
	var old := t.rid
	if t.level != 99:
		if level < t.level:
			stats.upgrades += 1
		elif level > t.level:
			stats.downgrades += 1
	else:
		stats.decoded += 1
	stats.decode_pixels += int(t.e.w) * int(t.e.h)
	stats.vram_mb += (_bytes(t.e, level) - (_bytes(t.e, t.level) if old.is_valid() else 0)) / 1048576.0
	t.rid = rid
	t.level = level
	t.over_since = -1.0
	(t.tex as Texture2DRD).texture_rd_rid = rid
	if old.is_valid():
		_rd.free_rid(old)


## A BC texture's size with `skip` top levels left out (BC1 half a byte a pixel, BC3 / BC5 one).
static func _bytes(e: Dictionary, skip: int) -> int:
	var w := int(e.w) >> skip
	var h := int(e.h) >> skip
	var per := 1.0 if e.get("normal", false) else 0.5 # BC3 with alpha is 1 too: close enough for a running figure
	var total := 0.0
	while true:
		total += maxi(4, w) * maxi(4, h) * per
		if w <= 1 and h <= 1:
			break
		w = maxi(1, w / 2)
		h = maxi(1, h / 2)
	return int(total)


## Who draws which texture: the GeometryInstance3Ds that entered the tree last frame (their materials are set by then).
func _find_users() -> void:
	if _new_nodes.is_empty():
		return
	var nodes := _new_nodes
	_new_nodes = []
	for n in nodes:
		if not is_instance_valid(n):
			continue
		var g := n as GeometryInstance3D
		var important := _important(g)
		for m in materials_of(g):
			for tx in textures_of(m):
				var t: Tex = texs.get(tx.resource_path)
				if t and t.tex == tx:
					t.users.append(weakref(g))
					t.important = t.important or important


## The materials `g` draws with (override, the surfaces' active ones, a MultiMesh's).
static func materials_of(g: GeometryInstance3D) -> Array[Material]:
	var mats: Array[Material] = []
	if g.material_override:
		mats.append(g.material_override)
	if g is MeshInstance3D and (g as MeshInstance3D).mesh:
		var mi := g as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s)
			if m:
				mats.append(m)
	elif g is MultiMeshInstance3D and (g as MultiMeshInstance3D).multimesh and (g as MultiMeshInstance3D).multimesh.mesh:
		var mm := (g as MultiMeshInstance3D).multimesh.mesh
		for s in mm.get_surface_count():
			if mm.surface_get_material(s):
				mats.append(mm.surface_get_material(s))
	return mats


static func _important(n: Node) -> bool:
	var p := n
	while p:
		if p is CharacterBody3D or p.is_in_group(&"jxl_full_detail"):
			return true
		p = p.get_parent()
	return false


static func textures_of(m: Material) -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	while m:
		if m is BaseMaterial3D:
			for i in BaseMaterial3D.TEXTURE_MAX:
				var tx := (m as BaseMaterial3D).get_texture(i)
				if tx is Texture2DRD:
					out.append(tx)
		elif m is ShaderMaterial and (m as ShaderMaterial).shader:
			for u in (m as ShaderMaterial).shader.get_shader_uniform_list():
				var v = (m as ShaderMaterial).get_shader_parameter(u.name)
				if v is Texture2DRD:
					out.append(v)
		m = m.next_pass
	return out


## How much detail each wanted texture needs now (0 = full, 1 = a quarter of the memory, 2 = 1/16). Textures nothing
## draws yet keep what they have (full when they have nothing).
func _update_wants() -> void:
	var cam := get_viewport().get_camera_3d()
	var planes: Array[Plane] = cam.get_frustum() if cam else []
	var now := Time.get_ticks_msec() / 1000.0
	for t: Tex in texs.values():
		if not t.loaded:
			continue
		var want := t.level if t.level != 99 else 0
		if t.important:
			want = 0
		elif cam and not t.users.is_empty():
			var live := []
			var best := 2
			for w: WeakRef in t.users:
				var g := w.get_ref() as GeometryInstance3D
				if g == null or not g.is_inside_tree():
					continue
				live.append(w)
				if not g.is_visible_in_tree():
					continue
				var box := g.global_transform * g.get_aabb()
				var c := box.get_center()
				var r := box.size.length() * 0.5
				var d := maxf(0.0, cam.global_position.distance_to(c) - r)
				var seen := true
				for p in planes:
					if p.distance_to(c) > r:
						seen = false
						break
				var lvl := 0 if d < FULL else (1 if d < HALF else 2)
				if not seen and d >= NEAR:
					lvl = 2
				best = mini(best, lvl)
				if best == 0:
					break
			t.users = live
			if not live.is_empty():
				want = best
		t.want = want
		if t.level < want and t.rid.is_valid():
			if t.over_since < 0.0:
				t.over_since = now
		else:
			t.over_since = -1.0


## Hands the worker what needs decoding once it has nothing queued: wanted textures with nothing yet or less detail than
## they need (those with nothing first), and ones with more than they need for KEEP s (decoded again smaller), at most
## STREAM_PART pixels a job, one job per detail level.
func _schedule() -> void:
	_lock.lock()
	var queued := _jobs.size()
	if queued == 0:
		_dirty = false
	_lock.unlock()
	if queued > 0:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var todo: Array[Tex] = []
	for t: Tex in texs.values():
		if not t.loaded or t.busy:
			continue
		if t.level == 99 or (DETAIL and (t.level > t.want or (t.over_since >= 0.0 and now - t.over_since >= KEEP and t.want > t.level))):
			todo.append(t)
	if todo.is_empty():
		return
	todo.sort_custom(func(a: Tex, b: Tex) -> bool:
		if (a.level == 99) != (b.level == 99):
			return a.level == 99
		return a.want < b.want)
	var by_level := {}
	for t in todo:
		var lvl := t.want if DETAIL else 0
		if not by_level.has(lvl):
			by_level[lvl] = [[], 0]
		var slot: Array = by_level[lvl]
		var n := int(t.e.w) * int(t.e.h)
		if not (slot[0] as Array).is_empty() and int(slot[1]) + n > STREAM_PART:
			_dirty = true # the rest next round
			continue
		(slot[0] as Array).append(t)
		slot[1] = int(slot[1]) + n
	for lvl: int in by_level:
		var part: Array[Tex] = []
		part.assign(by_level[lvl][0])
		_queue(part, lvl)


func _exit_tree() -> void:
	if _thread:
		_lock.lock()
		_quit = true
		_lock.unlock()
		_sem.post()
		_thread.wait_to_finish()
		_thread = null
	if texs.is_empty():
		return
	var levels := [0, 0, 0, 0]
	for t: Tex in texs.values():
		if t.rid.is_valid():
			levels[mini(t.level, 3)] += 1
	stats.at_exit_levels = levels
	print("JXL-SZI at exit: %s" % JSON.stringify(stats))
	if _rd:
		for t: Tex in texs.values():
			(t.tex as Texture2DRD).texture_rd_rid = RID()
			for r in [t.rid, t.ready_rid, t.placeholder]:
				if r.is_valid():
					_rd.free_rid(r)


## Hands out JxlStream's textures for the PNGs' paths (ahead of Godot's own importer), from any loader thread.
class StreamLoader extends ResourceFormatLoader:
	var stream: Node

	func _get_recognized_extensions() -> PackedStringArray:
		return PackedStringArray(["png"])

	func _recognize_path(path: String, _type: StringName) -> bool:
		return (stream.texs as Dictionary).has(path)

	func _handles_type(type: StringName) -> bool:
		return type == &"" or ClassDB.is_parent_class(&"Texture2DRD", type) or type == &"Texture2DRD"

	func _get_resource_type(path: String) -> String:
		return "Texture2D" if (stream.texs as Dictionary).has(path) else ""

	func _exists(path: String) -> bool:
		return (stream.texs as Dictionary).has(path)

	func _load(path: String, original_path: String, _use_sub_threads: bool, _cache_mode: int) -> Variant:
		var p := original_path if original_path != "" else path
		var r: Resource = stream.request(p)
		return r if r else ERR_FILE_NOT_FOUND
