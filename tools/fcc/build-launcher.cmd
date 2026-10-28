@echo off
rem Build FarCryCoopLauncher.exe (Tauri, i686) from games\far-cry\launcher with rustup's Rust and the
rem local MSVC 2019 Build Tools + Windows SDK (x86). Runs the launcher's unit tests first.
rem Usage: tools\fcc\build-launcher.cmd   (from the repo root) -> tools\bin\launcher\FarCryCoopLauncher.exe
rem Needs: rustup target add i686-pc-windows-msvc
setlocal
set ROOT=%~dp0..\..
set OUT=%ROOT%\tools\bin\launcher
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x86 >nul || exit /b 1
set RUSTFLAGS=-C target-feature=+crt-static
set CARGO_TARGET_DIR=%ROOT%\.harness\launcher-target
cargo test --target i686-pc-windows-msvc --manifest-path "%ROOT%\games\far-cry\launcher\Cargo.toml" || exit /b 1
cargo build --release --target i686-pc-windows-msvc --manifest-path "%ROOT%\games\far-cry\launcher\Cargo.toml" || exit /b 1
if not exist "%OUT%" mkdir "%OUT%"
copy /y "%CARGO_TARGET_DIR%\i686-pc-windows-msvc\release\FarCryCoopLauncher.exe" "%OUT%" >nul || exit /b 1
echo built %OUT%\FarCryCoopLauncher.exe
