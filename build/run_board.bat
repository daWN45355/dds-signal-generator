@echo off
chcp 936 >nul
setlocal enabledelayedexpansion
title EBAZ4205 DDS - 上板运行入口

set "HERE=%~dp0"
set "VIVADO=D:\vivad\Vivado\2017.4\bin\vivado.bat"
set "BIT=%HERE%..\bit\dds_key_top.bit"

:menu
cls
echo ======================================================
echo    EBAZ4205  双通道 DDS 信号发生器   上板运行入口
echo ======================================================
echo.
echo   接线（板已上电、比特流已下载）：
echo     DAC    DIN --^> F19    SCLK --^> F20    CS --^> D19
echo            VCC --^> 5V     GND  --^> GND
echo     串口   CH340 TXD --^> D18    RXD --^> D20   GND --^> GND
echo.
echo   ----------------------------------------------------
echo   [1] 网页控制台    拖滑块控频率/相位/幅度，实时看波形
echo   [2] 串口调参      菜单式调参，或用第 6 项发任意指令
echo   [3] 只看回传      纯监听，用来确认板子在不在发报文
echo   [4] 烧录比特流    用 Vivado 把 bit 下载到板卡
echo   [5] 串口接线自检  只发一个问号，看能不能收到状态行
echo   [0] 退出
echo   ----------------------------------------------------
echo.
set /p "sel=请选择 1-5 或 0 : "

if "%sel%"=="1" goto web
if "%sel%"=="2" goto tune
if "%sel%"=="3" goto listen
if "%sel%"=="4" goto program
if "%sel%"=="5" goto selftest
if "%sel%"=="0" goto end
goto menu

rem ============================================================
:web
cls
echo [网页控制台] 启动 dds_monitor.py ...
echo.
echo   需要的依赖： pip install pyserial
echo   启动后浏览器会自动打开 http://localhost:8000
echo   关闭本窗口即停止服务。
echo.
where python >nul 2>nul
if errorlevel 1 (
    echo [!] 找不到 python 命令。请先安装 Python 3 并勾选 "Add to PATH"。
    echo.
    pause
    goto menu
)
pushd "%HERE%..\src\host"
python -c "import serial" >nul 2>nul
if errorlevel 1 (
    echo [!] 缺少 pyserial，正在尝试安装 ...
    python -m pip install pyserial
    echo.
)
python dds_monitor.py
popd
echo.
echo [网页控制台已退出]
pause
goto menu

rem ============================================================
:tune
cls
echo [串口调参] 启动 uart_tune.ps1 ...
echo.
echo   脚本会自动找 CH340 的端口号。
echo   菜单 1-5 分别改 频率/相位/波形/幅度/方向，6 可发任意指令。
echo   常用指令： F1000  P90  W2  A50  D1  S1  ?
echo.
if not exist "%HERE%tools\uart_tune.ps1" (
    echo [!] 缺少 tools\uart_tune.ps1
    pause
    goto menu
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%tools\uart_tune.ps1"
echo.
pause
goto menu

rem ============================================================
:listen
cls
echo [只看回传] 启动 monitor_serial.ps1 ...
echo.
echo   只读不写。确认板子在不在每秒发状态行。
echo   若一直没有数据，先确认：比特流下了没有、串口线 TXD/RXD 有没有接反。
echo.
if not exist "%HERE%tools\monitor_serial.ps1" (
    echo [!] 缺少 tools\monitor_serial.ps1
    pause
    goto menu
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%tools\monitor_serial.ps1"
echo.
pause
goto menu

rem ============================================================
:program
cls
echo [烧录比特流]
echo.
if not exist "%BIT%" (
    echo [!] 找不到比特流： %BIT%
    echo     请先跑 02_build\build.bat 重新生成。
    pause
    goto menu
)
echo   比特流： %BIT%
echo.
echo   方式 A（本脚本自动烧，需要 hw_server 已在 3121 端口运行）：
echo       直接按回车继续；
echo   方式 B（手工在 GUI 里烧）：
echo       输入 N 回车，按屏幕提示操作。
echo.
set /p "auto=回车=自动烧 / N=看 GUI 步骤 : "
if /i "%auto%"=="N" goto program_gui

if not exist "%VIVADO%" (
    echo [!] 找不到 Vivado： %VIVADO%
    echo     请修改本脚本开头的 VIVADO 变量。
    pause
    goto menu
)
call "%VIVADO%" -mode batch -source "%HERE%program_bit.tcl" -nojournal -nolog
echo.
echo [自动烧录结束] 若上面报 connect_hw_server 失败，改用方式 B。
pause
goto menu

:program_gui
echo.
echo   1. 板子上电，JTAG 下载器接好
echo   2. Vivado 左侧最下 -^> Open Hardware Manager
echo   3. Open Target -^> Auto Connect
echo   4. 出现 xc7z010 后右键 -^> Program Device
echo   5. Bitstream file 手打下面这个路径（别用中文路径）：
echo        %BIT%
echo   6. 点 Program，等 "Programmed successfully"
echo   7. 烧完立刻拔掉 JTAG 线 —— 本板 JTAG 座松动，
echo      线一动配置流可能被打断，波形会突然全没、DONE 灯灭
echo.
pause
goto menu

rem ============================================================
:selftest
cls
echo [串口接线自检]
echo.
echo   只发一个问号，等 2 秒看有没有回一行 F=xxxxx P=xxx ...
echo.
if not exist "%HERE%selftest.ps1" (
    echo [!] 缺少 selftest.ps1
    pause
    goto menu
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%selftest.ps1"
echo.
pause
goto menu

rem ============================================================
:end
endlocal
exit /b 0
