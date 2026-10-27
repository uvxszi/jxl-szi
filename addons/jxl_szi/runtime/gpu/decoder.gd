extends RefCounted
## A staged batch of JPEG XL textures (jxl_stage.gd) decoded on a RenderingDevice: HF entropy decode (hf_decode6) and
## alpha (alpha_decode), then the 8x8 and larger inverse transforms and colour (vd8, vdl2) into RGBA8, then mips and
## blocks (blocks.gd). decode() waits for the GPU and returns each texture's blocks.

const Kernels := preload("kernels.gd")
const Blocks := preload("blocks.gd")
## The transforms' constant tables (inverse DCT bases, the 8x8 transforms as 64x64 matrices), precomputed: making
## them on the GPU made D3D12 keep ~350 MB of per-thread memory for that kernel for as long as the device lived.
const CONSTS_FILE := "res://addons/jxl_szi/runtime/gpu/consts.bin"

var g: Kernels # compiled kernels and the constant tables, kept between batches
var _consts: RID
var _dummy: RID


## Decodes batch `st` on `rd`; its scratch buffers are st.pre (shared between batches, freed by the caller) when it
## has them. Returns the blocks per texture, in st.textures' order.
func decode(rd: RenderingDevice, st: Dictionary) -> Array:
	var ctx := _hf(rd, st)
	var cl := rd.compute_list_begin()
	_transforms(rd, cl, ctx)
	rd.compute_list_end()
	var bl := Blocks.new(g)
	bl.run(st.textures, ctx.b_rgba)
	for r in [ctx.s_hf, ctx.s_alpha, ctx.s8, ctx.sl]:
		rd.free_rid(r)
	var keep: Array = (st.pre as Dictionary).values() if st.has("pre") else []
	for b in ctx.hf_bufs + (ctx.vd_bufs as Array).slice(0, 2) + [ctx.b_rgba, (ctx.vd_bufs as Array)[6]] + (ctx.a_bufs as Array).slice(1, 3) + [(ctx.a_bufs as Array)[4]]:
		if not keep.has(b):
			rd.free_rid(b)
	return bl.blocks


## Frees what this decoder keeps on its device (kernels, constant tables), before the device goes.
func release() -> void:
	if g == null:
		return
	for r in [_consts, _dummy]:
		if r.is_valid():
			g.rd.free_rid(r)
	g.release()
	g = null


## Uploads a staged batch and records its alpha and HF decode; returns what _transforms needs.
func _hf(rd: RenderingDevice, st: Dictionary) -> Dictionary:
	if g == null:
		g = Kernels.new(rd)
		_dummy = g.buf(PackedByteArray([0, 0, 0, 0]))
		_consts = g.buf(FileAccess.get_file_as_bytes(CONSTS_FILE))
	var coeff_bytes: int = st.coeff_words * 4
	# the big buffers: the shared scratch ones (st.pre) when they're big enough, else made here
	var pre: Dictionary = st.get("pre", {})
	var fits: bool = not pre.is_empty() and int(pre.sizes.coeff_words) >= int(st.coeff_words) \
			and int(pre.sizes.rgba_words) >= int(st.rgba_words) and int(pre.sizes.alpha_words) >= int(st.alpha_words)
	assert(fits or pre.is_empty(), "a batch is bigger than the shared scratch buffers")
	var b_coeffs: RID = pre.coeffs if fits else rd.storage_buffer_create(coeff_bytes)
	var b_rgba: RID = pre.rgba if fits else rd.storage_buffer_create(int(st.rgba_words) * 4)
	var b_alpha: RID = pre.alpha if fits else rd.storage_buffer_create(int(st.alpha_words) * 4)
	var hf_bufs := [_upload(rd, st.bits), _upload(rd, st.groups), _upload(rd, st.ptables), _upload(rd, st.blist), b_coeffs,
		_upload(rd, st.records), _upload(rd, st.work)]
	var vd_bufs := [_upload(rd, st.vd_params), _upload(rd, st.vd_input), b_coeffs, _dummy, b_rgba, _consts, b_alpha]
	var a_bufs := [hf_bufs[0], _upload(rd, st.apl), _upload(rd, st.atables), b_alpha, _upload(rd, st.adata)]
	var s_alpha := g.uset(a_bufs, _alpha_kernel(rd))
	var hfk := "hf_decode6:WORK4"
	var s_hf := g.uset(hf_bufs, hfk)
	rd.buffer_clear(b_coeffs, 0, coeff_bytes)
	var cl := rd.compute_list_begin()
	# the alpha groups first: independent of the HF decode, and all their workgroups fit the GPU at once, so the HF
	# workgroups fill in around them
	if st.alpha_groups > 0:
		var slots := _alpha_slots(rd)
		rd.compute_list_bind_compute_pipeline(cl, g.kernel(_alpha_kernel(rd)).pipe)
		rd.compute_list_bind_uniform_set(cl, s_alpha, 0)
		var apc := PackedInt32Array([st.alpha_groups, 0, 0, 0]).to_byte_array()
		rd.compute_list_set_push_constant(cl, apc, apc.size())
		rd.compute_list_dispatch(cl, (int(st.alpha_groups) + slots - 1) / slots, 1, 1)
	rd.compute_list_bind_compute_pipeline(cl, g.kernel(hfk).pipe)
	rd.compute_list_bind_uniform_set(cl, s_hf, 0)
	rd.compute_list_dispatch(cl, (st.work as PackedByteArray).size() / 16, 1, 1)
	rd.compute_list_end()
	return { st = st, hf_bufs = hf_bufs, vd_bufs = vd_bufs, b_rgba = b_rgba, s_hf = s_hf, a_bufs = a_bufs, s_alpha = s_alpha }


## Records a batch's transforms + colour into compute list `cl` (after its HF decode).
func _transforms(_rd: RenderingDevice, cl: int, ctx: Dictionary) -> void:
	var st: Dictionary = ctx.st
	# without 32x32 varblocks the larger-block kernel needs half the shared memory (more workgroups at once) and does
	# better with 128 threads
	var kl := "vdl2" if st.get("has_dct32", true) else "vdl2:MAX512,THREADS 128"
	ctx.s8 = g.uset(ctx.vd_bufs, "vd8:NATURAL")
	ctx.sl = g.uset(ctx.vd_bufs, kl)
	if st.small_count > 0:
		g.dispatch_list(cl, "vd8:NATURAL", ctx.s8, st.small_list, st.small_count)
	if st.big_count > 0:
		g.dispatch_list(cl, kl, ctx.sl, st.big_list, st.big_count)


## Pass groups per alpha workgroup: 16 (~44 KB of shared memory) where the GPU has 48 KB or more, else 8 (~22 KB;
## Vulkan guarantees only 16 KB, many mobile GPUs have 32).
static func _alpha_slots(device: RenderingDevice) -> int:
	return 16 if device.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_SHARED_MEMORY_SIZE) >= 48 * 1024 else 8


static func _alpha_kernel(device: RenderingDevice) -> String:
	return "alpha_decode" if _alpha_slots(device) == 16 else "alpha_decode:SLOTS 8"


## A storage buffer holding `bytes`: created empty, then filled with buffer_update (through the device's mapped
## staging blocks: faster than creating it with the data, which goes through a transfer worker's staging buffer).
func _upload(rd: RenderingDevice, bytes: PackedByteArray) -> RID:
	var b := rd.storage_buffer_create(maxi(bytes.size(), 4))
	if not bytes.is_empty():
		rd.buffer_update(b, 0, bytes.size(), bytes)
	return b
