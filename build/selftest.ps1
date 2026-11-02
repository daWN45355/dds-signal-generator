# ============================================================
#  selftest.ps1 -- 串口接线自检
#
#  做三件事：找 CH340 端口 -> 发一个问号 -> 读一行判定
#  不需要装 pyserial，只用 .NET 的 SerialPort
# ============================================================

$ErrorActionPreference = "Continue"
$OutputEncoding = [System.Text.Encoding]::GetEncoding("GBK")

Write-Host ""
Write-Host "======================================================"
Write-Host "  串口接线自检"
Write-Host "======================================================"
Write-Host ""

function Find-Port {
    $cands = New-Object System.Collections.ArrayList

    try {
        foreach ($d in (Get-WmiObject Win32_SerialPort -ErrorAction Stop)) {
            if ($d.DeviceID -match '(COM\d+)' -and $d.Name -match 'CH34|USB-SERIAL|USB 串行|Silicon') {
                [void]$cands.Add($d.DeviceID)
            }
        }
    } catch { }

    if ($cands.Count -eq 0) {
        try {
            foreach ($d in (Get-PnpDevice -Class Ports -PresentOnly -ErrorAction Stop)) {
                if ($d.FriendlyName -match 'CH34|USB-SERIAL|USB 串行') {
                    if ($d.FriendlyName -match '(COM\d+)') { [void]$cands.Add($matches[1]) }
                }
            }
        } catch { }
    }

    if ($cands.Count -eq 0) { return $null }
    return $cands[0]
}

$port = Find-Port
if (-not $port) {
    Write-Host "[!] 没找到 CH340 串口。"
    Write-Host "    检查：USB 线是否插好、CH340 驱动是否安装、设备管理器里有没有 COM 口。"
    Write-Host ""
    Read-Host "按回车退出"
    exit 1
}

Write-Host "端口: $port"
Write-Host "参数: 115200-8-N-1"
Write-Host ""

$sp = New-Object System.IO.Ports.SerialPort $port, 115200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One
$sp.ReadTimeout = 2000
$sp.WriteTimeout = 2000

try {
    $sp.Open()
} catch {
    Write-Host ("[!] 打不开 " + $port + " ：" + $_.Exception.Message)
    Write-Host "    可能被别的程序占用了（比如已经开着的串口终端 / 网页控制台）。"
    Write-Host ""
    Read-Host "按回车退出"
    exit 1
}

Write-Host "[1/2] 发送问号 ..."
Start-Sleep -Milliseconds 200

# 先清空接收缓冲，避免读到上次残留
try { $sp.DiscardInBuffer() } catch { }

try {
    $sp.Write("?`r")
} catch {
    Write-Host ("[!] 发送失败：" + $_.Exception.Message)
    $sp.Close()
    Read-Host "按回车退出"
    exit 1
}

Write-Host "[2/2] 等回传（最多 2 秒）..."
$line = $null
try {
    $line = $sp.ReadLine()
} catch {
    $line = $null
}

$sp.Close()

if ($null -eq $line) {
    Write-Host ""
    Write-Host "[X] 2 秒内没收到任何数据。按可能性排序："
    Write-Host "    1) 比特流没下载（板上 DONE 灯不亮）—— 先烧 06_bitstream/7_key_dds.bit"
    Write-Host "    2) TXD / RXD 接反了 —— 交换 D18 与 D20 两根线"
    Write-Host "    3) GND 没接 —— CH340 的 GND 必须与板子共地"
    Write-Host "    4) 波特率不是 115200"
    Write-Host ""
    Read-Host "按回车退出"
    exit 1
}

Write-Host ""
Write-Host ("收到: " + $line.Trim())

if ($line -match 'F=\d+\s+P=\d+\s+W=\d+\s+A=\d+\s+D=[+-]\s+K=[01]{4}') {
    Write-Host ""
    Write-Host "[OK] 接线正确，板子在正常回状态行。"
    Write-Host "     下一步：用 02 串口调参发 F1000 / W1 / P90 / A50 看波形变化。"
    if ($line -match 'K=([01]{4})') {
        $k = $Matches[1]
        Write-Host ""
        Write-Host ("     K 字段 = " + $k)
        if ($k -eq "0000") {
            Write-Host "     空闲应为 0000 —— 当前正确，没有键被误判为按下。"
        } else {
            Write-Host "     空闲应为 0000 —— 现在不是 0000，说明有键卡住或按键极性/引脚配置有问题。"
            Write-Host "     对照：按住 KEY_1/2/3/4 应依次变成 1000/0100/0010/0001。"
        }
    }
    $code = 0
} else {
    Write-Host ""
    Write-Host "[?] 收到了数据，但不像状态行。"
    Write-Host "    检查波特率是否 115200，或板上跑的是不是别的工程（比如 4_uart_tune.bit 的报文格式不同）。"
    $code = 2
}

Write-Host ""
Read-Host "按回车退出"
exit $code
