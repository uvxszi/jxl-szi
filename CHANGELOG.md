# Changelog

## 0.3.0 (2026-10-27)

- **BC7 on the GPU:** a new BC7 encoder (modes 6, 1, 3, 4, 5 and 7). Textures with alpha now use BC7 by default:
  the same memory as BC3, and their colour went from 41.0 to 45.6 dB against the source in the sample game. Opaque
  textures can use it too (Blocks > Opaque Format = BC7): 41.7 -> 50.6 dB for twice their memory.
- **Better BC1 / BC4:** endpoint refinement (it was off) and an endpoint search for single channels with BC4's
  6-value mode: +2 dB on BC3's alpha, +0.5 dB on normal maps.
- **Settings:** 18 project settings in Converter, Boot, Blocks and Runtime, each with its description shown above it
  in Project Settings and Editor Settings. New: converter effort and parallel jobs, the block formats and encoder
  effort, and the runtime's batch size, threads, upload budget, idle time, detail by distance and logging (they
  used to be command-line switches only). Switches `--jxl-opaque`, `--jxl-alpha` and `--jxl-bc7` override the
  block settings for a run.
- **Boot > Script is now Boot > Boot Script:** a setting named "script" is hidden in Project Settings. The plugin
  moves an old value over.
- **Research:** where the quality goes (JPEG XL itself keeps colour at 52.9 dB; most of the loss was BC1), and what
  each block setting costs, in docs/RESEARCH.md.

## 0.2.0 (2026-10-26)

- **Normal maps get their own distance:** Project Settings > Jxl Szi > Converter > Normal Map Distance, default
  0.35 (colour stays at 1.0). Normal maps keep much more detail (34.3 -> 39.5 dB over the sample game's 45, now
  ahead of Basis Universal at the same size), for a ~8% bigger build. They convert again on the first export.
- **Benchmarks:** a comparison with `.ctex` and Basis Universal, and a normal-map distance table, in the README.

## 0.1.0 (2026-10-26)

The first packaged version. It's experimental.

- **Export:**
  - Presets with the custom feature `jxl-szi` ship VRAM-compressed 8-bit textures as JPEG XL.
  - Conversion is cached by content and import options, with no Python needed.
  - Each texture gets a 16x16 thumbnail.
  - The boot set can come from the main scene, a list, or a script.
- **Runtime:**
  - The GPU decoder works on a local RenderingDevice in the background.
  - It picks BC or ETC2 / EAC by what the GPU samples.
  - Thumbnails show until a texture is in.
  - The decoder's memory is freed once it's idle.
- **Bundled tools:** cjxl (libjxl 0.12.0, patched) and the stager, for Windows x86_64. Build scripts for Linux and
  macOS are included.
