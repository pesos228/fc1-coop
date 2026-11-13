# Build FarCryCoopNet.asi (x86) with the read-only MSVC in D:\TailCore\toolchain\vs.
# There is no Windows SDK outside drive C:, so import libraries are generated below and the
# plugin is linked without the CRT.
# Usage: & games\far-cry\asi\build.ps1 [-Out E:\FarCryCoop\Temp\asi]
param([string]$Out = 'E:\FarCryCoop\Temp\asi')
. E:\FarCryCoop\env.ps1
$msvc = 'D:\TailCore\toolchain\vs\VC\Tools\MSVC\14.44.35207'
$bin = "$msvc\bin\Hostx64\x86"
New-Item -ItemType Directory -Force $Out | Out-Null
# Imported functions: name = bytes of stdcall arguments.
$imports = [ordered]@{
  kernel32 = [ordered]@{ GetModuleHandleA = 4; GetModuleFileNameA = 12; VirtualAlloc = 16; VirtualProtect = 16
    FlushInstructionCache = 12; GetCurrentProcess = 0; GetCurrentProcessId = 0; GetCurrentThreadId = 0
    InitializeCriticalSection = 4; EnterCriticalSection = 4; LeaveCriticalSection = 4; TryEnterCriticalSection = 4; CreateThread = 24; Sleep = 4
    CreateFileA = 28; WriteFile = 20; ReadFile = 20; CloseHandle = 4; DeleteFileA = 4; AddVectoredExceptionHandler = 8; GetTickCount = 0; DisableThreadLibraryCalls = 4; lstrcmpiA = 8; IsBadReadPtr = 8
    LoadLibraryA = 4; GetProcAddress = 8; SetEnvironmentVariableA = 8; GetCommandLineA = 0 }
  user32 = [ordered]@{ wvsprintfA = 12; LoadKeyboardLayoutA = 8; GetKeyboardLayout = 4 }
  winmm = [ordered]@{ timeBeginPeriod = 4 }
}
# An import library is a by-product of linking a stub DLL with the same stdcall exports:
# symbols stay decorated (_Sleep@4) while the imported names are plain (Sleep).
foreach ($l in $imports.Keys) {
  $c = foreach ($f in $imports[$l].Keys) {
    $n = $imports[$l][$f] / 4
    $a = if ($n) { (0..($n - 1) | ForEach-Object { "int a$_" }) -join ', ' } else { 'void' }
    "void __stdcall $f($a) {}"
  }
  Set-Content "$Out\$l.c" -Encoding ascii $c
  Set-Content "$Out\$l.def" -Encoding ascii (@("LIBRARY $l.dll", 'EXPORTS') + @($imports[$l].Keys))
  & "$bin\cl.exe" /nologo /c /Zl "/Fo$Out\$l.obj" "$Out\$l.c" | Out-Null
  & "$bin\link.exe" /nologo /dll /noentry /nodefaultlib /machine:x86 "/def:$Out\$l.def" `
    "/out:$Out\$l.stub.dll" "/implib:$Out\$l.lib" "$Out\$l.obj" | Out-Null
  if ($LASTEXITCODE) { exit $LASTEXITCODE }
}
& "$bin\cl.exe" /nologo /c /O1 /GS- /W3 /Zl "/I$msvc\include" "/Fo$Out\FarCryCoopNet.obj" "$PSScriptRoot\FarCryCoopNet.c"
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& "$bin\link.exe" /nologo /dll /nodefaultlib /entry:DllMain /safeseh:no /machine:x86 `
  "/out:$Out\FarCryCoopNet.asi" "$Out\FarCryCoopNet.obj" "$Out\kernel32.lib" "$Out\user32.lib" "$Out\winmm.lib"
exit $LASTEXITCODE
