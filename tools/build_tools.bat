@echo off
rem Builds JXL-SZI's converter tools on Windows x86_64 into addons\jxl_szi\bin\windows-x86_64\ (what the addon ships):
rem   cjxl.exe    libjxl 0.12.0 with tools\libjxl\jxl-szi-libjxl-0.12.0.patch (static, C++ runtime linked in)
rem   stager.exe  tools\stager (Rust, C runtime linked in)
rem Needs git, Visual Studio 2022 Build Tools (C++ workload, with its CMake and Ninja) and Rust 1.85+ (cargo). Downloads
rem libjxl (with its submodules) into tools\libjxl\libjxl the first time.
rem   tools\build_tools.bat
setlocal
set ROOT=%~dp0..
set SRC=%ROOT%\tools\libjxl\libjxl
set OUT=%ROOT%\addons\jxl_szi\bin\windows-x86_64
set VS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools
if not exist "%VS%" set VS=C:\Program Files\Microsoft Visual Studio\2022\Community
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
set PATH=%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%
if not exist "%SRC%" (
	git clone --depth 1 --branch v0.12.0 --recursive --shallow-submodules https://github.com/libjxl/libjxl.git "%SRC%" || exit /b 1
	git -C "%SRC%" apply "%ROOT%\tools\libjxl\jxl-szi-libjxl-0.12.0.patch" || exit /b 1
)
cmake -S "%SRC%" -B "%SRC%\build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF ^
  -DCMAKE_POLICY_DEFAULT_CMP0091=NEW -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded ^
  -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF ^
  -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_JPEGLI=OFF ^
  -DJPEGXL_BUNDLE_LIBPNG=ON -DJPEGXL_ENABLE_SKCMS=ON -DJPEGXL_ENABLE_DEVTOOLS=OFF || exit /b 1
cmake --build "%SRC%\build" --target cjxl || exit /b 1
set RUSTFLAGS=-C target-feature=+crt-static
cargo build --release --manifest-path "%ROOT%\tools\stager\Cargo.toml" --bin stager || exit /b 1
if not exist "%OUT%" mkdir "%OUT%"
copy /y "%SRC%\build\tools\cjxl.exe" "%OUT%\cjxl.exe" >nul || exit /b 1
copy /y "%ROOT%\tools\stager\target\release\stager.exe" "%OUT%\stager.exe" >nul || exit /b 1
"%OUT%\cjxl.exe" --version
echo tools in %OUT%
