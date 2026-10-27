extends RefCounted
## After the decode: every texture's mip chain (mip_buf, one dispatch per level for all textures) and its blocks
## (blocks.glslsrc, the same), written in their final layout into one buffer that is read back: the caller makes
## the textures with that data, as Godot's own .ctex loading does.
## Formats: BC1 (opaque), BC3 (alpha), BC5 (normal maps); where the GPU can't sample BC (phones) ETC2 RGB8, ETC2
## RGBA8 and EAC RG11 instead, which have the same block sizes (`etc`, set once by the stream).

const Kernels := preload("kernels.gd")
const MAXL := 16

## ETC2 / EAC blocks instead of BC (the stream sets it from what the main device can sample).
static var etc := false

var g: Kernels
var rd: RenderingDevice
var blocks := [] # per texture: its blocks, mip levels in order (from skip_for on)


func _init(kernels: Kernels) -> void:
	g = kernels
	rd = kernels.rd


## Can `device` sample every format this path writes? BC first, else ETC2; neither: false.
static func choose_formats(device: RenderingDevice) -> bool:
	var bc := true
	for f in [RenderingDevice.DATA_FORMAT_BC1_RGB_UNORM_BLOCK, RenderingDevice.DATA_FORMAT_BC3_UNORM_BLOCK, RenderingDevice.DATA_FORMAT_BC5_UNORM_BLOCK]:
		bc = bc and device.texture_is_format_supported_for_usage(f, RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT)
	if bc and not "--jxl-etc" in OS.get_cmdline_user_args():
		etc = false
		return true
	var ok := true
	for f in [RenderingDevice.DATA_FORMAT_ETC2_R8G8B8_UNORM_BLOCK, RenderingDevice.DATA_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK, RenderingDevice.DATA_FORMAT_EAC_R11G11_UNORM_BLOCK]:
		ok = ok and device.texture_is_format_supported_for_usage(f, RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT)
	etc = true
	return ok


## A texture's format: normal maps two channels (BC5 / EAC RG11), alpha BC3 / ETC2 RGBA8, the rest BC1 / ETC2 RGB8.
## Colour formats also declare their sRGB twin as shareable: materials sample albedo through an sRGB view (Godot
## makes it for a Texture2DRD, but the texture must allow the reinterpretation from its creation). `info.skip`
## leaves that many top mip levels out (see skip_for).
static func texture_format(info: Dictionary) -> RDTextureFormat:
	var tf := RDTextureFormat.new()
	var skip := skip_for(info)
	tf.width = maxi(1, int(info.width) >> skip)
	tf.height = maxi(1, int(info.height) >> skip)
	tf.mipmaps = int(info.levels) - skip
	if info.normal:
		tf.format = RenderingDevice.DATA_FORMAT_EAC_R11G11_UNORM_BLOCK if etc else RenderingDevice.DATA_FORMAT_BC5_UNORM_BLOCK
		return tf
	var alpha: bool = info.get("alpha", false)
	var srgb: int
	if etc:
		tf.format = RenderingDevice.DATA_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK if alpha else RenderingDevice.DATA_FORMAT_ETC2_R8G8B8_UNORM_BLOCK
		srgb = RenderingDevice.DATA_FORMAT_ETC2_R8G8B8A8_SRGB_BLOCK if alpha else RenderingDevice.DATA_FORMAT_ETC2_R8G8B8_SRGB_BLOCK
	else:
		tf.format = RenderingDevice.DATA_FORMAT_BC3_UNORM_BLOCK if alpha else RenderingDevice.DATA_FORMAT_BC1_RGB_UNORM_BLOCK
		srgb = RenderingDevice.DATA_FORMAT_BC3_SRGB_BLOCK if alpha else RenderingDevice.DATA_FORMAT_BC1_RGB_SRGB_BLOCK
	tf.add_shareable_format(tf.format)
	tf.add_shareable_format(srgb)
	return tf


static func levels(w: int, h: int) -> int:
	return 1 + int(floor(log(float(maxi(w, h))) / log(2.0)))


## The top mip levels a texture leaves out (info.skip), at most as many as keep its largest level a whole number of
## 4x4 blocks across (D3D12 wants block-compressed textures in whole blocks).
static func skip_for(info: Dictionary) -> int:
	var skip := int(info.get("skip", 0))
	while skip > 0 and ((int(info.width) >> skip) < 4 or (int(info.height) >> skip) < 4 or (int(info.width) >> skip) % 4 != 0 \
			or (int(info.height) >> skip) % 4 != 0):
		skip -= 1
	return skip


## `infos`: per texture { width, height, rgba (word offset in b_rgba), normal, alpha, skip }. Waits for the GPU (a
## local device on the decoding thread) and fills `blocks`.
func run(infos: Array, b_rgba: RID) -> void:
	var lv := PackedInt32Array()
	lv.resize(infos.size() * MAXL * 12)
	var mip_words := 0
	var max_levels := 0
	var words := 0
	var chains := [] # per texture: [word offset, words] of the levels it keeps
	for t in infos.size():
		var info: Dictionary = infos[t]
		var w: int = info.width
		var h: int = info.height
		var n := levels(w, h)
		max_levels = maxi(max_levels, n)
		info.levels = n
		var mode := 2 if info.normal else (1 if info.get("alpha", false) else 0)
		var skip := skip_for(info)
		var start := words
		# per level (12 words): its buffer (0 rgba, 1 mips), offset, w, h, mode, sRGB, its blocks' word offset, 0, and
		# the previous level's buffer, offset, w, h (what mip_buf filters down from)
		var prev := [0, int(info.rgba), w, h]
		for l in n:
			var lw := maxi(1, w >> l)
			var lh := maxi(1, h >> l)
			var sel := 0 if l == 0 else 1
			var ofs: int = info.rgba if l == 0 else mip_words
			if l > 0:
				mip_words += lw * lh
			if l == skip:
				start = words
			var vals := [sel, ofs, lw, lh, mode, 0 if info.normal else 1, words, 0, prev[0], prev[1], prev[2], prev[3]]
			var e := (t * MAXL + l) * 12
			for k in 12:
				lv[e + k] = vals[k]
			words += ((lw + 3) / 4) * ((lh + 3) / 4) * (2 if mode == 0 else 4)
			prev = [sel, ofs, lw, lh]
		chains.append([start, words - start])
	var b_mips := rd.storage_buffer_create(maxi(4, mip_words * 4))
	var b_lv := g.buf(lv.to_byte_array())
	var b_out := rd.storage_buffer_create(words * 4)
	var kname := "blocks:ETC" if etc else "blocks"
	var s_mip := g.uset([b_rgba, b_mips, b_lv], "mip_buf")
	var s_blk := g.uset([b_rgba, b_mips, b_lv, b_out], kname)
	var max_w := 0
	var max_h := 0
	for info in infos:
		max_w = maxi(max_w, info.width)
		max_h = maxi(max_h, info.height)
	var cl := rd.compute_list_begin()
	for l in range(1, max_levels):
		var pc := PackedInt32Array([l, 0, 0, 0]).to_byte_array()
		rd.compute_list_bind_compute_pipeline(cl, g.kernel("mip_buf").pipe)
		rd.compute_list_bind_uniform_set(cl, s_mip, 0)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, (maxi(1, max_w >> l) + 7) / 8, (maxi(1, max_h >> l) + 7) / 8, infos.size())
		rd.compute_list_add_barrier(cl)
	for l in max_levels:
		var pc := PackedInt32Array([l, 0, 0, 0]).to_byte_array()
		rd.compute_list_bind_compute_pipeline(cl, g.kernel(kname).pipe)
		rd.compute_list_bind_uniform_set(cl, s_blk, 0)
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		var bw := (maxi(1, max_w >> l) + 3) / 4
		var bh := (maxi(1, max_h >> l) + 3) / 4
		rd.compute_list_dispatch(cl, (bw + 7) / 8, (bh + 7) / 8, infos.size())
	rd.compute_list_end()
	var data := rd.buffer_get_data(b_out) # waits for the GPU
	for t in infos.size():
		blocks.append(data.slice(int(chains[t][0]) * 4, (int(chains[t][0]) + int(chains[t][1])) * 4))
	for r in [s_mip, s_blk]:
		rd.free_rid(r)
	for b in [b_mips, b_lv, b_out]:
		rd.free_rid(b)
