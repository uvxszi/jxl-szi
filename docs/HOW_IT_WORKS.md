# How JXL-SZI works

## At export (`addons/jxl_szi/export_plugin.gd`)

This runs only for presets with the custom feature `jxl-szi`.

1. **Find the textures:** every image whose `.import` says VRAM Compressed (`compress/mode=2`) and is 8-bit.
2. **Convert the ones not cached yet** (`res://.jxl_cache/`). The cache key is the image's content plus the import
   options that change pixels.
   - `cjxl` (patched, see [tools/BUILDING.md](../tools/BUILDING.md)) encodes it at distance 1.0, with three AC passes
     and ANS only.
   - `stager --annotate` (`JXL_SZI_SIDE=z`) decodes the file once and appends two boxes:
     - `sziA` (files with alpha): where each pass group's data ends, and which 256x256 alpha groups hold a single
       value.
     - `sziZ`: the "staged job", everything the GPU kernels need besides the bitstream itself: headers, entropy
       tables, the LF (1:8) image, block types and quantisation fields, as one zlib stream that Godot's own
       `decompress` can read.

   Up to half the CPU's cores run at once.
3. **Pack:**
   - Each texture goes in as `res://addons/jxl_szi/data/<name>.jxl`, and its `.ctex` is left out.
   - `data/manifest.json` lists every texture: its path and UID, size, normal-map flag, a 16x16 RGBA thumbnail and
     average colour, and its boot rank.
   - The boot set is the main scene's dependencies, then `jxl_szi/boot/paths`, then what `jxl_szi/boot/script`
     returns.
   - The shaders and the transforms' constant tables (`consts.bin`) go in too.

## At runtime (`addons/jxl_szi/runtime/jxl_stream.gd`, the autoload `JxlSzi`)

1. **Startup, in `_init`:**
   - With no manifest (the editor, other exports) it stops here.
   - It makes a 16x16 thumbnail texture for each texture and points each UID at the image's path.
   - It registers a `ResourceFormatLoader` ahead of Godot's. Loading `res://.../albedo.png` (by path or UID) now
     returns a `Texture2DRD` that shows the thumbnail. Scenes hold that same object for good.
   - It starts a worker thread on the boot set, in parts of 8 megapixels (2 on phones).
2. **The worker:**
   - It makes a local RenderingDevice: a second device on the same GPU, with its own queue, so nothing waits on the
     game's frames.
   - For each part:
     - Read the files and stage them on CPU threads (`jxl_stage.gd`): inflate `sziZ`, copy each pass group's bytes
       out of the codestream, pack one batch.
     - Upload the batch and run the kernels (`gpu/decoder.gd`):
       - `alpha_decode`: modular alpha groups.
       - `hf_decode6`: the AC coefficients, ANS decoded, one workgroup per pass group; the heaviest groups get their
         own workgroup.
       - `vd8` / `vdl2`: inverse transforms for 8x8 and larger blocks, then XYB to RGBA8.
       - `mip_buf`: the mip chain.
       - `blocks`: BC1 / BC3 / BC5 blocks, or ETC2 RGB8 / RGBA8 and EAC RG11 where the GPU can't sample BC.
     - Read the blocks back.
   - After a second with nothing to do, the device and every scratch buffer are freed.
3. **The main thread:**
   - Each frame it makes textures from the finished blocks (at most 16 MB of uploads a frame) and swaps them into the
     `Texture2DRD`s. A texture asked for while the main thread loads a scene is swapped in at once.
   - A texture outside the boot set is queued when something loads it.
4. **Kernel cache:** compiled kernels are cached in `user://jxl_szi_kernels/` per GPU, driver and engine build.
   The first launch compiles them, which takes a few hundred ms.

## Why it's built this way

- **No native code:** the staging that a native library first did in Rust is precomputed by the converter
  (`sziZ`), so the runtime only inflates and copies. That's fast enough in GDScript on three threads.
- **A local device:** decoding on Godot's main RenderingDevice made the decode wait on the game's frames, and vice
  versa.
- **Blocks read back, textures made on the main thread:** Godot keeps an upload buffer per thread that makes
  textures, as large as its largest upload ever. Making them on the worker kept ~0.4 GB more memory on D3D12.
- **`consts.bin` precomputed:** making those tables on the GPU made the D3D12 driver reserve ~350 MB of per-thread
  memory for that kernel, which it kept as long as the device lived.
- **Thumbnails, not flat colours:** a flat average made textures with a lot of transparency (a shirt over a body)
  vanish under alpha scissor until they decoded.

The measurements behind these choices are in [RESEARCH.md](RESEARCH.md).
