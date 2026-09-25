@echo off
call "D:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
set "PHP_HOME=D:\git\php\tpc_v0.9.3_windows_x64"
set "PHPX_HOME=D:\git\php\tpc_v0.9.3_windows_x64\phpx"
set "PATH=D:\git\php\tpc_v0.9.3_windows_x64;%PATH%"
cd /d "D:\git\php\typephp-gui\nano-stdio-test"
"D:\git\php\tpc_v0.9.3_windows_x64\tpc.exe" test_line.php -o test_line_bin.exe
echo BUILD_RC=%ERRORLEVEL%
