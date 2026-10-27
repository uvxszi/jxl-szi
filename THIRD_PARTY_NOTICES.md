# Third-party notices

The addon's GDScript and shaders run in your game; they contain no third-party code. The two converter tools in
`addons/jxl_szi/bin/` run only in the editor and never ship with a game. They are built from these sources, whose
licenses are in [licenses/](licenses/):

## cjxl (libjxl 0.12.0, patched)

| Component | License | File |
|---|---|---|
| libjxl | BSD-3-Clause (and its patent grant) | `licenses/libjxl-LICENSE.txt`, `licenses/libjxl-PATENTS.txt` |
| Brotli | MIT | `licenses/brotli-LICENSE.txt` |
| Highway | Apache-2.0 or BSD-3-Clause | `licenses/highway-LICENSE.txt`, `licenses/highway-LICENSE-BSD3.txt` |
| skcms | BSD-3-Clause | `licenses/skcms-LICENSE.txt` |
| libpng | libpng license (PNG Reference Library License v2) | `licenses/libpng-LICENSE.txt` |
| zlib | zlib license | `licenses/zlib-LICENSE.txt` |

JXL-SZI's changes to libjxl are in `tools/libjxl/jxl-szi-libjxl-0.12.0.patch`.

## stager

This is Rust, built on jxl-oxide 0.12 (MIT OR Apache-2.0). Five jxl-oxide crates are patched: `jxl-render`,
`jxl-coding`, `jxl-vardct`, `jxl-modular` and `jxl-frame`. Their patched copies, with their license files, are in
`tools/stager/patched/`.

Every crate compiled into it, with its license texts, is listed in `licenses/rust-crates.txt`. All of them are
under MIT, Apache-2.0, BSD-3-Clause, Zlib, 0BSD, Unlicense or Unicode-3.0 terms.
