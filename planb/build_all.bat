@echo off
rem ===========================================================================
rem Build the TypePHP <-> tinyjsapp bridge artifacts:
rem   backend_shell.exe  C++ shim     (MinGW-w64 g++)
rem   app.exe            PHP backend  (aot-compiler / tpc, bin mode, MSVC)
rem
rem The launcher spawns the shim (default "<launcher_dir>\backend.exe" or
rem %TYPEPHP_BACKEND%); the shim spawns app.exe (%TYPEPHP_APP%, default <dir>\app.exe).
rem Override PHP_HOME / TPC / VC vars via the environment if yours differ.
rem ===========================================================================
setlocal
pushd "%~dp0"

rem Force the toolchain (ambient PHP_HOME may point at another tpc version).
if "%TPC_HOME%"=="" set "TPC_HOME=D:\git\php\tpc_v0.9.3_windows_x64"
if "%VCVARS%"=="" set "VCVARS=D:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set "PHP_HOME=%TPC_HOME%"
set "PHPX_HOME=%TPC_HOME%\phpx"
set "PATH=%TPC_HOME%;%PATH%"

where g++ >nul 2>&1
if errorlevel 1 (
  echo [!] g++ ^(MinGW-w64^) not on PATH. Install: winget install BrechtSanders.WinLibs.POSIX.UCRT
  exit /b 1
)

echo == [1/2] building shim ^(backend_shell.exe^) ==
g++ -std=c++17 -O2 -o backend_shell.exe backend_shell.cpp -ladvapi32
if errorlevel 1 exit /b 1

echo == [2/2] building PHP backend ^(app.exe^) with tpc @ %TPC_HOME% ==
call "%VCVARS%" >nul 2>&1
"%TPC_HOME%\tpc.exe" backend.php -o app.exe -f -O2
if errorlevel 1 exit /b 1

popd
echo.
echo == done: backend_shell.exe + app.exe ready ==
echo    run: launcher-win.exe --typephp index.html "My App" 960x640
endlocal
