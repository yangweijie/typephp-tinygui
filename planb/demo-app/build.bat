@echo off
rem Rebuild the two sidecars this demo needs, in one shot:
rem   ..\backend_shell.exe -> <tinyjsapp>\native\backend.exe   (the shim)
rem   ..\backend.php       -> backend\app.exe                  (the PHP backend)
rem Then: tinyjs dev --typephp
rem
rem Override TPC_HOME / VCVARS / TINYJSAPP via the environment if yours differ.
setlocal
pushd "%~dp0"

if "%TPC_HOME%"==""   set "TPC_HOME=D:\git\php\tpc_v0.9.3_windows_x64"
if "%VCVARS%"==""     set "VCVARS=D:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if "%TINYJSAPP%"==""  set "TINYJSAPP=D:\git\web\tinyjsapp-0.42.0"
set "PLANB=%~dp0.."
set "PHP_HOME=%TPC_HOME%"
set "PHPX_HOME=%TPC_HOME%\phpx"
set "PATH=%TPC_HOME%;%PATH%"

echo == [1/4] shim (backend_shell.exe) ==
g++ -std=c++17 -O2 -o "%PLANB%\backend_shell.exe" "%PLANB%\backend_shell.cpp" -ladvapi32
if errorlevel 1 exit /b 1
copy /y "%PLANB%\backend_shell.exe" "%TINYJSAPP%\native\backend.exe" >nul
if errorlevel 1 exit /b 1

echo == [2/4] PHP backend (app.exe via tpc @ %TPC_HOME%) ==
call "%VCVARS%" >nul 2>&1
if not exist backend mkdir backend
"%TPC_HOME%\tpc.exe" "%PLANB%\backend.php" -o backend\app.exe -f -O2
if errorlevel 1 exit /b 1

echo == [3/4] PHP runtime DLLs ==
rem app.exe is NOT self-contained: it imports php8ts.dll / phpx.dll /
rem libmpdec*.dll / gmp-10.dll / mpfr-6.dll (15.5 MB total for tpc v0.9.3).
rem Windows resolves non-KnownDLLs from the exe's own directory FIRST, so copying
rem them next to app.exe pins the right version and removes any PATH dependency
rem ("it worked on my machine" = the tpc dir happened to be on PATH).
for %%D in (php8ts.dll phpx.dll libmpdec-4.0.1.dll libmpdec++-4.0.1.dll gmp-10.dll mpfr-6.dll) do (
  if exist "%TPC_HOME%\%%D" (
    copy /y "%TPC_HOME%\%%D" "backend\%%D" >nul
  ) else (
    echo    [!] missing %TPC_HOME%\%%D
  )
)
echo    ok: backend\*.dll

echo == [4/4] launcher ==
if not exist "%TINYJSAPP%\native\launcher-win.exe" (
  echo    [!] %TINYJSAPP%\native\launcher-win.exe missing
  echo        run the tinyjsapp-windows-build skill's build_launcher.sh, or setup.ps1
) else (
  echo    ok: %TINYJSAPP%\native\launcher-win.exe
)

popd
echo.
echo == done. now run:  %TINYJSAPP%\bin\tjs.exe run %TINYJSAPP%\cli.js dev --typephp
endlocal
