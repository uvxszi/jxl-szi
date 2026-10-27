# Building the converter tools

The export runs two programs for each texture. Windows x86_64 builds of both come in
`addons/jxl_szi/bin/windows-x86_64/`. On other systems, or to rebuild them, follow this page.

| Tool | What it does | Source |
|---|---|---|
| `cjxl` | Encodes the image as JPEG XL, with two small changes to libjxl 0.12.0 (below) | libjxl v0.12.0 + `libjxl/jxl-szi-libjxl-0.12.0.patch` |
| `stager` | Decodes each file once and adds the boxes the runtime reads: where each pass group's data ends, which alpha groups are a single value, and the staged GPU job (headers, entropy tables, LF image, block info) as zlib | `stager/` (Rust, on a patched jxl-oxide 0.12) |

The files stay standard JPEG XL: other decoders ignore the extra boxes.

## Linux and macOS

You need git, CMake 3.16 or newer, a C++17 compiler, Ninja or make, and Rust 1.85 or newer
([rustup.rs](https://rustup.rs)). Then run:

```sh
sh tools/build_tools.sh
```

This clones libjxl v0.12.0 with its submodules into `tools/libjxl/libjxl`, applies the patch and builds `cjxl`. It
then builds `stager` and copies both into `addons/jxl_szi/bin/<os>-<arch>/`, where the export looks for them.

## Windows

You need git, Visual Studio 2022 (Build Tools or Community) with the C++ workload, and Rust 1.85 or newer. Then run:

```bat
tools\build_tools.bat
```

The C/C++ runtime is linked into both programs, so they run on any Windows 10/11 x86_64 PC without the Visual C++
redistributable.

## The libjxl patch

The GPU decoder reads a subset of JPEG XL that the patch makes cjxl write. The export turns both changes on through
environment variables; without them the patched cjxl behaves like the released one.

- **`JXL_SZI_PASSES=3,5,8`:** three progressive AC passes (the 3x3, 5x5 and 8x8 corners of each 8x8 block's
  coefficients). Each 256x256 group's entropy-coded data comes in three shorter streams, which is what a GPU decoder
  waits on.
- **`JXL_SZI_ANS=1`:** ANS entropy coding everywhere. libjxl otherwise switches small streams to prefix codes, which
  the decoder doesn't implement.
- **Build fix:** with the bundled libpng and zlib, the build finds `zlib.h` in the build tree.

The export runs `cjxl <image> <out.jxl> -d 1 -e 7 --faster_decoding=4`. Then it runs `stager --annotate <dir> <files...>`
with `JXL_SZI_SIDE=z`.
