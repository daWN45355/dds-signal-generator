# ============================================================
# uart_tune.ps1 —— EBAZ4205 双通道 DDS 上位机在线调参
#
# 配合 4_uart_tune.bit 使用。
# 接线：CH340 TXD -> D18 / CH340 RXD -> D20 / GND -> GND
#       模块电源脚一律不接
#
# 双击 uart_tune.bat 即可运行。
# v3：串口断线自动重连 + 自动跟随设备重枚举后的新端口号
# ============================================================

$ErrorActionPreference = "Continue"
$OutputEncoding = [System.Text.Encoding]::GetEncoding("GBK")

Write-Host ""
Write-Host "======================================================"
Write-Host "  EBAZ4205  双通道 DDS  上位机在线调参"
Write-Host "======================================================"
Write-Host ""

# ---------- 0. 工具函数 ----------

function Find-Ch340Port([string[]]$present) {
    $cands = New-Object System.Collections.ArrayList

    # 方法 1：注册表 Enum\USB（最稳，不依赖 WMI / PnP 服务）
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

    # 方法 2：PnP 友好名兜底
    if ($cands.Count -eq 0) {
        try {
            foreach ($d in (Get-PnpDevice -Class Ports -PresentOnly -ErrorAction Stop)) {
                if (($d.FriendlyName -match "CH34") -or ($d.FriendlyName -match "USB-SERIAL") -or ($d.FriendlyName -match "USB 串行")) {
                    if ($d.FriendlyName -match "(COM\d+)") { [void]$cands.Add($matches[1]) }
                }
            }
        } catch { }
    }

    # 方法 3：WMI 兜底
    if ($cands.Count -eq 0) {
        try {
            foreach ($d in (Get-WmiObject Win32_PnPEntity -ErrorAction Stop)) {
                if (($d.DeviceID -like "*VID_1A86*") -and ($d.Name -match "(COM\d+)")) {
                    [void]$cands.Add($matches[1])
                }
            }
        } catch { }
    }

    foreach ($c in $cands) { if ($present -contains $c) { return $c } }
    return $null
}

function Get-PortList {
    try { return @([System.IO.Ports.SerialPort]::GetPortNames()) } catch { return @() }
}

function Open-Port([string]$name) {
    $sp = New-Object System.IO.Ports.SerialPort
    $sp.PortName    = $name
    $sp.BaudRate    = 115200
    $sp.Parity      = [System.IO.Ports.Parity]::None
    $sp.DataBits    = 8
    $sp.StopBits    = [System.IO.Ports.StopBits]::One
    $sp.Handshake   = [System.IO.Ports.Handshake]::None
    $sp.ReadTimeout = 1500
    $sp.DtrEnable   = $false
    $sp.RtsEnable   = $false
    $sp.Open()
    return $sp
}

function Ensure-Port {
    if ($script:port -ne $null) {
        try { if ($script:port.IsOpen) { return $true } } catch { }
    }

    # 先释放旧句柄，否则重开可能报"拒绝访问"
    try { if ($script:port -ne $null) { $script:port.Dispose() } } catch { }
    $script:port = $null

    # 端口号可能被 Windows 重枚举变了（COM4 -> COM5），先试原名再重新探测
    $tryList = @($script:portName)
    $now = Get-PortList
    if ($now -notcontains $script:portName) {
        $newOne = Find-Ch340Port $now
        if ($newOne) { $tryList += $newOne }
    }

    foreach ($name in $tryList) {
        try {
            $script:port = Open-Port $name
            $script:portName = $name
            Write-Host "  [重连] 串口 $name 已重新打开"
            return $true
        } catch { }
    }

    Write-Host "  [X] 串口断开，且重连失败。"
    Write-Host "      当前可用端口: $(if ($now.Count) { $now -join ', ' } else { '（无）' })"
    Write-Host "      处理办法: 拔插一次 CH340 的 USB 线，然后按 7 重新选串口"
    return $false
}

# ---------- 1. 找串口 ----------
$all = Get-PortList

if ($all.Count -eq 0) {
    Write-Host "[X] 没有找到任何串口。"
    Write-Host ""
    Write-Host "  排查："
    Write-Host "    1) CH340 是否已经插进电脑（并换一个 USB 口试试）"
    Write-Host "    2) 设备管理器里是否出现 'USB-SERIAL CH340 (COMx)'"
    Write-Host "    3) 驱动是否装好（黄色感叹号 = 没装驱动）"
    Write-Host ""
    Read-Host "按回车退出"
    exit 1
}

$target = Find-Ch340Port $all

if ($target) {
    Write-Host "自动识别 CH340: $target"
} elseif ($all.Count -eq 1) {
    $target = $all[0]
    Write-Host "本机只有 $target 一个串口，直接使用（未能确认芯片型号）"
} else {
    Write-Host "检测到的串口: $($all -join ', ')"
    Write-Host "（没自动认出 CH340，可能驱动报告的硬件 ID 不是 1A86）"
    $target = (Read-Host "请输入端口号，例如 COM4").Trim().ToUpper()
    if ($target -match "^\d+$") { $target = "COM$target" }
}

if (-not $target) {
    Write-Host "[X] 没有指定端口，退出。"
    Read-Host "按回车退出"
    exit 1
}

if ($all -notcontains $target) {
    Write-Host "[!] 警告：$target 不在当前端口列表里（$($all -join ', ')），仍尝试打开。"
}

# ---------- 2. 打开串口 ----------
$script:portName = $target
$script:port = $null

try {
    $script:port = Open-Port $target
} catch {
    Write-Host ""
    Write-Host "[X] 打开 $target 失败: $($_.Exception.Message)"
    Write-Host "    常见原因：端口被别的程序占用（串口助手 / Arduino IDE / MobaXterm）"
    Read-Host "按回车退出"
    exit 1
}

Write-Host "已打开 $target   115200-8-N-1"
Write-Host ""

# ---------- 3. 发送命令 ----------
function Send-Cmd([string]$cmd) {
    if (-not (Ensure-Port)) { return $null }

    try {
        $script:port.DiscardInBuffer()
        $script:port.Write($cmd + [char]13)
        Start-Sleep -Milliseconds 300
        return ($script:port.ReadExisting()).Trim()
    } catch {
        Write-Host "  [!] 发送出错: $($_.Exception.Message)"
        Write-Host "      尝试重连后重发一次..."
        try { $script:port.Dispose() } catch { }
        $script:port = $null
        if (-not (Ensure-Port)) { return $null }
        try {
            $script:port.Write($cmd + [char]13)
            Start-Sleep -Milliseconds 300
            return ($script:port.ReadExisting()).Trim()
        } catch {
            Write-Host "  [X] 重发仍失败，请拔插 CH340 的 USB 线"
            return $null
        }
    }
}

Write-Host "正在握手（发送 ? ）..."
$hello = Send-Cmd "?"
if ($null -eq $hello) {
    Write-Host "[X] 握手发送失败，串口不通。先处理串口，再继续。"
} elseif ($hello) {
    Write-Host "设备回答: $hello"
    Write-Host "握手成功。"
} else {
    Write-Host ""
    Write-Host "[!] 发 '?' 没有回答。请逐条确认："
    Write-Host "    1) 烧的是 4_uart_tune.bit（不是 3 号或 5 号）"
    Write-Host "    2) 接线是否交叉：模块 TXD -> D18，模块 RXD -> D20"
    Write-Host "    3) GND 是否共地（最容易漏）"
    Write-Host "    4) 烧完 bit 后是否拔掉了 JTAG 线"
    Write-Host "    5) DONE 灯是否亮"
    Write-Host ""
    Write-Host "    仍可继续手动发指令测试。"
}
Write-Host ""

# ---------- 4. 交互菜单 ----------
while ($true) {
    $stateText = "已断开"
    try { if ($script:port -ne $null -and $script:port.IsOpen) { $stateText = "在线" } } catch { }
    Write-Host "------------------------------------------------------"
    Write-Host "  [$($script:portName)  $stateText]"
    Write-Host "  1  查询当前参数"
    Write-Host "  2  设置频率     (1 ~ 20000 Hz)"
    Write-Host "  3  设置相位差   (0 ~ 359 度)"
    Write-Host "  4  设置波形     (0正弦 1方波 2三角 3锯齿 4自动切换)"
    Write-Host "  5  设置幅度     (1 ~ 100 %)"
    Write-Host "  6  直接发送指令 (如 F5000 / P90 / W2 / A50 / D1 / ?)"
    Write-Host "  7  重新选择串口"
    Write-Host "  8  切换加/减方向 (0加 1减)"
    Write-Host "  9  连续回传开关 (1开 0关，每秒刷一行)"
    Write-Host "  q  退出"
    Write-Host ""

    $sel = (Read-Host "请选择").Trim()

    if ($sel -eq "q" -or $sel -eq "Q") { break }

    $cmd = $null

    switch ($sel) {
        "7" {
            $now = Get-PortList
            Write-Host "  当前可用端口: $(if ($now.Count) { $now -join ', ' } else { '（无）' })"
            $nv = (Read-Host "  输入新端口号，例如 COM5（直接回车取消）").Trim().ToUpper()
            if ($nv -match "^\d+$") { $nv = "COM$nv" }
            if ($nv) {
                try { if ($script:port -ne $null) { $script:port.Dispose() } } catch { }
                $script:port = $null
                $script:portName = $nv
                if (Ensure-Port) { } else { Write-Host "  [X] 仍打不开 $nv" }
            }
            Write-Host ""
            continue
        }
        "1" { $cmd = "?" }
        "2" {
            $v = (Read-Host "频率 Hz (1-20000)").Trim()
            if ($v -match "^\d+$" -and [int]$v -ge 1 -and [int]$v -le 20000) { $cmd = "F$v" }
            else { Write-Host "[!] 输入不合法，已忽略"; continue }
        }
        "3" {
            $v = (Read-Host "相位差 度 (0-359)").Trim()
            if ($v -match "^\d+$" -and [int]$v -ge 0 -and [int]$v -le 359) { $cmd = "P$v" }
            else { Write-Host "[!] 输入不合法，已忽略"; continue }
        }
        "4" {
            $v = (Read-Host "波形 0-4").Trim()
            if ($v -match "^[0-4]$") { $cmd = "W$v" }
            else { Write-Host "[!] 输入不合法，已忽略"; continue }
        }
        "5" {
            $v = (Read-Host "幅度 % (1-100)").Trim()
            if ($v -match "^\d+$" -and [int]$v -ge 1 -and [int]$v -le 100) { $cmd = "A$v" }
            else { Write-Host "[!] 输入不合法，已忽略"; continue }
        }
        "8" {
            $v = (Read-Host "方向 0=加 1=减").Trim()
            if ($v -match "^[01]$") { $cmd = "D$v" }
            else { Write-Host "[!] 输入不合法，已忽略"; continue }
        }
        "9" {
            $v = (Read-Host "连续回传 1开 0关").Trim()
            if ($v -match "^[01]$") { $cmd = "S$v" }
            else { Write-Host "[!] 输入不合法，已忽略"; continue }
        }
        "6" {
            $cmd = (Read-Host "输入指令").Trim()
        }
        default {
            if ($sel -match "^[A-Za-z?]") { $cmd = $sel }
            else { Write-Host "[!] 无法识别，请输入菜单编号"; continue }
        }
    }

    if (-not $cmd) { continue }

    Write-Host "  -> 发送: $cmd"
    $resp = Send-Cmd $cmd
    if ($null -eq $resp) {
        Write-Host "  <- 发送失败（串口问题，见上方提示）"
    } elseif ($resp) {
        Write-Host "  <- 回答: $resp"
    } else {
        Write-Host "  <- (无回答，板子没收到或被占用)"
    }
    Write-Host ""
}

try { if ($script:port -ne $null) { $script:port.Dispose() } } catch { }
Write-Host ""
Write-Host "串口已关闭。"
