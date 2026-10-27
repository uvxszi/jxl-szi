# Research notes

JXL-SZI came out of ten experiments (X1-X10) and a log of 39 findings (F1-F39). This page keeps the results that
matter. The IDs match the ones in the code's comments.

**Setup for every number below:**
- **PC:** Windows 11, RTX 5070 (12 GB), Ryzen 7 9800X3D, NVMe drive.
- **Engine:** Godot 4.7.2, Forward+.
- **Textures:** a sample game with 221-236 VRAM-compressed textures, mostly 1-2K anime-style character and prop maps,
  plus some photographic ones. About 270 MP in all.
- **Warm runs** have the files in the OS cache. **Cold runs** copy the build first with unbuffered I/O
  (`robocopy /J`), so none of it is cached.

## Where it ended up (F39, exported release builds)

| | Godot `.ctex` | JXL-SZI |
|---|---|---|
| Windows .exe | 470 MB | 257 MB |
| zip / 7z of the build (F36) | 200 / 159 MB | 177 / 150 MB |
| FPS, D3D12 / Vulkan | 235.6 / 233.4 | 235.6 / 233.7 |
| 1% low, D3D12 / Vulkan | 221.9 / 195.3 | 224.5 / 198.0 |
| VRAM in play, D3D12 / Vulkan | 1516 / 1420 MB | 1555 / 1405 MB |
| RAM in play, D3D12 / Vulkan | 2157 / 2609 MB | 2238 / 2579 MB |
| Peak VRAM, D3D12 / Vulkan | 1517 / 1464 MB | 1791 / 2001 MB |
| Main menu drawn, warm / cold NVMe | 1609 / 1969 ms | 1688 / 2005 ms |
| Main menu drawn, cold USB SSD (F37) | 2790 ms | 2560 ms |

- **Frame rate:** the same. The GPU samples the same BC blocks either way.
- **Steady memory:** on par.
- **Peak memory:** higher for the first ~1.5 s, while the boot set decodes.
- **Startup:** about 50-80 ms slower from a warm cache, about the same from a fast NVMe, and 0.2-0.4 s faster from
  slower drives, because there are fewer bytes to read.
- **Size:** about half on disk. The gain shrinks once compressed, because BC data compresses well and JPEG XL
  doesn't.

## Why the GPU

- **CPU decoding is too slow (F3, F5, F6).**
  - libjxl on all 16 threads takes 1.2-1.9 s for the set. Godot loads the same textures as `.ctex` in 0.19 s.
  - jxl-oxide (Rust) is about 4x slower than libjxl.
  - libjxl inside Godot, 16 files at once, still takes 0.40 s.
  - Phones would be several times worse.
- **A GPU only samples its own block formats** (BCn, ETC2, ASTC), so the image has to be decoded somewhere and then
  block-compressed anyway.
- **Encoding BC on the GPU is fast and good (F4, F19).**
  - The whole set encodes in a few milliseconds when batched.
  - Quality beats Godot's import. SSIMULACRA2 for BC1: 80.1 vs 68.3; for BC3: 85.7 vs 79.9.
- **No engine changes are needed (F2).**
  - Compute shaders run through `RenderingDevice`.
  - `Texture2DRD` makes a GPU-made texture usable by any material, sRGB included.
  - `texture_copy` can move blocks written as `R32G32_UINT` / `R32G32B32A32_UINT` into a BC texture.

## The decoder

- **It only needs a subset of JPEG XL (F10, F12).** At `-d 1 -e 7 --faster_decoding=4`, cjxl writes VarDCT, XYB, no
  EPF or Gaborish, and no patches, splines or noise. The streams are ANS with no LZ77, at most 7 histogram clusters,
  and transforms up to 32x32. A GPU decoder for these files is much smaller than a full one.
- **Entropy decoding on the GPU is bit-exact, but slow per symbol (F14, F15, F21).**
  - One GPU thread per pass group.
  - A symbol costs ~100-200 ns on a GPU thread, against ~10 ns on a CPU core.
  - The GPU wins only by running all ~4,000 pass groups at once. The longest single stream sets the floor.
- **VarDCT pass groups are always 256x256 (F29, F31).** Only modular frames can use smaller groups. Splitting each
  group's coefficients into several AC passes is legal, though, and shortens the longest stream.
- **The libjxl patch (F31):**
  - `JXL_SZI_PASSES=3,5,8` gives three passes that partition the same coefficients: the 3x3, 5x5 and 8x8 corners.
    Every pass uses its own coefficient order, so no pass codes positions it doesn't own.
  - The longest stream went from 383 k to 154 k bits, for +1.4% file size, with the same pixels.
  - All 221 textures' HF decode went from 54 to 38 ms.
  - Past 3-4 passes the GPU becomes throughput-bound (shared memory per workgroup), so 3 it is.
  - `JXL_SZI_ANS=1` keeps tiny streams on ANS; libjxl would otherwise switch them to prefix codes.
  - Stock `--progressive_ac` (F18) doesn't help: its passes are lopsided, and the last one still carries ~62% of the
    bits.
- **The whole decode matches jxl-oxide (F16, F17, F25).**
  - Steps: HF coefficients, dequant, the 14 transform types, chroma from luma, XYB to sRGB.
  - Coefficients are exact. RGBA8 is within 1, from float rounding on ≤0.007% of values.
  - The 8x8 transforms are linear, so each is one 64x64 matrix applied per block.
  - The larger varblocks get one workgroup each, because they don't align to 32-pixel tiles.
- **Alpha (F24, F26).**
  - It's modular data inside each pass group. The converter records where each group's HF data ends (the `sziA`
    box), so the alpha can be found without decoding the HF data.
  - Of 2,436 alpha groups, 1,554 hold a single value. The converter marks them and the GPU just fills them.
  - The remaining real groups are long serial chains: ~300 ns a sample on a GPU thread vs ~5 ns on a CPU core.
- **Precomputed side data (F29, F37).**
  - The CPU part of decoding (headers, histograms, the LF image, block info) is done once by the converter and
    stored as the `sziZ` box: 115 MB raw, ~27-32 MB compressed for the set.
  - The runtime only inflates it and copies the pass groups' bytes. This made staging 3x faster and removed the
    need for a native library.
  - Staging in GDScript, on 3 threads in the background, is fast enough.
- **Uploads (F32):** `buffer_update` into an empty buffer goes through the staging blocks at 35-46 GB/s with
  `rendering_device/staging_buffer/block_size_kb=8192`. `storage_buffer_create(size, data)` managed only 3-15 GB/s.

## Loading speed

- **From RAM or a fast NVMe, `.ctex` can't be beaten (F22).** Godot's threaded load of the set takes 0.06 s,
  because the data is already in the GPU's format. JPEG XL's CPU part alone (~60 ms on 8 cores) equals that, before
  the GPU's floor.
- **Best batched JPEG XL load (F30, F32):** 0.17 s for 221 textures with 3 parts, the heaviest textures first,
  against 0.16-0.18 s for Godot's sequential load.
- **In the game, decoding happens off the critical path (F35, F37).**
  - A worker thread decodes on a local RenderingDevice, its own queue on the same GPU, from the first autoload on.
  - The boot set is in ~0.8-1.1 s after the engine starts, before the main scene is ready.
  - Decoding on the main device instead made the game's frames and the decode wait on each other.
- **Godot 4.7.2's D3D12 driver can't make BC textures copy targets (F23, F33).** It adds UAV usage, which D3D12
  refuses for block formats.
  - Godot master has the fix.
  - JXL-SZI reads the blocks back and makes the textures with data, as `.ctex` loading does. This works on every
    driver and costs no frame time on a worker thread.

## Memory

- **D3D12 kept ~355 MB for one kernel (F38).** The kernel that built the transform tables used a 64-float array per
  thread. The driver reserved that per-thread memory for every thread slot of the GPU and kept it as long as the
  D3D12 device lived, and Godot's local device shares the main D3D12 device.
  - Fix: the tables are fixed math, computed once and shipped as `consts.bin`.
  - Vulkan didn't show it, because there the local device is its own `VkDevice`.
- **Textures are made on the main thread (F38).** Godot keeps one upload buffer per thread that makes textures, as
  big as that thread's largest upload ever. Making them on the worker kept ~0.4 GB more on D3D12.
- **The decoder's device is freed after 1 s idle (F38).** Detail streaming (lower mips for far objects, F35) kept
  the device and its scratch memory alive all game, to save a few MB of textures. It's now an off-by-default switch.
- **Decoding everything in one batch peaked at 6.5-7.4 GB VRAM (F34).** Fixed-size parts sharing one scratch set
  brought it to 2.3-2.8 GB at the same speed.

## Pitfalls worth remembering

- **A conditional shared-memory read miscompiled (F24).** `int v = y > 0u ? row[x] : 0;` returned 0 at x = 0 on an
  RTX 5070 with Vulkan. Reading unconditionally first fixed it.
- **CRLF shader files silently lost their `#define`s (F25).** GDScript strips CRs from its own string literals but
  `FileAccess.get_file_as_string` keeps them, so the define insertion's match failed without an error. Strip `\r`
  before matching.
- **Every `print` flushes stdout in debug builds (F35):** 7-15 ms a line when piped. Keep per-frame code print-free.
- **D3D12 copies BC data in whole 4x4 blocks (F36):** copying mips down to 1x1 failed the command list.
- **Textures made inside a readback callback crashed D3D12 (F37).**
- **Average-colour placeholders vanished under alpha scissor (F38):** textures with much transparency hit it.
  16x16 thumbnails don't.
- **`RenderingServer.call_on_render_thread` from a SceneTree script runs on the main thread later (F7),** so
  waiting on a semaphore for it deadlocks.
- **Godot's importer fixes alpha borders (F7):** it spreads colour into invisible pixels for clean mips. The
  converter has to do the same (`Image.fix_alpha_edges`).
- **"Frame drawn" and `RenderingServer.force_sync()` return before the GPU is done (F20).** Time to a readback
  instead.
- **Two compute lists never overlap in Godot's RD (F27, F32):** it puts a barrier between them. Order dispatches
  within one list.

## Tried and dropped

- **Splitting the load into equal parts (F21):** each part pays the full HF floor.
- **Moving the heaviest pass groups to the CPU (F28):** the group sizes are flat at the top.
- **Godot's separate render thread mode (F32):** worse.
- **Preallocating every part's buffers (F33):** this only moved the allocations onto the main thread.
- **D3D12's `CREATE_NOT_ZEROED` heaps (F33):** no gain.
- **A native extension (F37):** a DLL cost ~20 ms warm and ~90 ms cold, because the virus scanner checks new DLLs,
  and the side data made it unnecessary.

## Open

- **Linux builds** haven't been run yet. Android has been tested. ETC2 / EAC output was also checked by decoding it on
  the CPU (`probe_jxl_formats`): colour ~1 dB below BC, normal maps and alpha on par.
- **More benchmarks:** open-source Godot games built with and without JXL-SZI.
- **Mobile GPUs:** they often have 32 KB of shared memory or less, and Vulkan only guarantees 16 KB (F28). The alpha
  kernel already picks 16 or 8 slots from the limit; the HF kernel uses ~27 KB.
- **Only Godot 4.7.2** has been tried.
