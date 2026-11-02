@echo off
rem ============================================================
rem  Build any project in one command
rem  Usage:  build.bat phase3_dual
rem          build.bat diag_pin
rem  Output: <project>\proj\<project>.runs\impl_1\<top>.bit
rem ============================================================
setlocal
set "VIVADO=D:\vivad\Vivado\2017.4\bin\vivado.bat"
set "HERE=%~dp0"

if "%~1"=="" (
    echo.
    echo Usage: build.bat ^<project_folder^>
    echo Available:
    for /d %%D in ("%HERE%*") do echo    %%~nxD
    echo.
    exit /b 1
)

if not exist "%HERE%%~1\build.tcl" (
    echo [ERROR] %HERE%%~1\build.tcl not found
    exit /b 1
)

pushd "%HERE%%~1"
echo Building project: %~1
call "%VIVADO%" -mode batch -source build.tcl -nojournal -nolog
set "RC=%ERRORLEVEL%"
popd

if "%RC%"=="0" (
    echo.
    echo [OK] bit file: %HERE%%~1\proj\%~1.runs\impl_1\*.bit
) else (
    echo [FAILED] exit code %RC%
)
endlocal
