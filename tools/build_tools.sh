#!/bin/sh
# Builds JXL-SZI's converter tools on Linux or macOS into addons/jxl_szi/bin/<os>-<arch>/:
#   cjxl    libjxl 0.12.0 with tools/libjxl/jxl-szi-libjxl-0.12.0.patch (static libjxl, bundled libpng)
#   stager  tools/stager (Rust)
# Needs git, CMake 3.16+, a C++17 compiler, Ninja or make, and Rust 1.85+ (cargo). Downloads libjxl (with its
# submodules) into tools/libjxl/libjxl the first time.
#   sh tools/build_tools.sh
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
case "$(uname -s)" in
	Linux) OS=linux ;;
	Darwin) OS=macos ;;
	*) echo "use tools/build_tools.bat on Windows"; exit 1 ;;
esac
case "$(uname -m)" in
	x86_64|amd64) ARCH=x86_64 ;;
	arm64|aarch64) ARCH=arm64 ;;
	*) ARCH=$(uname -m) ;;
esac
OUT="$ROOT/addons/jxl_szi/bin/$OS-$ARCH"
SRC="$ROOT/tools/libjxl/libjxl"
if [ ! -d "$SRC" ]; then
	git clone --depth 1 --branch v0.12.0 --recursive --shallow-submodules https://github.com/libjxl/libjxl.git "$SRC"
	git -C "$SRC" apply "$ROOT/tools/libjxl/jxl-szi-libjxl-0.12.0.patch"
fi
GEN=""
command -v ninja >/dev/null 2>&1 && GEN="-G Ninja"
cmake -S "$SRC" -B "$SRC/build" $GEN -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
	-DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF \
	-DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_JPEGLI=OFF \
	-DJPEGXL_BUNDLE_LIBPNG=ON -DJPEGXL_ENABLE_SKCMS=ON -DJPEGXL_ENABLE_DEVTOOLS=OFF
cmake --build "$SRC/build" --target cjxl -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
cargo build --release --manifest-path "$ROOT/tools/stager/Cargo.toml" --bin stager
mkdir -p "$OUT"
cp "$SRC/build/tools/cjxl" "$OUT/cjxl"
cp "$ROOT/tools/stager/target/release/stager" "$OUT/stager"
"$OUT/cjxl" --version | head -1
echo "tools in $OUT"
