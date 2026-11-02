@echo off
chcp 936 >nul
setlocal
title Build - eabaz4205_dds

rem ============================================================
rem  单步构建：综合 -> 实现 -> 生成比特流 -> 打印 WNS
rem
rem  产物： proj\eabaz4205_dds.runs\impl_1\dds_key_top.bit
rem
rem  如果 Vivado 不在下面这个路径，改 VIVADO 这一行即可。
rem ============================================================

set "VIVADO=D:\vivad\Vivado\2017.4\bin\vivado.bat"
set "HERE=%~dp0"

if not exist "%VIVADO%" (
    echo.
    echo [!] 找不到 Vivado：
    echo     %VIVADO%
    echo.
    echo     请修改本脚本开头的 VIVADO 变量，指向你自己的 vivado.bat
    echo     例如： set "VIVADO=C:\Xilinx\Vivado\2017.4\bin\vivado.bat"
    echo.
    pause
    exit /b 1
)

if not exist "%HERE%build.tcl" (
    echo [!] 找不到 build.tcl
    pause
    exit /b 1
)

pushd "%HERE%"
echo.
echo ======================================================
echo   开始构建（约 4 分钟，主要耗时在实现阶段）
echo ======================================================
echo.

call "%VIVADO%" -mode batch -source build.tcl -nojournal -nolog
set "RC=%ERRORLEVEL%"
popd

echo.
if "%RC%"=="0" (
    echo [OK] 构建成功
    echo      比特流： %HERE%proj\eabaz4205_dds.runs\impl_1\dds_key_top.bit
) else (
    echo [FAILED] 退出码 %RC%
    echo          详细日志： %HERE%proj\eabaz4205_dds.runs\impl_1\runme.log
)

endlocal & exit /b %RC%
