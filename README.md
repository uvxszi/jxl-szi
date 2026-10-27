# JXL-SZI: JPEG XL textures for Godot 4, decoded on the GPU

> [!WARNING]
> **Experimental.** JXL-SZI is research code, tested with Godot 4.7.2 in one sample game.
> - **Tested:** Windows (D3D12 and Vulkan) and Android.
> - **Not tested yet:** Linux. Linux exports build, but haven't been run.
>
> Its file format and settings may change between versions. Before you ship with it, test the build on every
> platform you target, and keep a normal export to fall back on. Use it at your own risk.

**JXL-SZI is a Godot 4 addon that ships your game's textures as JPEG XL (JXL) instead of Godot's `.ctex`, and
decodes them on the GPU at runtime.** It makes an exported game about 40% smaller, at the same frame rate and
steady memory. It needs no engine changes, no GDExtension and no native code at runtime: the decoder is GDScript
plus Vulkan / D3D12 compute shaders through Godot's `RenderingDevice`.

You install it as a normal addon, add one feature tag to an export preset, and export.

In short:
- **What it is:** a GPU JPEG XL decoder and a texture exporter for Godot 4.x (Forward+ and Mobile renderers).
- **What it's for:** smaller game builds and downloads. It uses JPEG XL's visually lossless setting (distance 1.0),
  which measures below Godot's own formats against the source images.
- **How it works:** the export converts VRAM-compressed textures to JPEG XL with a patched libjxl. At runtime,
  compute shaders do the entropy decode (ANS), the VarDCT inverse transforms, the mipmaps and the block
  compression to BC1 / BC3 / BC5 / BC7 (desktop) or ETC2 / EAC (mobile).
- **Status:** experimental, MIT licensed.

## What it does

- **About 40% smaller builds:** every texture Godot imports as *VRAM Compressed* goes into the export as JPEG XL
  instead of BC / ETC2 blocks: distance 1.0 (visually lossless) for colour, 0.35 for normal maps.
- **Decoded on the GPU at startup:** a background thread uses its own RenderingDevice and does the entropy
  decode, inverse transforms, mipmaps and block compression (BC1, BC7 and BC5 by default on desktop GPUs, ETC2 / EAC
  on phones). The textures your main scene needs are done first.
- **Nothing to change in your scenes:** scenes, materials and scripts keep pointing at `res://.../texture.png`. Until
  a texture is decoded it shows a 16x16 thumbnail of itself, then fills in where it is.
- **Only where you ask:** export presets without the `jxl-szi` feature, and the editor, are untouched.

### Benchmarks

All measured in one sample game: a 3D game with 236 textures, mostly 1-2K character and prop maps. Windows 11, RTX
5070, D3D12, release builds exported from the same project.

#### Every format, sorted by build size, then FPS, then quality

2560x1440 exclusive fullscreen, vsync off, no frame cap, Ultra, MSAA 4x. Each format ran twice, 10 s of a camera
turning a full circle in the same solo trial; a range covers both runs. Quality is the PSNR of the full-size mip
level against the source images, over the same 60 textures: higher is closer to the source.

| Format | Build | FPS | 1% low | Quality | Video memory | RAM |
|---|---|---|---|---|---|---|
| JXL-SZI, BC7 everywhere, Balanced | **291 MB** | 313-326 | 207-209 | 45.0 dB | 1954 MB | 2564-2569 MB |
| JXL-SZI, BC1 / BC3 / BC5 | **291 MB** | 315 | 203-206 | 41.2 dB | 1906 MB | 2517-2520 MB |
| JXL-SZI, BC7 everywhere, Fast | **291 MB** | 312 | 204-206 | 43.9 dB | 1954-1970 MB | 2570-2580 MB |
| **JXL-SZI, BC1 / BC7 / BC5, Balanced (default)** | **291 MB** | 309-311 | 199-202 | 43.4 dB | 1906 MB | 2525-2526 MB |
| JXL-SZI, BC7 everywhere, Best | **291 MB** | 307-308 | 192-202 | 45.4 dB | 1954-1955 MB | 2576-2686 MB |
| Godot Basis Universal (UASTC) | 331 MB | 310-315 | 198-202 | 47.0 dB | 1883-1899 MB | 2465-2494 MB |
| Godot VRAM Compressed (`.ctex`) | 493 MB | 307-311 | 187-199 | 45.5 dB | **1835 MB** | **2414-2422 MB** |
| Godot VRAM Compressed, High Quality | 554 MB | 315-330 | 196-199 | **47.6 dB** | 1883-1899 MB | 2478-2497 MB |

- **Size:** every JXL-SZI setting ships the same 291 MB, because the game builds its blocks while it loads, from
  the same JPEG XL files. That's 12% smaller than Basis and 41% smaller than `.ctex`.
- **FPS:** the same for every format, 307-330. The same format moved by up to 13 FPS between its two runs, so the
  order within a size is noise.
- **Quality:** Godot's High Quality and Basis keep the most detail. JXL-SZI with BC7 everywhere is level with
  `.ctex`; the default trades 2 dB of that for BC1's memory on opaque textures.
- **Memory:** JXL-SZI uses about 70 MB more video memory and 100 MB more RAM than `.ctex` in play: its startup set
  decodes some textures this trial never loads. BC7 everywhere adds about 50 MB more.

Quality by kind of texture, in the same order (colour: 11 opaque textures; alpha: the visible pixels' colour of 29
textures with alpha; normal maps: the X and Y channels of 20):

| Format | Colour | With alpha | Normal maps |
|---|---|---|---|
| JXL-SZI, BC7 everywhere, Balanced | 50.6 dB | 45.6 dB | 41.1 dB |
| JXL-SZI, BC1 / BC3 / BC5 | 41.7 dB | 41.0 dB | 41.1 dB |
| JXL-SZI, BC7 everywhere, Fast | 50.5 dB | 43.3 dB | 41.1 dB |
| **JXL-SZI, BC1 / BC7 / BC5, Balanced (default)** | 41.7 dB | 45.6 dB | 41.1 dB |
| JXL-SZI, BC7 everywhere, Best | 50.8 dB | 46.3 dB | 41.1 dB |
| Godot Basis Universal | 55.1 dB | 48.4 dB | 40.5 dB |
| Godot VRAM Compressed (`.ctex`) | 46.6 dB | 43.4 dB | 48.0 dB |
| Godot VRAM Compressed, High Quality | 53.6 dB | 48.5 dB | 43.2 dB |

- **Where JXL-SZI's loss comes from:** decoded on its own, JPEG XL at distance 1.0 keeps colour at 52.9 dB. Most of
  the loss is the GPU block format afterwards: BC1 brings it down to 41.7 dB, BC7 only to 50.6.
- **Normal maps** are limited by JPEG XL itself (42.5 dB before BC5 at distance 0.35); see the distance table below.
  Godot's `.ctex` keeps them best because it compresses the source straight to BC5. High Quality stores them as BC7
  and Basis transcodes them from UASTC, which both lose more.
- **The alpha channel itself** comes out a little less exact with BC7 than with BC3: 47.1 dB instead of 49.0. The
  colour of those textures gains far more.

#### Loading

1920x1080 windowed, warm file cache, one or two runs:

| Format | Main menu drawn | Trial map in | Longest frame at trial start |
|---|---|---|---|
| Godot VRAM Compressed (`.ctex`) | 1.72 s | 2.07 s | 486 ms |
| JXL-SZI | 1.71-1.75 s | 2.11-2.18 s | 500 ms |
| Godot Basis Universal | 2.34-2.45 s | 3.16-3.32 s | 845-1121 ms |

- **Basis** is transcoded on the CPU while scenes load; JXL-SZI decodes on the GPU in the background.
- **From a slow drive** (a USB SSD), JXL-SZI reached the menu 0.2-0.4 s sooner than `.ctex`, because it reads fewer
  bytes.
- **The first launch** compiles the decoder's shaders (a few hundred ms; about a second more with BC7). They're
  cached for later launches.
- **A memory peak** while the startup set decodes: up to +0.5 GB of video memory and RAM for about 1.5 s. The
  decoder's device is freed after that.

#### Decode time per Blocks setting

The whole GPU decode of the same 60 textures:

| Blocks setting | Quality | Decode |
|---|---|---|
| The decoded image, before block compression | 47.3 dB | |
| BC1 / BC3 / BC5 as in 0.2.0 | 40.7 dB | 315 ms |
| BC1 / BC3 / BC5 with refinement and endpoint search | 41.2 dB | 323 ms |
| BC7 everywhere, Fast | 43.9 dB | 339 ms |
| **BC1 / BC7 / BC5, Balanced (default)** | **43.4 dB** | **348 ms** |
| BC7 everywhere, Balanced | 45.0 dB | 417 ms |
| ETC2 / EAC (phones) | 40.2 dB | 476 ms |
| BC7 everywhere, Best | 45.4 dB | 912 ms |

#### Other platforms

| Build | `.ctex` | JXL-SZI |
|---|---|---|
| Windows .exe | 493 MB | 291 MB |
| Linux x86_64 | 446 MB | 256 MB |
| Android .apk (debug-signed) | 396 MB | 204 MB |

The Linux and Android `.ctex` builds were measured a day earlier, when the Windows one was 470 MB. Zipped, the Windows build was only 11% smaller, because BC data compresses well and JPEG XL doesn't.

#### Normal maps: distance against size and quality

All 45 normal maps of the sample game, decoded by JXL-SZI and compared with their sources (X and Y channels):

| | Normal-map files | Quality (BC5) |
|---|---|---|
| JXL-SZI, distance 1.0 | 30.8 MB | 34.3 dB |
| JXL-SZI, distance 0.5 | 44.4 MB | 37.6 dB |
| **JXL-SZI, distance 0.35 (default)** | **53.1 MB** | **39.5 dB** |
| Godot Basis Universal | 54.4 MB | 38.2 dB |
| JXL-SZI, distance 0.25 | 62.0 MB | 41.2 dB |
| JXL-SZI, distance 0.15 | 76.3 MB | 43.6 dB |
| Godot VRAM Compressed (`.ctex`, BC5) | 91.2 MB | 44.0 dB |
| JXL-SZI, distance 0.05 | 110.6 MB | 47.1 dB |

Set **Converter > Normal Map Distance** to trade one for the other. The phone format (ETC2 / EAC) scores about
0.3-0.6 dB higher than BC5 at each distance.

This is the only game benchmarked so far. Benchmarks of open-source Godot games built with and without JXL-SZI are
planned.

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

1. **Copy the addon:** download `jxl-szi-<version>.zip` from
   [Releases](https://github.com/uvxszi/jxl-szi/releases) and unzip it into your project's folder, so that you get
   `addons/jxl_szi`. Or copy that folder from a clone of this repository.
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

Every setting has a working default, and each one's description is shown right above it in the dialog.

**Project > Project Settings > General**, section **Jxl Szi** (shown once the plugin is enabled). The Converter and
Boot settings apply at export; Blocks and Runtime are read by the exported game when it starts, so changing them
needs no new conversion.

| Setting | Default | What it does |
|---|---|---|
| Converter > Distance | 1.0 | How much detail cjxl may drop from colour textures (`-d`). 1.0 is visually lossless; lower is bigger and closer to the source, higher smaller and blurrier. |
| Converter > Normal Map Distance | 0.35 | The same for normal maps: see [the table](#normal-maps-distance-against-size-and-quality). |
| Converter > Effort | 7 | cjxl's `-e`. 5 and 6 make files about 5% smaller with the same colour quality, but normal maps lose about 1.5 dB. Above 7 can fail with the pass layout the decoder needs. |
| Converter > Parallel Jobs | 0 | Textures converted at once during an export. 0 is half the CPU's threads. |
| Boot > Paths | empty | Scenes, resources or folders whose textures decode from startup, in order, after the main scene's. |
| Boot > Boot Script | empty | A script with `static func jxl_boot_paths() -> Array`, for a boot set you work out in code. Each entry is a path, or an Array of paths that share a rank. |
| Blocks > Opaque Format | BC1 | BC1, or BC7 for twice the memory and far more detail. See [the table](#every-format-sorted-by-build-size-then-fps-then-quality). |
| Blocks > Alpha Format | BC7 | BC7 or BC3: the same memory; BC7 keeps the colour much closer, BC3 the alpha channel a little. |
| Blocks > Encoder Search | Balanced | How hard the BC7 encoder searches: Fast, Balanced or Best. |
| Blocks > Refinement Passes | 1 | Least-squares fitting passes for BC1 and BC7 endpoints. |
| Blocks > Single Channel Search | on | Better endpoints for BC3's alpha and BC5's normal maps. |
| Runtime > Boot Part Megapixels | 8 | Megapixels per startup batch on desktops (the decoder's scratch memory is ~16 bytes a pixel of a batch). |
| Runtime > Boot Part Megapixels Mobile | 2 | The same on phones and tablets. |
| Runtime > Staging Threads | 3 | CPU threads that unpack each file's data for the GPU. |
| Runtime > Upload Megabytes per Frame | 16 | At most this much of finished textures is made per frame. |
| Runtime > Free Device After Seconds | 1.0 | Idle time before the decoder's GPU device and scratch memory are freed. |
| Runtime > Detail by Distance | off | Lower mip levels for far-away objects. Saves a little texture memory, but keeps the decoder busy. |
| Runtime > Log | off | A line per decoded batch, like `--jxl-log`. |

Textures outside the boot set decode the moment something loads them, and show their thumbnail until then.

**Editor > Editor Settings**, with **Advanced Settings** on, section **Jxl Szi > Converter**:

| Setting | Default | What it does |
|---|---|---|
| Custom Tools Dir | empty | Leave this empty. It's only for your own builds of the converter tools: a folder holding `cjxl` and `stager`. Empty uses the bundled ones in `addons/jxl_szi/bin/<os>-<arch>`. If the folder doesn't hold both tools, the export warns and uses the bundled ones. |

**Upgrading from 0.2.0:** Boot > Script is now Boot > Boot Script (a setting named "script" is hidden in Project
Settings). The plugin moves the old value over the first time the editor opens the project.

### Switches for the exported game

Put these after `--` on the command line:

| Switch | What it does |
|---|---|
| `--jxl-log` | Prints a line per decoded batch. |
| `--jxl-off` | Shows thumbnails only. |
| `--jxl-part-mp=<n>` | Megapixels per startup batch (default 8, 2 on phones). |
| `--jxl-threads=<n>` | CPU threads for staging (default 3). |
| `--jxl-etc` | Uses ETC2 even where BC works. |
| `--jxl-opaque=bc1\|bc7` | Overrides Blocks > Opaque Format for this run. |
| `--jxl-alpha=bc3\|bc7` | Overrides Blocks > Alpha Format for this run. |
| `--jxl-bc7=0\|1\|2` | Overrides Blocks > Encoder Search (Fast, Balanced, Best) for this run. |
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
  - `.jxl` files already in the project. Godot doesn't import them as textures, so the export never sees them; see
    the FAQ.
- **Differences from Godot's own import:**
  - Every converted texture gets mipmaps, even if its import turns them off.
  - "High quality" (BC7) imports follow the Blocks settings like every other texture.
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
.github/workflows/     the release workflow
```

### Making a release

A release zip holds only `addons/jxl_szi`, with the license, the third-party notices and this README inside it.
The sources, docs and CI stay out.

1. Set `version` in `addons/jxl_szi/plugin.cfg`.
2. Add a `## <version>` section to `CHANGELOG.md`, and commit. That section becomes the release notes.
3. Tag and push the tag: `git tag v0.1.0 && git push origin v0.1.0`.

The **Release** workflow checks that the tag matches `plugin.cfg`, builds the zip and publishes it as a release.
To see the zip without publishing anything, run the workflow by hand from the Actions tab: the zip comes out as a
workflow artifact.

GitHub's own "Source code" downloads also leave out `docs/`, `tools/` and `.github/` (`export-ignore` in
`.gitattributes`).

## FAQ

- **Does Godot support JPEG XL textures?** Not on its own. Godot 4 imports PNG, JPEG, WebP and others; JXL-SZI adds
  JPEG XL as a shipping format for textures through an addon.
- **Is the decoding done on the CPU?** No. Only small per-file setup data is unpacked on CPU threads. The entropy
  decoding, inverse DCTs, colour conversion, mipmaps and BC / ETC2 encoding run in compute shaders.
- **Does it change the frame rate?** No. The GPU samples the same block formats Godot's own imports use. In the
  sample game every format ran at 307-330 FPS at 1440p with no frame cap.
- **Should I use BC7 for opaque textures?** If you can spare the memory, yes: it's the biggest quality step there is
  (colour 41.7 -> 50.6 dB in the sample game) for twice those textures' video memory. Set Blocks > Opaque Format to
  BC7; no new conversion is needed, the game encodes its blocks when it loads.
- **Does it need a custom engine build?** No. It works on stock Godot 4.7.2, including the D3D12 driver, where Godot
  4.7.2 can't copy into BC textures: the blocks are read back and uploaded instead.
- **Can other tools open the files?** Yes. They are standard JPEG XL. The extra boxes JXL-SZI adds are ignored by
  other decoders.
- **Can I use `.jxl` files I already have?** Not yet. JXL-SZI converts PNG, JPEG, WebP, TGA and BMP textures, and
  leaves `.jxl` files in a project untouched. There are two reasons:
  - Godot 4 has no JPEG XL importer, so a `.jxl` in a project isn't a texture scenes can use.
  - The GPU decoder reads only the subset of JPEG XL its own converter writes, with the converter's extra boxes. A
    `.jxl` made by another tool would need re-encoding first.

  Importing existing `.jxl` files as textures may come in a later version.
- **How is it different from Basis Universal / KTX2?** Basis ships its own intermediate format, which Godot
  transcodes into GPU blocks on the CPU at load. JXL-SZI ships standard JPEG XL and does the full image decode on
  the GPU. In the sample game, JXL-SZI's build was 12% smaller and loaded about 0.6 s faster at the same FPS, while Basis
  kept more detail. See [the benchmarks](#every-format-sorted-by-build-size-then-fps-then-quality).

## License

[MIT](LICENSE). The bundled converter tools contain third-party code under their own licenses: see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
