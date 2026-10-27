# JXL-SZI: JPEG XL textures for Godot 4, decoded on the GPU

> [!WARNING]
> **Experimental.** JXL-SZI is research code, tested with Godot 4.7.2 in one sample game.
> - **Tested:** Windows (D3D12 and Vulkan) and Android.
> - **Not tested yet:** Linux. Linux exports build, but haven't been run.
>
> Its file format and settings may change between versions. Before you ship with it, test the build on every
> platform you target, and keep a normal export to fall back on. Use it at your own risk.

**JXL-SZI is a Godot 4 addon that ships your game's textures as JPEG XL (JXL) instead of Godot's `.ctex`, and
decodes them on the GPU at runtime.** It roughly halves the size of an exported game, at the same frame rate and
steady memory. It needs no engine changes, no GDExtension and no native code at runtime: the decoder is GDScript
plus Vulkan / D3D12 compute shaders through Godot's `RenderingDevice`.

You install it as a normal addon, add one feature tag to an export preset, and export.

In short:
- **What it is:** a GPU JPEG XL decoder and a texture exporter for Godot 4.x (Forward+ and Mobile renderers).
- **What it's for:** smaller game builds and downloads, with texture compression that stays visually lossless.
- **How it works:** the export converts VRAM-compressed textures to JPEG XL with a patched libjxl. At runtime,
  compute shaders do the entropy decode (ANS), the VarDCT inverse transforms, the mipmaps and the block
  compression to BC1 / BC3 / BC5 (desktop) or ETC2 / EAC (mobile).
- **Status:** experimental, MIT licensed.

## What it does

- **About half the size:** every texture Godot imports as *VRAM Compressed* goes into the export as JPEG XL
  (visually lossless, distance 1.0) instead of BC / ETC2 blocks.
- **Decoded on the GPU at startup:** a background thread uses its own RenderingDevice and does the entropy
  decode, inverse transforms, mipmaps and block compression (BC1 / BC3 / BC5 on desktop GPUs, ETC2 / EAC on phones).
  The textures your main scene needs are done first.
- **Nothing to change in your scenes:** scenes, materials and scripts keep pointing at `res://.../texture.png`. Until
  a texture is decoded it shows a 16x16 thumbnail of itself, then fills in where it is.
- **Only where you ask:** export presets without the `jxl-szi` feature, and the editor, are untouched.

### Measured in a sample game

A 3D game with 236 textures, mostly 1-2K character and prop maps. Windows 11, RTX 5070, release builds, the same game
exported with and without the `jxl-szi` feature:

| | `.ctex` | JXL-SZI |
|---|---|---|
| Windows .exe | 470 MB | 257 MB |
| Linux x86_64 | 446 MB | 233 MB |
| Android .apk (debug-signed) | 396 MB | 180 MB |
| FPS, D3D12 / Vulkan | 235.6 / 233.4 | 235.6 / 233.7 |
| VRAM in play, D3D12 / Vulkan | 1516 / 1420 MB | 1555 / 1405 MB |
| RAM in play, D3D12 / Vulkan | 2157 / 2609 MB | 2238 / 2579 MB |
| Main menu drawn (warm cache / cold NVMe) | 1.61 / 1.97 s | 1.69 / 2.01 s |

- **From a slow drive** (a USB SSD), the JPEG XL build reached the menu 0.2-0.4 s sooner, because it reads half as
  many bytes.
- **The costs:**
  - A memory peak while the startup set decodes: up to +0.5 GB of VRAM and RAM for about 1.5 s. The decoder's device
    is freed after that.
  - Thumbnails show for a moment at startup.
- **Compressed downloads gain less:** zipped, the build was only 11% smaller, because BC data compresses well and
  JPEG XL doesn't.

This is the only benchmark so far. Benchmarks of open-source Godot games built with and without JXL-SZI are planned.

How it got here, and what was measured on the way: [docs/RESEARCH.md](docs/RESEARCH.md).

## Requirements

- **Godot 4.x** with a RenderingDevice renderer: **Forward+** or **Mobile**. It was made and tested with Godot
  4.7.2. It uses only standard 4.x APIs, but older versions haven't been tried.
- **Not the Compatibility renderer:** it has no RenderingDevice, so a JXL-SZI export shows thumbnails only. The
  export warns about this.
- **Exporting:** the editor runs two converter programs.
  - **Windows x86_64:** they come with the addon (`addons/jxl_szi/bin/windows-x86_64`, about 8 MB, no other
    installs needed).
  - **Linux and macOS:** build them once, as described in [tools/BUILDING.md](tools/BUILDING.md).
- **Tested so far:**
  - Windows, on D3D12 and Vulkan.
  - Android.
  - The phone format (ETC2 / EAC) was also checked against the source images by decoding it on the CPU: colour
    about 1 dB below BC, normal maps and alpha on par.
  - **Not yet:** Linux. The Linux export builds, but hasn't been run.

## Install

1. **Copy the addon:** put the `addons/jxl_szi` folder into your project's `addons/` folder.
2. **Enable it:** in **Project > Project Settings > Plugins**, enable **JXL-SZI**. This adds the autoload `JxlSzi`
   and keeps it first in the autoload list, so it's ready before anything else loads a texture.
3. **Add the export feature:** in **Project > Export**, pick the preset to ship as JPEG XL. On its **Features**
   tab, type `jxl-szi` into **Custom**.
   - The feature changes only how textures are packed. Keep the preset's app name, package name and everything
     else as they are.
   - To export both kinds, duplicate the preset and give the copy its own export path.
4. **Export.** The first export converts every VRAM-compressed texture; the 236 above took 50 s. Later exports
   convert only changed textures.
5. **Ignore the cache:** add `.jxl_cache/` to your `.gitignore`. That folder holds the converted textures.

There's nothing to set up beyond that. The settings below are optional.

### Checking it works

Run the exported game from a terminal with `-- --jxl-log`. It prints lines like these:

```
JXL-SZI ready: 236 textures, 171 to decode from the start, in 22 ms
JXL-SZI boot set in at 1635 ms: {...}
```

The export also prints `JXL-SZI export: 236 textures as JPEG XL (...)`.

## Settings

The addon has three project settings and one editor setting, and all of them have working defaults.

**Project > Project Settings > General**, section **Jxl Szi** (shown once the plugin is enabled):

| Setting | Default | What it does |
|---|---|---|
| Converter > Distance | 1.0 | cjxl's `-d`. 1.0 is visually lossless; higher is smaller and blurrier. |
| Boot > Paths | empty | Scenes, resources or folders whose textures decode from startup, in order, after the main scene's. |
| Boot > Script | empty | A script with `static func jxl_boot_paths() -> Array`, for a boot set you work out in code. Each entry is a path, or an Array of paths that share a rank. |

Textures outside the boot set decode the moment something loads them, and show their thumbnail until then.

**Editor > Editor Settings**, with **Advanced Settings** on, section **Jxl Szi > Converter**:

| Setting | Default | What it does |
|---|---|---|
| Custom Tools Dir | empty | Leave this empty. It's only for your own builds of the converter tools: a folder holding `cjxl` and `stager`. Empty uses the bundled ones in `addons/jxl_szi/bin/<os>-<arch>`. If the folder doesn't hold both tools, the export warns and uses the bundled ones. |

### Switches for the exported game

Put these after `--` on the command line:

| Switch | What it does |
|---|---|
| `--jxl-log` | Prints a line per decoded batch. |
| `--jxl-off` | Shows thumbnails only. |
| `--jxl-part-mp=<n>` | Megapixels per startup batch (default 8, 2 on phones). |
| `--jxl-threads=<n>` | CPU threads for staging (default 3). |
| `--jxl-etc` | Uses ETC2 even where BC works. |
| `--jxl-detail` | Lower mip levels for far-away objects (off by default). |

## What it converts, and what it doesn't

- **Converted:**
  - 8-bit images (PNG, JPEG, WebP, TGA, BMP) imported as **VRAM Compressed**. That includes textures Godot switched
    to VRAM because they're used in 3D.
  - These import options are applied: normal map, size limit, invert Y for normal maps, premultiplied alpha, fix alpha
    border.
- **Left as they are:**
  - Lossless, Lossy, Basis Universal and VRAM Uncompressed textures.
  - HDR images.
  - Anything with a `.gdignore` on the way.
- **Differences from Godot's own import:**
  - Every converted texture gets mipmaps, even if its import turns them off.
  - "High quality" (BC7) imports become BC1 / BC3 like the rest.
  - Godot's roughness-from-normal-map option isn't applied.
- **In code:** scripts see a `Texture2DRD` where they used to see a `CompressedTexture2D`.

## Troubleshooting

- **"cjxl is missing" during export:** you're not on Windows x86_64, or the `bin` folder didn't get copied. Build the
  tools ([tools/BUILDING.md](tools/BUILDING.md)), or set **Custom Tools Dir** to the folder they're in.
- **"Custom Tools Dir ... has no cjxl and stager in it":** the setting points somewhere else, for example this
  repository's `tools/` folder, which holds the tools' sources. Clear it.
- **A texture stays blurry:** it isn't loaded by path, or its conversion failed. The export warns
  `... could not be converted; it stays .ctex` in that case, and that texture ships as usual.
- **"the JxlSzi autoload is missing":** disable and enable the plugin.

## How it works

See [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md).

## Repository layout

```
addons/jxl_szi/        the addon: copy this folder into a project
  plugin.gd            registers the export and the settings, keeps the autoload first
  export_plugin.gd     converts and packs the textures for presets with the `jxl-szi` feature
  runtime/             the autoload (jxl_stream.gd), CPU staging (jxl_stage.gd), the GPU decoder (gpu/)
  bin/<os>-<arch>/     the converter tools (cjxl, stager); never exported
tools/                 sources of the converter tools: the libjxl patch, the stager (Rust), BUILDING.md
licenses/              licenses of everything compiled into the bundled tools
docs/                  how it works, and the research behind it
```

## FAQ

- **Does Godot support JPEG XL textures?** Not on its own. Godot 4 imports PNG, JPEG, WebP and others; JXL-SZI adds
  JPEG XL as a shipping format for textures through an addon.
- **Is the decoding done on the CPU?** No. Only small per-file setup data is unpacked on CPU threads. The entropy
  decoding, inverse DCTs, colour conversion, mipmaps and BC / ETC2 encoding run in compute shaders.
- **Does it change the frame rate?** No. The GPU samples the same BC / ETC2 block formats as with `.ctex`.
- **Does it need a custom engine build?** No. It works on stock Godot 4.7.2, including the D3D12 driver, where Godot
  4.7.2 can't copy into BC textures: the blocks are read back and uploaded instead.
- **Can other tools open the files?** Yes. They are standard JPEG XL. The extra boxes JXL-SZI adds are ignored by
  other decoders.
- **How is it different from Basis Universal / KTX2?** Basis ships its own intermediate format, built to transcode
  fast into GPU blocks. JXL-SZI ships standard JPEG XL and does the full image decode on the GPU. The two haven't
  been benchmarked against each other yet.

## License

[MIT](LICENSE). The bundled converter tools contain third-party code under their own licenses: see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
