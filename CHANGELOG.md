# Changelog

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
