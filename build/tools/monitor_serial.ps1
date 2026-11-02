# ============================================================
# monitor_serial.ps1 —— 串口监听（只收不发）
#
# 用途：配合 6_key_probe.bit，实时看板子打印出来的按键状态
#       格式  V13=1 T19=1 P19=1 U20=1 U19=1 V20=1
#
# 双击 monitor_serial.bat 运行，Ctrl+C 退出。
# ============================================================

$ErrorActionPreference = "Continue"
$OutputEncoding = [System.Text.Encoding]::GetEncoding("GBK")

Write-Host ""
Write-Host "======================================================"
Write-Host "  串口监听（只收不发）"
Write-Host "======================================================"
Write-Host ""

function Find-Ch340Port([string[]]$present) {
    $cands = New-Object System.Collections.ArrayList
    $base = "HKLM:\SYSTEM\CurrentControlSet\Enum\USB"
    if (Test-Path $base) {
        foreach ($vidKey in (Get-ChildItem $base -ErrorAction SilentlyContinue)) {
            if ($vidKey.PSChildName -notmatch "VID_1A86") { continue }
            foreach ($instKey in (Get-ChildItem $vidKey.PSPath -ErrorAction SilentlyContinue)) {
                $dp = Join-Path $instKey.PSPath "Device Parameters"
                if (-not (Test-Path $dp)) { continue }
                $pn = $null
                try { $pn = (Get-ItemProperty -Path $dp -Name PortName -ErrorAction Stop).PortName } catch { }
                if ($pn) { [void]$cands.Add($pn) }
            }
        }
    }
    foreach ($c in $cands) { if ($present -contains $c) { return $c } }
    return $null
}

$all = @()
try { $all = @([System.IO.Ports.SerialPort]::GetPortNames()) } catch { }

if ($all.Count -eq 0) {
    Write-Host "[X] 没有找到任何串口，先确认 CH340 插好了。"
    Read-Host "按回车退出"
    exit 1
}

$target = Find-Ch340Port $all
if (-not $target) {
    if ($all.Count -eq 1) {
        $target = $all[0]
    } else {
        Write-Host "可用串口: $($all -join ', ')"
        $target = (Read-Host "请输入端口号，例如 COM4").Trim().ToUpper()
        if ($target -match "^\d+$") { $target = "COM$target" }
    }
}

Write-Host "监听 $target   115200-8-N-1"
Write-Host "按 Ctrl+C 退出"
Write-Host "------------------------------------------------------"

$port = New-Object System.IO.Ports.SerialPort
$port.PortName    = $target
$port.BaudRate    = 115200
$port.Parity      = [System.IO.Ports.Parity]::None
$port.DataBits    = 8
$port.StopBits    = [System.IO.Ports.StopBits]::One
$port.Handshake   = [System.IO.Ports.Handshake]::None
$port.ReadTimeout = 1000
$port.DtrEnable   = $false
$port.RtsEnable   = $false

try {
    $port.Open()
} catch {
    Write-Host "[X] 打开 $target 失败: $($_.Exception.Message)"
    Write-Host "    端口可能被 uart_tune.bat 或其它串口工具占用，先关掉它们。"
    Read-Host "按回车退出"
    exit 1
}

try {
    while ($true) {
        try {
            if ($port.IsOpen) {
                $s = $port.ReadExisting()
                if ($s -and $s.Length -gt 0) {
                    Write-Host -NoNewline $s
                }
            } else {
                Write-Host ""
                Write-Host "[!] 端口已断开，正在重连..."
                $port.Dispose()
                Start-Sleep -Milliseconds 500
                $port = New-Object System.IO.Ports.SerialPort
                $port.PortName    = $target
                $port.BaudRate    = 115200
                $port.Parity      = [System.IO.Ports.Parity]::None
                $port.DataBits    = 8
                $port.StopBits    = [System.IO.Ports.StopBits]::One
                $port.Handshake   = [System.IO.Ports.Handshake]::None
                $port.ReadTimeout = 1000
                $port.DtrEnable   = $false
                $port.RtsEnable   = $false
                try { $port.Open(); Write-Host "[OK] 已重连" } catch { Write-Host "[X] 重连失败，请拔插 USB" }
            }
        } catch {
            Write-Host ""
            Write-Host "[!] 读取异常: $($_.Exception.Message)"
            Start-Sleep -Milliseconds 300
        }
        Start-Sleep -Milliseconds 20
    }
} finally {
    try { $port.Dispose() } catch { }
}
