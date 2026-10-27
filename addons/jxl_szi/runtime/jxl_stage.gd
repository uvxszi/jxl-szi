extends RefCounted
## Staging JPEG XL textures for the GPU decoder (gpu/decoder.gd), in GDScript. Each exported file carries its staged
## job in a `sziZ` box (written by the converter's stager with JXL_SZI_SIDE=z): a u32 length, JSON { header, sections:
## [[name, bytes]...], groups: [[file offset, bytes]...] }, then the sections in one zlib stream. Staging is: inflate
## it, copy each pass group's bytes out of the codestream, and pack a batch for the kernels.
## The files are staged on WorkerThreadPool threads (THREADS of them, at normal priority: the game's own loading comes
## first), one task per file; packing appends their pieces in order.

const JOB_STRIDE := 64
const VSTRIDE := 192
const APL_STRIDE := 32
const VD_SECTIONS := ["hfmul", "lf_xyb", "cfl", "mats", "iorders", "biglist", "smalllist"]
static var THREADS := 3


## The payload of the box `ty` in a JPEG XL container (empty if there's none).
static func find_box(bytes: PackedByteArray, ty: String) -> PackedByteArray:
	if bytes.size() < 12 or bytes.slice(4, 8).get_string_from_ascii() != "JXL ":
		return PackedByteArray()
	var want := ty.to_ascii_buffer()
	var at := 0
	while at + 8 <= bytes.size():
		var size := (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]
		var hdr := 8
		if size == 1:
			size = 0
			for k in 8:
				size = (size << 8) | bytes[at + 8 + k]
			hdr = 16
		elif size == 0:
			size = bytes.size() - at
		if bytes.slice(at + 4, at + 8) == want:
			return bytes.slice(at + hdr, at + size)
		if size < hdr:
			break
		at += size
	return PackedByteArray()


## One file from its sziZ box: { h: header, s: { section: bytes } }, or { error }.
static func stage_file(bytes: PackedByteArray, name: String) -> Dictionary:
	var data := find_box(bytes, "sziZ")
	if data.size() < 4:
		return { error = "%s: no sziZ box" % name }
	var ml := data.decode_u32(0)
	var meta: Variant = JSON.parse_string(data.slice(4, 4 + ml).get_string_from_utf8())
	if not (meta is Dictionary):
		return { error = "%s: bad side box" % name }
	var total := 0
	for e: Array in meta.sections:
		total += int(e[1])
	var blob := data.slice(4 + ml).decompress(total, FileAccess.COMPRESSION_DEFLATE)
	if blob.size() != total:
		return { error = "%s: side box: short data" % name }
	var s := {}
	# "bits": each pass group's bytes from the file, from a word boundary, two zero words after it
	var bits := PackedByteArray()
	for g: Array in meta.groups:
		var o := int(g[0])
		var n := int(g[1])
		if o + n > bytes.size():
			return { error = "%s: side box: a pass group outside the file" % name }
		bits.append_array(bytes.slice(o, o + n))
		bits.resize(((bits.size() + 3) / 4) * 4 + 8)
	s.bits = bits
	var at := 0
	for e: Array in meta.sections:
		var len := int(e[1])
		s[String(e[0])] = blob.slice(at, at + len)
		at += len
	var h: Dictionary = meta.header
	h.name = name
	return { h = h, s = s }


static func _f32(v: float) -> float:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	return b.decode_float(0)


static func _u(h: Dictionary, k: String) -> int:
	return int(h.get(k, 0))


static func _f(h: Dictionary, k: String) -> float:
	return float(h.get(k, 0.0))


static func _words(s: Dictionary, n: String) -> int:
	return (s.get(n, PackedByteArray()) as PackedByteArray).size() / 4


## The HF decode records (one per pass) and the reconstruction params record of an image placed at `pl`.
static func _records(h: Dictionary, pl: Dictionary) -> Array:
	var w8 := _u(h, "w8")
	var h8 := _u(h, "h8")
	var passes := maxi(1, _u(h, "num_passes"))
	var pb: int = pl.ptables
	var rec := PackedByteArray()
	var plist: Array = h.get("passes", [])
	rec.resize(plist.size() * JOB_STRIDE * 4)
	for i in plist.size():
		var pr: Dictionary = plist[i]
		var b := i * JOB_STRIDE * 4
		rec.encode_u32(b + 0 * 4, _u(pr, "t_cmap") + pb)
		rec.encode_u32(b + 1 * 4, _u(pr, "t_cfg") + pb)
		rec.encode_u32(b + 2 * 4, _u(pr, "t_bkt") + pb)
		rec.encode_u32(b + 4 * 4, _u(pr, "t_ord") + pb)
		rec.encode_u32(b + 5 * 4, _u(h, "nbc"))
		rec.encode_u32(b + 7 * 4, _u(pr, "log_bucket_size"))
		rec.encode_u32(b + 8 * 4, w8)
		rec.encode_u32(b + 10 * 4, int(pl.coeff) & 0xffffffff)
		rec.encode_u32(b + 11 * 4, h8)
		var oo: Array = pr.get("ord_ofs", [])
		for k in oo.size():
			rec.encode_u32(b + (12 + k) * 4, int(oo[k]))
		rec.encode_u32(b + 33 * 4, _u(pr, "num_clusters"))
		rec.encode_u32(b + 34 * 4, _u(pr, "shift"))
		rec.encode_u32(b + 35 * 4, 1 if passes > 1 else 0)
	var cw := (w8 + 7) / 8
	var ch := (h8 + 7) / 8
	var o: Array = pl.vd_ofs
	var r := PackedByteArray()
	r.resize(VSTRIDE * 4)
	var put := func(i: int, v: int) -> void: r.encode_u32(i * 4, v & 0xffffffff)
	var putf := func(i: int, v: float) -> void: r.encode_float(i * 4, v)
	put.call(0, w8)
	put.call(1, h8)
	put.call(2, o[0])
	put.call(3, pl.coeff)
	put.call(4, pl.coeff)
	put.call(5, o[1])
	put.call(6, o[2])
	put.call(7, o[3])
	put.call(8, o[4])
	put.call(9, cw)
	put.call(10, o[5])
	put.call(11, _u(h, "num_big"))
	put.call(12, _u(h, "width"))
	put.call(13, _u(h, "height"))
	put.call(14, pl.rgba)
	put.call(15, cw * ch)
	putf.call(16, pow(0.8, _u(h, "x_qm_scale") - 2))
	putf.call(17, 1.0)
	putf.call(18, pow(0.8, _u(h, "b_qm_scale") - 2))
	var qb: Array = h.get("quant_bias", [0, 0, 0])
	var ob: Array = h.get("opsin_bias", [0, 0, 0])
	for c in 3:
		putf.call(19 + c, float(qb[c]))
		putf.call(36 + c, float(ob[c]))
	putf.call(22, _f(h, "quant_bias_numerator"))
	putf.call(23, float(_u(h, "global_scale")))
	putf.call(24, _f(h, "base_correlation_x"))
	putf.call(25, _f(h, "base_correlation_b"))
	putf.call(26, float(_u(h, "colour_factor")))
	var im: Array = h.get("inv_mat", [])
	for row in 3:
		for c in 3:
			putf.call(27 + row * 3 + c, float(im[row][c]) if row < im.size() else 0.0)
	putf.call(39, 255.0 / _f(h, "intensity_target"))
	var mats: Dictionary = h.get("mats", {})
	for t: String in mats:
		for c in 3:
			put.call(40 + int(t) * 3 + c, int(mats[t][c]))
	var io: Array = h.get("iord_ofs", [])
	for i in io.size():
		put.call(121 + i, int(io[i]))
	put.call(163, o[6])
	put.call(164, _u(h, "num_small"))
	for c in 3:
		var v := _f32(float(ob[c])) # as the extension: the bias as a 32-bit float, then its cube root
		putf.call(165 + c, signf(v) * pow(absf(v), 1.0 / 3.0))
	put.call(168, o[0])
	var has_alpha := String(h.get("alpha", "")) == "ok"
	put.call(169, pl.alpha if has_alpha else 0xffffffff)
	put.call(170, (_u(h, "width") + 3) / 4)
	return [rec, r]


## Stages `blobs` (the files' bytes; `names` their texture names) and packs them for the kernels: a dictionary of
## (bits, groups, ptables, blist, records, work, vd_params, vd_input, small_list,
## small_count, big_list, big_count, coeff_words, rgba_words, apl, atables, adata, has_dct32, alpha_groups,
## alpha_words, textures, skipped, stage_ms, pack_ms).
static func stage_blobs(blobs: Array, names: PackedStringArray, solo_groups := 96) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var n := blobs.size()
	var staged := []
	staged.resize(n)
	var task := WorkerThreadPool.add_group_task(func(i: int) -> void:
		staged[i] = stage_file(blobs[i], names[i]), n, mini(THREADS, n), false, "JxlStage files")
	WorkerThreadPool.wait_for_group_task_completion(task)
	var t1 := Time.get_ticks_usec()
	var ok := []
	var skipped := []
	for i in n:
		if (staged[i] as Dictionary).has("error"):
			skipped.append(staged[i].error)
		else:
			ok.append(staged[i])
	# 1. where every image goes (sizes only)
	var places := []
	var tot := { bits = 0, groups = 0, ptables = 0, blist = 0, records = 0, vd_input = 0, small = 0, big = 0, coeff = 0, rgba = 0, apl = 0, atables = 0, alpha = 0, adata = 0 }
	for img: Dictionary in ok:
		var h: Dictionary = img.h
		var s: Dictionary = img.s
		var vd_ofs := []
		var v: int = tot.vd_input
		for sec: String in VD_SECTIONS:
			vd_ofs.append(v)
			v += _words(s, sec)
		var pl := tot.duplicate()
		pl.vd_ofs = vd_ofs
		places.append(pl)
		tot.bits += _words(s, "bits")
		tot.groups += _words(s, "groups2") / 8
		tot.ptables += _words(s, "ptables")
		tot.blist += _words(s, "blist")
		tot.records += maxi(1, _u(h, "num_passes"))
		tot.vd_input = v
		tot.small += _words(s, "smalllist") / 2
		tot.big += _words(s, "biglist") / 2
		tot.coeff += (_u(h, "w8") * 8 * _u(h, "h8") * 8) * 3
		tot.rgba += _u(h, "width") * _u(h, "height")
		if String(h.get("alpha", "")) == "ok":
			tot.apl += _words(s, "apl") / APL_STRIDE
			tot.atables += _words(s, "atables")
			tot.alpha += ((_u(h, "width") + 3) / 4) * _u(h, "height")
			tot.adata += _words(s, "adata")
	var small_list: int = tot.vd_input
	var big_list: int = small_list + tot.small * 2
	# 2. each image's fixed-up pieces (in parallel), then appended in order
	var pieces := []
	pieces.resize(ok.size())
	var task2 := WorkerThreadPool.add_group_task(func(i: int) -> void:
		pieces[i] = _pieces(ok[i], places[i], i), ok.size(), mini(THREADS, ok.size()), false, "JxlStage pack")
	WorkerThreadPool.wait_for_group_task_completion(task2)
	var bits := PackedByteArray()
	var groups := PackedByteArray()
	var ptables := PackedByteArray()
	var blist := PackedByteArray()
	var recs := PackedByteArray()
	var params := PackedByteArray()
	var vd_main := PackedByteArray()
	var smalls := PackedByteArray()
	var bigs := PackedByteArray()
	var apl_out := PackedByteArray()
	var at_out := PackedByteArray()
	var ad_out := PackedByteArray()
	var work := []
	for i in ok.size():
		var p: Dictionary = pieces[i]
		bits.append_array(p.bits)
		groups.append_array(p.groups)
		ptables.append_array(p.ptables)
		blist.append_array(p.blist)
		recs.append_array(p.records)
		params.append_array(p.params)
		vd_main.append_array(p.vd)
		smalls.append_array(p.small)
		bigs.append_array(p.big)
		apl_out.append_array(p.apl)
		at_out.append_array(p.atables)
		ad_out.append_array(p.adata)
	for i in range(ok.size() - 1, -1, -1): # the extension gathers the workgroups last image first (ties keep that)
		work.append_array(pieces[i].work)
	bits.resize((tot.bits + 4) * 4)
	var vd_input := vd_main
	vd_input.append_array(smalls)
	vd_input.append_array(bigs)
	if apl_out.is_empty():
		apl_out.resize(APL_STRIDE * 4)
	if at_out.is_empty():
		at_out.resize(4)
	if ad_out.is_empty():
		ad_out.resize(4)
	# the heaviest groups (by bits) each get a workgroup: [record, entry, 1, 256]; they're flagged (bit 31 of their
	# entry's word 7) so the shared workgroups skip them; shared workgroups: [record, first, count, 8]
	# (both sorts stable, as the extension's: ties keep their order)
	var all := []
	for w: Array in work:
		for e in range(int(w[2]), int(w[2]) + int(w[3])):
			all.append([groups.decode_u32(e * 32 + 16), int(w[1]), e, all.size()])
	all.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0] or (a[0] == b[0] and a[3] < b[3]))
	var solo := mini(maxi(solo_groups, 0), all.size())
	var wl := PackedInt32Array()
	for k in solo:
		var e: int = all[k][2]
		groups.encode_u32(e * 32 + 28, groups.decode_u32(e * 32 + 28) | 0x80000000)
		wl.append_array(PackedInt32Array([all[k][1], e, 1, 256]))
	for k in work.size():
		work[k].append(k)
	work.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0] or (a[0] == b[0] and a[4] < b[4]))
	for w: Array in work:
		wl.append_array(PackedInt32Array([w[1], w[2], w[3], 8]))
	var textures := []
	var has_dct32 := false
	for i in ok.size():
		var h: Dictionary = ok[i].h
		var lower := String(h.name).to_lower()
		textures.append({ name = h.name, width = _u(h, "width"), height = _u(h, "height"), rgba = places[i].rgba,
			normal = lower.ends_with("_n") or lower.contains("normal"), alpha = String(h.get("alpha", "")) == "ok" })
		has_dct32 = has_dct32 or int((h.get("transforms", {}) as Dictionary).get("5", 0)) > 0
	var t2 := Time.get_ticks_usec()
	return { bits = bits, groups = groups, ptables = ptables, blist = blist, records = recs, work = wl.to_byte_array(),
		vd_params = params, vd_input = vd_input, small_list = small_list, small_count = tot.small, big_list = big_list,
		big_count = tot.big, coeff_words = tot.coeff, rgba_words = tot.rgba, apl = apl_out, atables = at_out, adata = ad_out,
		has_dct32 = has_dct32, alpha_groups = tot.apl, alpha_words = maxi(1, tot.alpha), textures = textures,
		skipped = skipped, read_ms = 0.0, stage_ms = (t1 - t0) / 1000.0, pack_ms = (t2 - t1) / 1000.0 }


## Image `i`'s pieces with its fix-ups (group entries and varblock lists point into the batch), its records, and
## its workgroups [heaviest group's bits, record, first group entry, count].
static func _pieces(img: Dictionary, pl: Dictionary, i: int) -> Dictionary:
	var h: Dictionary = img.h
	var s: Dictionary = img.s
	var gr := (s.get("groups2", PackedByteArray()) as PackedByteArray).to_int32_array()
	for g in range(0, gr.size(), 8):
		gr[g] += int(pl.bits)
		gr[g + 5] += int(pl.blist)
		gr[g + 7] = i
	var vd := PackedByteArray()
	for sec: String in VD_SECTIONS:
		vd.append_array(s.get(sec, PackedByteArray()))
	var lists := []
	for sec: String in ["smalllist", "biglist"]:
		var l := (s.get(sec, PackedByteArray()) as PackedByteArray).to_int32_array()
		for k in range(1, l.size(), 2):
			l[k] |= i << 8
		lists.append(l.to_byte_array())
	var rp := _records(h, pl)
	var rec: PackedByteArray = rp[0] # (a packed array out of an Array is a copy: resized here, returned below)
	var slots := maxi(1, _u(h, "num_passes")) * JOB_STRIDE * 4
	if rec.size() < slots:
		rec.resize(slots)
	var work := []
	var groups_n := _u(h, "num_groups")
	for p in maxi(1, _u(h, "num_passes")):
		for first in range(0, groups_n, 32):
			var cnt := mini(32, groups_n - first)
			var e0 := p * groups_n + first
			var heaviest := 0
			for e in range(e0, e0 + cnt):
				heaviest = maxi(heaviest, gr[e * 8 + 4] & 0xffffffff)
			work.append([heaviest, int(pl.records) + p, int(pl.groups) + e0, cnt])
	var apl := PackedByteArray()
	var atables := PackedByteArray()
	var adata := PackedByteArray()
	if String(h.get("alpha", "")) == "ok":
		var a := (s.get("apl", PackedByteArray()) as PackedByteArray).to_int32_array()
		var w4 := (_u(h, "width") + 3) / 4
		for r in range(0, a.size(), APL_STRIDE):
			a[r] += int(pl.bits) * 32
			a[r + 2] += int(pl.atables)
			a[r + 11] = int(pl.alpha)
			a[r + 30] = w4
			if a[r + 1] == 3:
				a[r + 31] += int(pl.adata)
		apl = a.to_byte_array()
		atables = s.get("atables", PackedByteArray())
		adata = s.get("adata", PackedByteArray())
	return { bits = s.get("bits", PackedByteArray()), groups = gr.to_byte_array(), ptables = s.get("ptables", PackedByteArray()),
		blist = s.get("blist", PackedByteArray()), records = rec, params = rp[1], vd = vd, small = lists[0], big = lists[1],
		apl = apl, atables = atables, adata = adata, work = work }
