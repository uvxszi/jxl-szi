@tool
extends RefCounted
## Every JXL-SZI setting in one place: name, default, editor hint and the description shown above it in Project
## Settings / Editor Settings (help_inspector.gd). The editor plugin registers them from here; the export and the
## runtime read them with value(), so a setting missing from project.godot gets its default.

static var PROJECT := [
	{ name = "jxl_szi/converter/distance", default = 1.0, type = TYPE_FLOAT, hint = PROPERTY_HINT_RANGE, hint_string = "0.05,5.0,0.05",
		description = "How much detail the converter may drop from colour textures (cjxl's -d). 1.0 is JPEG XL's \"visually lossless\" setting. Lower keeps more detail in bigger files; higher makes smaller, blurrier files. Textures convert again on the next export when it changes." },
	{ name = "jxl_szi/converter/normal_map_distance", default = 0.35, type = TYPE_FLOAT, hint = PROPERTY_HINT_RANGE, hint_string = "0.05,5.0,0.05",
		description = "The same for normal maps, whose errors show up in lighting. At 0.35 they keep more detail than Basis Universal's at the same size; 0.15 is about as close to the source as Godot's own BC5, at 84% of its size; 1.0 is the smallest and the least accurate." },
	{ name = "jxl_szi/converter/effort", default = 7, type = TYPE_INT, hint = PROPERTY_HINT_RANGE, hint_string = "3,7,1",
		description = "How hard the encoder works (cjxl's -e). 7 gives normal maps the most detail. 5 and 6 make files about 5% smaller with the same colour quality, but normal maps lose about 1.5 dB. Above 7 isn't offered: it can fail with the pass layout the GPU decoder needs." },
	{ name = "jxl_szi/converter/parallel_jobs", default = 0, type = TYPE_INT, hint = PROPERTY_HINT_RANGE, hint_string = "0,64,1",
		description = "How many textures convert at once during an export. 0 uses half the CPU's threads (each conversion uses two)." },
	{ name = "jxl_szi/boot/paths", default = PackedStringArray(), type = TYPE_PACKED_STRING_ARRAY, hint = PROPERTY_HINT_TYPE_STRING, hint_string = "4/13:", # an Array of TYPE_STRING (4) with PROPERTY_HINT_FILE (13)
		description = "Scenes, resources or folders whose textures decode from the moment the game starts, in this order, after the main scene's own. Anything else decodes when something loads it, showing a 16x16 thumbnail until then." },
	{ name = "jxl_szi/boot/boot_script", default = "", type = TYPE_STRING, hint = PROPERTY_HINT_FILE, hint_string = "*.gd",
		description = "A script with `static func jxl_boot_paths() -> Array`, for a startup list worked out in code (for example every character and every map). Each entry is a path, or an Array of paths that share a place in the order. It's called at export time, after Boot > Paths." },
	{ name = "jxl_szi/blocks/opaque_format", default = 0, type = TYPE_INT, hint = PROPERTY_HINT_ENUM, hint_string = "BC1,BC7",
		description = "The GPU format for textures without alpha on desktop GPUs. BC1 uses the same memory as Godot's own import. BC7 uses twice the memory for these textures, but keeps far more of the decoded image: about 50 dB instead of 42 against the source in the sample game. Phones always use ETC2. Takes effect at runtime: no new conversion." },
	{ name = "jxl_szi/blocks/alpha_format", default = 1, type = TYPE_INT, hint = PROPERTY_HINT_ENUM, hint_string = "BC3,BC7",
		description = "The GPU format for textures with alpha on desktop GPUs. Both use the same memory. BC7 keeps the colour much closer to the source (45.6 dB instead of 41 in the sample game); BC3 keeps the alpha channel itself a little more exact (49 dB instead of 47.1). Takes effect at runtime: no new conversion." },
	{ name = "jxl_szi/blocks/encoder_search", default = 1, type = TYPE_INT, hint = PROPERTY_HINT_ENUM, hint_string = "Fast,Balanced,Best",
		description = "How hard the BC7 encoder searches, on the GPU while textures load. Fast tries one block mode; Balanced also tries two-subset blocks and separate alpha (much better on alpha textures; with BC7 everywhere, about a third more decode time than BC1 / BC3); Best tries more partitions and modes (two to three times Balanced's time, for about +0.4 dB). Only matters where BC7 is used." },
	{ name = "jxl_szi/blocks/refinement_passes", default = 1, type = TYPE_INT, hint = PROPERTY_HINT_RANGE, hint_string = "0,3,1",
		description = "Least-squares passes that fit BC1 and BC7 endpoints to the chosen indices after the first guess. 1 gains a little at almost no cost; more passes made no measurable difference in the sample game." },
	{ name = "jxl_szi/blocks/single_channel_search", default = true, type = TYPE_BOOL,
		description = "Search better endpoints for single-channel blocks (BC3's alpha, BC5's normal maps) instead of taking each block's range, including the mode with exact 0 and 1 values. +2 dB on alpha and +0.5 dB on normal maps for a few percent of decode time." },
	{ name = "jxl_szi/runtime/boot_part_megapixels", default = 8, type = TYPE_INT, hint = PROPERTY_HINT_RANGE, hint_string = "1,64,1",
		description = "How many megapixels of textures decode in one batch at startup on desktops. The decoder's scratch memory is about 16 bytes a pixel of one batch, so 8 MP is ~130 MB while decoding. Bigger batches finish a little sooner and peak higher." },
	{ name = "jxl_szi/runtime/boot_part_megapixels_mobile", default = 2, type = TYPE_INT, hint = PROPERTY_HINT_RANGE, hint_string = "1,64,1",
		description = "The same on phones and tablets (the `mobile` feature), where memory is tighter." },
	{ name = "jxl_szi/runtime/staging_threads", default = 3, type = TYPE_INT, hint = PROPERTY_HINT_RANGE, hint_string = "1,16,1",
		description = "CPU threads that unpack each file's data for the GPU. They run at normal priority, so the game's own loading comes first." },
	{ name = "jxl_szi/runtime/upload_megabytes_per_frame", default = 16, type = TYPE_INT, hint = PROPERTY_HINT_RANGE, hint_string = "1,256,1",
		description = "At most this many MB of finished textures are made per frame on the main thread, so a big batch doesn't stall a frame. A texture a scene asks for while it loads is made at once regardless." },
	{ name = "jxl_szi/runtime/free_device_after_seconds", default = 1.0, type = TYPE_FLOAT, hint = PROPERTY_HINT_RANGE, hint_string = "0,60,0.1",
		description = "With nothing left to decode for this long, the decoder's GPU device and scratch memory are freed. The next texture that needs decoding makes them again (a few tens of ms)." },
	{ name = "jxl_szi/runtime/detail_by_distance", default = false, type = TYPE_BOOL,
		description = "Lower mip levels for objects far from the camera, decoded again as they come closer. It saves a few MB of texture memory but keeps the decoder's device alive while the camera moves, which costs far more. Characters and held items always stay full." },
	{ name = "jxl_szi/runtime/log", default = false, type = TYPE_BOOL,
		description = "Print a line per decoded batch and a summary when the startup set is in. The same as the --jxl-log switch." },
]

static var EDITOR := [
	{ name = "jxl_szi/converter/custom_tools_dir", default = "", type = TYPE_STRING, hint = PROPERTY_HINT_GLOBAL_DIR, hint_string = "",
		description = "Leave this empty to use the converter tools that come with the addon (addons/jxl_szi/bin/<os>-<arch>). Set it only to use your own builds: a folder holding both cjxl and stager. A folder without them is ignored with a warning." },
]


## A project setting's value, or its default when the project doesn't set it.
static func value(name: String) -> Variant:
	for s: Dictionary in PROJECT:
		if s.name == name:
			return ProjectSettings.get_setting(name, s.default)
	return ProjectSettings.get_setting(name)


## Settings renamed since an earlier version: old name -> new name (the plugin moves a project's values over).
const RENAMED := {
	# a setting whose last part is "script" is hidden in Project Settings (it clashes with every object's own script)
	"jxl_szi/boot/script": "jxl_szi/boot/boot_script",
}


## The description of a setting (project or editor), by full name; empty if it isn't one of JXL-SZI's.
static func description(name: String) -> String:
	for s: Dictionary in PROJECT + EDITOR:
		if s.name == name:
			return s.description
	return ""
