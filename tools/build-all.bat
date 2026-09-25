@echo off
rem ===========================================================================
rem Build both Windows artifacts of the TypePHP <-> tinyjsapp bridge:
rem
rem   build\backend_shell.exe   the C++ shim      (MinGW-w64 g++)
rem   build\app.exe             the PHP backend   (aot-compiler / tpc, bin mode)
rem   build\*.dll               the PHP runtime app.exe imports
rem
rem Everything lands in <repo>\build\. Nothing is written into the tinyjsapp
rem checkout -- tools\build-launcher.sh assembles the runtime/ trio from here.
rem
rem Toolchain paths are overridable from the environment:
rem   TPC_HOME   tpc distribution  (default D:\git\php\tpc_v0.9.3_windows_x64)
rem   VCVARS     Visual Studio vcvars64.bat
rem
rem usage:  tools\build-all.bat
rem ===========================================================================
setlocal
pushd "%~dp0.."
set "ROOT=%CD%\"
set "BUILD=%ROOT%build"

if "%TPC_HOME%"=="" set "TPC_HOME=D:\git\php\tpc_v0.9.3_windows_x64"
if "%VCVARS%"==""  set "VCVARS=D:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"

if not exist "%TPC_HOME%\tpc.exe" (
  echo [!] tpc.exe not found at %TPC_HOME%\tpc.exe
  echo     set TPC_HOME to your aot-compiler distribution
  exit /b 1
)

where g++ >nul 2>&1
if errorlevel 1 (
  echo [!] g++ ^(MinGW-w64^) not on PATH.
  echo     install: winget install BrechtSanders.WinLibs.POSIX.UCRT
  exit /b 1
)

if not exist "%BUILD%" mkdir "%BUILD%"

echo == [1/3] shim ^(build\backend_shell.exe^)
g++ -std=c++17 -O2 -o "%BUILD%\backend_shell.exe" "%ROOT%shim\backend_shell.cpp" -ladvapi32
if errorlevel 1 exit /b 1

echo == [2/3] PHP backend ^(build\app.exe^) via tpc @ %TPC_HOME%
echo     source: %ROOT%src\backend.php
set "PHP_HOME=%TPC_HOME%"
set "PHPX_HOME=%TPC_HOME%\phpx"
set "PATH=%TPC_HOME%;%PATH%"
call "%VCVARS%" >nul 2>&1
"%TPC_HOME%\tpc.exe" "%ROOT%src\backend.php" -o "%BUILD%\app.exe" -f -O2
if errorlevel 1 exit /b 1

echo == [3/3] PHP runtime DLLs ^(build\^)
rem app.exe is NOT self-contained: it imports php8ts.dll / phpx.dll /
rem libmpdec*.dll / gmp-10.dll / mpfr-6.dll (~15.5 MB for tpc v0.9.3).
rem Windows resolves non-KnownDLLs from the exe's own directory FIRST, so a copy
rem next to app.exe pins the right version and removes any PATH dependency
rem ("worked on my machine" = the tpc dir happened to be on PATH).
for %%D in (php8ts.dll phpx.dll libmpdec-4.0.1.dll libmpdec++-4.0.1.dll gmp-10.dll mpfr-6.dll) do (
  if exist "%TPC_HOME%\%%D" (
    copy /y "%TPC_HOME%\%%D" "%BUILD%\%%D" >nul
  ) else (
    echo    [!] missing %TPC_HOME%\%%D
  )
)

popd
echo.
echo == done. next:
echo    bash tools/build-launcher.sh --install     ^(launcher + runtime trio^)
echo    cd demo ^&^& ^<tinyjsapp^>\bin\tjs.exe run ^<tinyjsapp^>\cli.js dev --typephp
endlocal
