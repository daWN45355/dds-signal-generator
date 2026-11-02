# -*- coding: utf-8 -*-
"""
dds_monitor.py —— 波形实时监测与调控控制台（网页版上位机）
适配固件：7_key_dds（dds_key_top，2026/10/27 版）
浏览器打开 http://localhost:8000

架构：浏览器(图表+滑块) ↔ 本地 HTTP 服务(本文件) ↔ CH340 串口 ↔ FPGA UART
串口未接时自动进入"模拟模式"：界面全部可用，命令仅记录不下发。

协议（源自 dds_key_top 固件，115200-8-N-1，命令以回车 \r 结尾）：
  F<hz>    频率 1~20000 Hz          例 F1000
  P<deg>   相位差 0~359 度          例 P90
  W<n>     波形 0正弦 1方波 2三角 3锯齿 4自动轮换   例 W4
  A<pct>   幅度 1~100 %             例 A100
  D0/D1    按键加/减方向（D1=减，见对话菜单 8）
  ?        查询，回一行 F=01000 P=090 W=4 A=100 D=+ K=0000
"""
import json
import os
import re
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import serial
import serial.tools.list_ports

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 8000
WAVE_NAMES = ['正弦', '方波', '三角', '锯齿', '自动轮换']

STATE = {
    # 板子状态（由 '?' 回传行刷新，连接后每秒轮询一次）
    'board': {'F': 1000, 'P': 90, 'W': 4, 'A': 100, 'D': '+',
              'K': '0000', 'raw': '', 'online': False, 't': 0},
    'serial': {'port': None, 'connected': False, 'error': None},
}
LOG = []      # [{t, cmd}]
HIST = []     # [{t, f}]  频率历史
DATA = []     # [{t, v1, v2?}] ← 上行数据环形缓冲（板 → CH340 → 网页）
LOCK = threading.Lock()
MAX_DATA = 2400

SER = None
SER_LOCK = threading.Lock()
RX_STATS = {'bytes': 0, 'lines': 0, 'last_line': ''}


def log_cmd(text):
    with LOCK:
        LOG.append({'t': time.strftime('%H:%M:%S'), 'cmd': text})
        del LOG[:-120]


def push_history(f):
    with LOCK:
        HIST.append({'t': round(time.time(), 2), 'f': f})
        del HIST[:-180]


def _parse_status(line):
    """解析 '?' 回传行：F=01000 P=090 W=4 A=100 D=+ K=0000"""
    m = re.search(
        r'F=(\d+)\s+P=(\d+)\s+W=(\d+)\s+A=(\d+)\s+D=([+\-])\s+K=([01]{4})', line)
    if not m:
        return None
    return {'F': int(m.group(1)), 'P': int(m.group(2)), 'W': int(m.group(3)),
            'A': int(m.group(4)), 'D': m.group(5), 'K': m.group(6)}


def _parse_data_line(line):
    """解析上行数据行 'D,<v1>[,<v2>]'（兼容 D:3.3 / 1024,2048 / D3.3 粘连形式）"""
    nums = []
    for p in line.replace(':', ',').split(','):
        p = p.strip()
        if not p or re.fullmatch(r'[A-Za-z]+', p):
            continue
        m = re.match(r'^[A-Za-z]*\s*(-?\d+(?:\.\d+)?)$', p)
        if not m:
            return None
        nums.append(float(m.group(1)))
    if not nums:
        return None
    return {'t': round(time.time(), 3), 'v1': nums[0],
            'v2': nums[1] if len(nums) > 1 else None}


def serial_connect(port):
    global SER
    with SER_LOCK:
        try:
            if SER:
                SER.close()
            SER = serial.Serial(port, 115200, timeout=0.1)
            STATE['serial'] = {'port': port, 'connected': True, 'error': None}
            log_cmd('SYS 串口已连接 ' + port)
            return True
        except Exception as e:
            STATE['serial'] = {'port': port, 'connected': False, 'error': str(e)}
            log_cmd('SYS 串口连接失败 ' + port)
            return False


def serial_disconnect():
    global SER
    with SER_LOCK:
        try:
            if SER:
                SER.close()
        except Exception:
            pass
        SER = None
        STATE['serial'] = {'port': None, 'connected': False, 'error': None}
        STATE['board']['online'] = False
        log_cmd('SYS 串口已断开')


def serial_send(cmd):
    global SER
    with SER_LOCK:
        if SER and STATE['serial']['connected']:
            try:
                SER.write((cmd + '\r').encode('ascii'))   # 本固件命令以 \r 结尾
                return True
            except Exception:
                # Windows USB 选择性暂停会把 COM 口挂起（对话中已记录此坑）→ 尝试重开后重发
                try:
                    port = STATE['serial'].get('port')
                    if port and SER:
                        SER.close()
                    new = serial.Serial(port, 115200, timeout=0.1)
                    SER = new
                    STATE['serial']['connected'] = True
                    STATE['serial']['error'] = None
                    log_cmd('SYS 串口断线自动重连成功 ' + port)
                    new.write((cmd + '\r').encode('ascii'))
                    return True
                except Exception as e:
                    STATE['serial']['connected'] = False
                    STATE['serial']['error'] = str(e)
                    log_cmd('SYS 串口发送失败（重连也未成功）：' + str(e))
                    return False
    return False


def serial_reader():
    """接收线程：板 → CH340 → 解析。状态行刷新 STATE['board']，数据行进 DATA"""
    global SER
    buf = b''
    while True:
        ser = SER
        if not (ser and STATE['serial']['connected']):
            time.sleep(0.1)
            continue
        try:
            chunk = ser.read(256)
            if not chunk:
                continue
            RX_STATS['bytes'] += len(chunk)
            buf += chunk
            while True:
                sep = None
                for s in (b'\n', b'\r'):
                    if s in buf:
                        sep = s
                        break
                if sep is None:
                    break
                raw, buf = buf.split(sep, 1)
                line = raw.decode('ascii', errors='ignore').strip()
                if not line:
                    continue
                RX_STATS['lines'] += 1
                RX_STATS['last_line'] = line[:60]
                st = _parse_status(line)
                if st:
                    with LOCK:
                        old_f = STATE['board']['F']
                        STATE['board'].update(st)
                        STATE['board']['raw'] = line
                        STATE['board']['online'] = True
                        STATE['board']['t'] = round(time.time(), 2)
                    if st['F'] != old_f:
                        push_history(st['F'])
                else:
                    parsed = _parse_data_line(line)
                    if parsed:
                        with LOCK:
                            DATA.append(parsed)
                            del DATA[:-MAX_DATA]
                    else:
                        log_cmd('RX  ' + line[:60])
        except Exception as e:
            STATE['serial'] = {'port': STATE['serial'].get('port'),
                               'connected': False, 'error': str(e)}
            STATE['board']['online'] = False
            log_cmd('SYS 串口接收异常，2 秒后尝试重连：' + str(e))
            time.sleep(2.0)
            port = STATE['serial'].get('port')
            if port:
                try:
                    with SER_LOCK:
                        if SER:
                            SER.close()
                        SER = serial.Serial(port, 115200, timeout=0.1)
                        STATE['serial']['connected'] = True
                        STATE['serial']['error'] = None
                        log_cmd('SYS 串口自动重连成功 ' + port)
                except Exception as e2:
                    log_cmd('SYS 自动重连失败：' + str(e2))
                    time.sleep(2.0)


def status_poller():
    """每 250ms 发一次 ?（串口带宽充裕：~160B/s ≪ 11.5KB/s），参数回读延迟 ≤0.55s"""
    while True:
        if STATE['serial']['connected']:
            serial_send('?')
        time.sleep(0.25)


def apply_param(key, value):
    """参数变更 → 组装 UART 指令下发（固件侧原子生效，无毛刺）"""
    ok = False
    if key == 'freq':
        v = max(1, min(20000, int(value)))
        ok = serial_send(f'F{v}')
        if ok:
            push_history(v)
    elif key == 'phase':
        v = max(0, min(359, int(value)))
        ok = serial_send(f'P{v}')
    elif key == 'wave':
        v = max(0, min(4, int(value)))
        ok = serial_send(f'W{v}')
    elif key == 'amp':
        v = max(1, min(100, int(value)))
        ok = serial_send(f'A{v}')
    elif key == 'dir':
        v = 1 if value in (1, '-', 'minus') else 0
        ok = serial_send(f'D{v}')
    elif key == 'resync':
        # 重写一次 W4：若固件在模式写入时复位轮换计数器，则网页时钟可与之对齐。
        # 注意：此同步依赖固件行为，若复位不会发生则仅能拉近（页面上有标注）。
        ok = serial_send('W4')
    elif key == 'demo':
        for c in ('D0', 'F1000', 'P90', 'W4', 'A100'):
            serial_send(c)
            time.sleep(0.15)
        ok = True
    log_cmd(f'SET {key} = {value}')
    return ok


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype='application/json'):
        data = body.encode('utf-8') if isinstance(body, str) else body
        self.send_response(code)
        self.send_header('Content-Type', ctype + '; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path in ('/', '/index.html'):
            with open(os.path.join(HERE, 'index.html'), 'rb') as f:
                self._send(200, f.read(), 'text/html')
        elif self.path == '/api/state':
            with LOCK:
                snap = {'state': STATE, 'log': LOG[-40:], 'hist': HIST[-180:]}
            self._send(200, json.dumps(snap, ensure_ascii=False))
        elif self.path == '/api/ports':
            ports = [{'device': p.device, 'desc': p.description}
                     for p in serial.tools.list_ports.comports()]
            self._send(200, json.dumps(ports, ensure_ascii=False))
        elif self.path == '/api/data':
            with LOCK:
                snap = {'data': DATA[-1200:], 'stats': RX_STATS}
            self._send(200, json.dumps(snap, ensure_ascii=False))
        else:
            self._send(404, '{"error":"not found"}')

    def do_POST(self):
        if self.path == '/api/set':
            try:
                n = int(self.headers.get('Content-Length', 0))
                req = json.loads(self.rfile.read(n).decode('utf-8'))
                ok = apply_param(req['param'], req['value'])
                self._send(200, json.dumps({'ok': ok}))
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path == '/api/serial':
            try:
                n = int(self.headers.get('Content-Length', 0))
                req = json.loads(self.rfile.read(n).decode('utf-8'))
                ok = serial_connect(req['port']) if req.get('action') == 'connect' \
                    else serial_disconnect()
                self._send(200, json.dumps({'ok': ok, 'serial': STATE['serial']}))
            except Exception as e:
                self._send(400, json.dumps({'ok': False, 'error': str(e)}))
        elif self.path == '/api/dataclear':
            with LOCK:
                del DATA[:]
            self._send(200, '{"ok":true}')
        else:
            self._send(404, '{"error":"not found"}')


def main():
    server = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Thread(target=serial_reader, daemon=True).start()
    threading.Thread(target=status_poller, daemon=True).start()
    print('波形监测与调控控制台已启动: http://localhost:%d' % PORT)
    print('关闭本窗口或 Ctrl+C 停止')
    webbrowser.open('http://localhost:%d' % PORT)
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print('已停止')


if __name__ == '__main__':
    main()
