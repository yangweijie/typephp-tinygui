@echo off
rem ===========================================================================
rem Demo build hook -- referenced by tinyjs.json as "typephp".build, so
rem `tinyjs build --typephp` and `tinyjs publish --typephp` run it.
rem
rem It does NOT compile: the PHP backend is compiled once by tools\build-all.bat
rem and then deployed per-app. Compiling here would mean one tpc invocation per
rem project for byte-identical output.
rem
rem Produces (all git-ignored):
rem   backend\app.exe     the compiled PHP backend this app runs
rem   backend\*.dll       the PHP runtime app.exe imports
rem
rem usage:  tools\build-all.bat   first, once
rem         demo\build.bat        then, or via the tinyjs CLI
rem ===========================================================================
setlocal
pushd "%~dp0"
set "ROOT=%~dp0.."
set "BUILD=%ROOT%\build"

if not exist "%BUILD%\app.exe" (
  echo [!] %BUILD%\app.exe not found.
  echo     run tools\build-all.bat once to compile the backend, then retry.
  echo     ^(see README.md, "Build"^)
  popd
  exit /b 1
)

echo == [1/2] deploying backend\app.exe
if not exist backend mkdir backend
copy /y "%BUILD%\app.exe" "backend\app.exe" >nul
if errorlevel 1 (popd & exit /b 1)

echo == [2/2] deploying backend\*.dll
for %%D in (php8ts.dll phpx.dll libmpdec-4.0.1.dll libmpdec++-4.0.1.dll gmp-10.dll mpfr-6.dll) do (
  if exist "%BUILD%\%%D" (
    copy /y "%BUILD%\%%D" "backend\%%D" >nul
  ) else (
    echo    [!] missing %BUILD%\%%D -- re-run tools\build-all.bat
  )
)

popd
echo.
echo == done: backend\app.exe + DLLs ready
endlocal
