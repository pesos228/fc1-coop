@echo off
rem Build FarCryCoopNet.asi (x86) from games\far-cry\asi with the local MSVC + Windows SDK.
rem Usage: tools\fcc\build-asi.cmd   (from the repo root) -> tools\bin\FarCryCoopNet.asi
setlocal
set ROOT=%~dp0..\..
set SRC=%ROOT%\games\far-cry\asi\FarCryCoopNet.c
set OUT=%ROOT%\tools\bin\asi
if not exist "%OUT%" mkdir "%OUT%"
call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x86 >nul || exit /b 1
cl /nologo /c /O1 /GS- /W3 /Zl "/Fo%OUT%\FarCryCoopNet.obj" "%SRC%" || exit /b 1
link /nologo /dll /nodefaultlib /entry:DllMain /safeseh:no /machine:x86 "/out:%ROOT%\tools\bin\FarCryCoopNet.asi" "%OUT%\FarCryCoopNet.obj" kernel32.lib user32.lib winmm.lib || exit /b 1
echo built %ROOT%\tools\bin\FarCryCoopNet.asi
