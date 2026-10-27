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

### Measured in a sample game

A 3D game with 236 textures, mostly 1-2K character and prop maps. Windows 11, RTX 5070, release builds, the same game
exported with and without the `jxl-szi` feature:

| | `.ctex` | JXL-SZI |
|---|---|---|
| Windows .exe | 470 MB | 291 MB |
| Linux x86_64 | 446 MB | 256 MB |
| Android .apk (debug-signed) | 396 MB | 204 MB |
| FPS, D3D12 / Vulkan | 235.6 / 233.4 | 235.6 / 233.7 |
| VRAM in play, D3D12 / Vulkan | 1516 / 1420 MB | 1555 / 1405 MB |
| RAM in play, D3D12 / Vulkan | 2157 / 2609 MB | 2238 / 2579 MB |
| Main menu drawn (warm cache / cold NVMe) | 1.61 / 1.97 s | 1.69 / 2.01 s |

The sizes are 0.2.0's (normal maps at distance 0.35). The other rows were measured with 0.1.0 (normal maps at
1.0); the textures decode the same way, so they shouldn't change much.

- **From a slow drive** (a USB SSD), the JPEG XL build reached the menu 0.2-0.4 s sooner, because it reads fewer
  bytes.
- **The costs:**
  - A memory peak while the startup set decodes: up to +0.5 GB of VRAM and RAM for about 1.5 s. The decoder's device
    is freed after that.
  - Thumbnails show for a moment at startup.
  - The textures are further from the source images than `.ctex` (see the comparison below).
- **Compressed downloads gain less:** zipped, the build was only 11% smaller, because BC data compresses well and
  JPEG XL doesn't.

### Compared with `.ctex` and Basis Universal

The same sample game, exported three ways from the same project: Godot's default VRAM Compressed textures (`.ctex`),
Godot's **Basis Universal** import mode (its defaults: UASTC level 0, no RDO), and JXL-SZI. Windows, D3D12, one run
each. JXL-SZI's size and quality are 0.3.0's defaults (BC1 for opaque textures, BC7 for textures with alpha, normal
maps at distance 0.35); its loading, FPS and memory were measured with 0.1.0 (normal maps at 1.0, BC3 for alpha).

| | `.ctex` | Basis Universal | JXL-SZI |
|---|---|---|---|
| Windows .exe | 493 MB | 331 MB | **291 MB** |
| Main menu drawn (warm cache) | 1.72 s | 2.34-2.45 s | 1.75 s |
| Trial map in | 2.07 s | 3.16-3.32 s | 2.11 s |
| Longest frame at trial start | 486 ms | 845-1121 ms | 500 ms |
| FPS / 1% low | 236.8 / 228.7 | 236.8 / 227.2 | 236.4 / 215.3 |
| Peak VRAM / RAM (Windows' counters) | 1548 / 2176 MB | 1533 / 2181 MB | 1812 / 2419 MB |
| Quality, average of 60 textures | 45.5 dB | **47.0 dB** | 43.4 dB (45.0 with BC7 for opaque too; ETC2: 40.2) |
| - colour (11) | 46.6 dB | 55.1 dB | 41.7 dB (BC1), 50.6 dB (BC7) |
| - with alpha (29) | 43.4 dB | 48.4 dB | 45.6 dB |
| - normal maps (20) | 48.0 dB | 40.5 dB | 41.1 dB |

Quality is the PSNR of the full-size mip level against the source image: higher is closer. For textures with alpha
it's the visible pixels' colour, and for normal maps the X and Y channels.

- **Size:** JXL-SZI makes the smallest build: 12% smaller than Basis, 41% smaller than `.ctex`.
- **Loading:** Basis is transcoded on the CPU while scenes load, so it reached the menu about 0.6 s later and froze
  about twice as long when the trial started. JXL-SZI decodes on the GPU in the background and loads like `.ctex`.
- **Frame rate:** the same for all three. JXL-SZI's lower 1% low is within run-to-run noise.
- **Memory:** in play it's about equal. JXL-SZI's peaks come from the startup decode, for about 1.5 s.
- **Quality:** decoded on its own, JPEG XL at distance 1.0 keeps colour at 52.9 dB against the source. Most of the
  loss comes from the GPU block format afterwards: BC1 brings colour down to 41.7 dB, BC7 only to 50.6.
  - **Textures with alpha** use BC7 by default: the same memory as BC3, and 45.6 dB instead of 41.0.
  - **Opaque textures** stay on BC1 by default, which keeps Godot's own texture memory. Setting **Blocks > Opaque
    Format** to BC7 brings the average to 45.0 dB, level with `.ctex`, for twice those textures' memory (+33 MB in
    this game).
  - **Normal maps** get a lower distance (0.35), which puts them level with Basis here and ahead of it over all 45 of
    the game's normal maps.
  - **Basis** scores highest on colour because Godot transcodes it to BC7 on desktops.

#### Block formats: quality and cost

The same 60 textures, decoded by JXL-SZI with each setting and compared with their sources. The decode time is the
whole GPU decode of the 60 textures, on an RTX 5070.

| Blocks setting | Colour (11) | With alpha (29) | Normal maps (20) | All 60 | Decode |
|---|---|---|---|---|---|
| The decoded image, before block compression | 52.9 dB | 48.6 dB | 42.5 dB | 47.3 dB | |
| BC1 / BC3 / BC5 as in 0.2.0 | 41.5 dB | 40.4 dB | 40.6 dB | 40.7 dB | 315 ms |
| BC1 / BC3 / BC5 with refinement and endpoint search | 41.7 dB | 41.0 dB | 41.1 dB | 41.2 dB | 323 ms |
| **BC1, BC7 for alpha, Balanced (default)** | **41.7 dB** | **45.6 dB** | **41.1 dB** | **43.4 dB** | **348 ms** |
| BC7 everywhere, Fast | 50.5 dB | 43.3 dB | 41.1 dB | 43.9 dB | 339 ms |
| BC7 everywhere, Balanced | 50.6 dB | 45.6 dB | 41.1 dB | 45.0 dB | 417 ms |
| BC7 everywhere, Best | 50.8 dB | 46.3 dB | 41.1 dB | 45.4 dB | 912 ms |
| ETC2 / EAC (phones) | 40.3 dB | 39.3 dB | 41.3 dB | 40.2 dB | 476 ms |

- **The alpha channel itself** comes out a little less exact with BC7 than with BC3: 47.1 dB instead of 49.0. The
  colour of those textures gains far more.
- **Build size:** the same for every Blocks setting (291 MB here): the game builds its blocks while it loads, from
  the same JPEG XL files.

In play, the same sample game on Windows / D3D12, a 30 s camera sweep per run, two runs each (ranges are both runs):

| | FPS | 1% low | GPU time per frame | Video memory | RAM | Build |
|---|---|---|---|---|---|---|
| `.ctex` (reference) | 236.8 | 229.8 | 1.94 ms | 1485 MB | 2125 MB | 493 MB |
| BC1 / BC3 / BC5 (0.2.0's formats) | 236.7-237.0 | 230.0-230.8 | 1.94-1.95 ms | 1555 MB | 2207-2224 MB | 291 MB |
| **BC1, BC7 for alpha (default)** | **235.9-236.6** | **207.6-224.5** | **2.02-2.15 ms** | **1555 MB** | **2216-2221 MB** | **291 MB** |
| BC7 everywhere | 236.7-236.8 | 226.4-228.7 | 2.11-2.13 ms | 1603-1605 MB | 2264-2278 MB | 291 MB |

- **Frame rate:** the same for all of them. The window can't show more than the 240 Hz screen's ~237 FPS.
- **GPU time:** BC7 costs about 0.1-0.2 ms more GPU time per frame (5-10%) in this game, which only matters for a
  GPU-bound game. The default's lower 1% low came from one run (the other was 224.5) and isn't a BC7 effect: the
  BC7-everywhere runs kept theirs.
- **Memory:** BC7 for alpha uses the same memory as BC3. BC7 everywhere adds about 50 MB of video memory and 50 MB of
  RAM here. The JPEG XL builds use about 70 MB more video memory than `.ctex` in play: the startup set decodes a few
  textures that this trial never loads.

#### Normal maps: distance against size and quality

All 45 normal maps of the sample game, decoded by JXL-SZI and compared with their sources (X and Y channels):

| | Normal-map files | Quality (BC5) |
|---|---|---|
| `.ctex` (BC5) | 91.2 MB | 44.0 dB |
| Basis Universal | 54.4 MB | 38.2 dB |
| JXL-SZI, distance 1.0 | 30.8 MB | 34.3 dB |
| JXL-SZI, distance 0.5 | 44.4 MB | 37.6 dB |
| **JXL-SZI, distance 0.35 (default)** | **53.1 MB** | **39.5 dB** |
| JXL-SZI, distance 0.25 | 62.0 MB | 41.2 dB |
| JXL-SZI, distance 0.15 | 76.3 MB | 43.6 dB |
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
| Blocks > Opaque Format | BC1 | BC1, or BC7 for twice the memory and far more detail. See [the table](#block-formats-quality-and-cost). |
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
- **Does it change the frame rate?** No. The GPU samples the same BC / ETC2 block formats as with `.ctex`.
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
  the GPU. In the sample game, JXL-SZI's build was 12% smaller and loaded about 0.6 s faster, while Basis kept more
  detail. See [Compared with `.ctex` and Basis Universal](#compared-with-ctex-and-basis-universal).

## License

[MIT](LICENSE). The bundled converter tools contain third-party code under their own licenses: see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
