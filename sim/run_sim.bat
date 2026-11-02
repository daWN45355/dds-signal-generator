@echo off
rem ============================================================
rem  cmd_parser behavioral sim (xvlog -> xelab -> xsim)
rem  Usage: double click this file
rem ============================================================
setlocal
set "V=D:\vivad\Vivado\2017.4\bin"
pushd "%~dp0"

if exist xsim.dir rmdir /s /q xsim.dir
if exist xvlog.log del /q xvlog.log
if exist xelab.log del /q xelab.log

echo [1/3] xvlog ...
call "%V%\xvlog.bat" -work work ..\src\cmd_parser.v tb_cmd.v
if errorlevel 1 goto fail

echo [2/3] xelab ...
call "%V%\xelab.bat" -debug typical -s tbsim tb_cmd
if errorlevel 1 goto fail

echo [3/3] xsim ...
call "%V%\xsim.bat" tbsim -runall
goto done

:fail
echo.
echo [SIM BUILD FAILED] see xvlog.log / xelab.log
:done
echo.
popd
endlocal
