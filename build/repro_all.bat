@echo off
chcp 936 >nul
setlocal
title 一键复现 - eabaz4205_dds

rem ============================================================
rem  一键复现：三步，任何一步失败就停
rem
rem    1/3  静态检查   源码完整性 / 端口约束 / bit 是否过期
rem    2/3  构建       综合 -> 实现 -> 比特流
rem    3/3  结果校验   时序与资源是否偏离基线
rem
rem  依赖： Vivado 2017.4（路径见 build.bat 的 VIVADO 变量）
rem         Python 3.6+（只用标准库）
rem ============================================================

set "HERE=%~dp0"
pushd "%HERE%"

rem ---------- 0. 环境检查 ----------
where python >nul 2>nul
if errorlevel 1 (
    echo.
    echo [!] 找不到 python 命令。
    echo     校验脚本需要 Python 3.6+。若不需要校验，可只跑 build.bat。
    echo.
    pause
    popd
    endlocal & exit /b 2
)

cls
echo ======================================================
echo   一键复现  eabaz4205_dds
echo ======================================================
echo.

rem ---------- 1/3 静态检查 ----------
echo [1/3] 静态检查 ...
echo.
python "%HERE%..\skills\checks\check_repro.py" --proj "%HERE%.." --top dds_key_top
set "RC1=%ERRORLEVEL%"
if not "%RC1%"=="0" (
    echo.
    echo [STOP] 静态检查未通过，先修上面列出的问题再构建。
    echo.
    pause
    popd
    endlocal & exit /b 1
)

rem ---------- 2/3 构建 ----------
echo.
echo [2/3] 构建（约 4 分钟）...
echo.
call "%HERE%build.bat"
set "RC2=%ERRORLEVEL%"
if not "%RC2%"=="0" (
    echo.
    echo [STOP] 构建失败，退出码 %RC2%
    echo        日志： proj\eabaz4205_dds.runs\impl_1\runme.log
    echo.
    pause
    popd
    endlocal & exit /b %RC2%
)

rem ---------- 3/3 结果校验 ----------
echo.
echo [3/3] 结果校验（与基线比对）...
echo.
python "%HERE%..\skills\checks\check_impl.py" --proj "%HERE%..\data"
set "RC3=%ERRORLEVEL%"

echo.
echo ======================================================
if "%RC3%"=="0" (
    echo   复现成功，结果与基线一致
) else (
    echo   构建完成，但结果偏离基线（见上面的 [FAIL] 行）
    echo   常见原因：改了代码、换了 Vivado 版本、换了机器。
    echo   若确认改动是有意的，用下面这句重设基线：
    echo       python skills\checks\check_impl.py --proj data --init
)
echo ======================================================
echo.
echo   比特流： %HERE%proj\eabaz4205_dds.runs\impl_1\dds_key_top.bit
echo.
pause

popd
endlocal & exit /b %RC3%
