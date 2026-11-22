"""启动隔离验收程序，并在宿主退出后验证 MPV 继续播放、Seek 与 IPC。"""
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
import os
from pathlib import Path
import subprocess
import time
from embedded_mpv_probe import k, u


def activate_test_window(hwnd, pid):
    u.GetForegroundWindow.restype = w.HWND
    u.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
    u.GetAncestor.argtypes = [w.HWND, w.UINT]
    u.GetAncestor.restype = w.HWND
    u.WindowFromPoint.argtypes = [w.POINT]
    u.WindowFromPoint.restype = w.HWND
    u.SetWindowPos.argtypes = [w.HWND, w.HWND, c.c_int, c.c_int, c.c_int, c.c_int, w.UINT]
    u.GetWindowRect.argtypes = [w.HWND, c.POINTER(w.RECT)]
    u.mouse_event.argtypes = [w.DWORD, w.DWORD, w.DWORD, w.DWORD, c.c_size_t]
    owner = w.DWORD()
    u.GetWindowThreadProcessId(hwnd, c.byref(owner))
    if owner.value != pid:
        raise RuntimeError('Keyboard test window does not belong to the host')
    if u.GetForegroundWindow() == hwnd:
        return
    # 只有命中本次验收窗口时才发送激活点击。
    bounds = w.RECT()
    cursor = w.POINT()
    flags = 0x13  # SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
    if not u.GetCursorPos(c.byref(cursor)):
        raise c.WinError(c.get_last_error())
    try:
        u.SetWindowPos(hwnd, -1, 0, 0, 0, 0, flags)
        if not u.GetWindowRect(hwnd, c.byref(bounds)):
            raise c.WinError(c.get_last_error())
        point = w.POINT((bounds.left + bounds.right) // 2,
                        (bounds.top + bounds.bottom) // 2)
        if u.GetAncestor(u.WindowFromPoint(point), 2) != hwnd:
            raise RuntimeError('Keyboard test window is covered')
        if not u.SetCursorPos(point.x, point.y):
            raise c.WinError(c.get_last_error())
        u.mouse_event(0x0002, 0, 0, 0, 0)
        u.mouse_event(0x0004, 0, 0, 0, 0)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and u.GetForegroundWindow() != hwnd:
            time.sleep(.02)
    finally:
        u.SetCursorPos(cursor.x, cursor.y)
        u.SetWindowPos(hwnd, -2, 0, 0, 0, 0, flags)

parser = argparse.ArgumentParser()
parser.add_argument('--app', required=True)
parser.add_argument('--mpv', required=True)
parser.add_argument('--media', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
output = Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=True)
# 保留命令名，以覆盖默认 mpv 的 PATH 解析。
env = dict(os.environ, STREAMPATH_PATH_MPV=args.mpv,
    STREAMPATH_EMBED_ACCEPTANCE_DIR=str(output),
    STREAMPATH_EMBED_ACCEPTANCE_MEDIA=str(Path(args.media).resolve()))
with (output/'stdout.log').open('w') as stdout, (output/'stderr.log').open('w') as stderr:
    keyboard_window = output / 'keyboard-window.txt'
    keyboard_window.unlink(missing_ok=True)
    app = subprocess.Popen([str(Path(args.app).resolve())], env=env,
        stdout=stdout, stderr=stderr, creationflags=subprocess.CREATE_NO_WINDOW)
    deadline = time.monotonic() + 40
    while app.poll() is None and time.monotonic() < deadline:
        if keyboard_window.exists():
            hwnd = keyboard_window.read_text(encoding='utf-8')
            if hwnd.endswith('\n'):
                activate_test_window(int(hwnd), app.pid)
                break
        time.sleep(.05)
    app.wait(timeout=90)
result = json.loads((output/'result.json').read_text(encoding='utf-8'))
handle = None
pending = b''
def request(command):
    global pending
    payload = json.dumps({'command': command, 'request_id': 1}).encode()+b'\n'
    count = w.DWORD()
    if not k.WriteFile(handle,payload,len(payload),c.byref(count),None):
        raise OSError('Detached MPV write failed')
    deadline = time.monotonic()+5
    while time.monotonic()<deadline:
        while b'\n' in pending:
            line,pending = pending.split(b'\n',1)
            response = json.loads(line)
            if response.get('request_id') == 1:
                if response.get('error') != 'success': raise RuntimeError(response)
                return response.get('data')
        available = w.DWORD()
        if not k.PeekNamedPipe(handle,None,0,None,c.byref(available),None):
            raise OSError('Detached MPV pipe closed')
        if available.value:
            buf = c.create_string_buffer(available.value)
            if not k.ReadFile(handle,buf,len(buf),c.byref(count),None): raise OSError('ReadFile failed')
            pending += buf.raw[:count.value]
        else: time.sleep(.01)
    raise TimeoutError(command)
try:
    handle = k.CreateFileW(result['pipe'],0xC0000000,0,None,3,0,None)
    if handle == c.c_void_p(-1).value: raise OSError('MPV did not survive host exit')
    owner = w.ULONG()
    k.GetNamedPipeServerProcessId.argtypes = [w.HANDLE,c.POINTER(w.ULONG)]
    if not k.GetNamedPipeServerProcessId(handle,c.byref(owner)) or owner.value != result['same_pid']:
        raise RuntimeError('Detached MPV process identity mismatch')
    if not result.get('passed'): raise RuntimeError('Native acceptance failed')
    result['host_exit_code'] = app.returncode
    result['survived_host_exit'] = True
    request(['set_property','pause',False])
    request(['seek',10,'absolute+exact'])
    time.sleep(.6)
    position = request(['get_property','time-pos'])
    if not 10 <= position < 13: raise RuntimeError('Detached Seek position mismatch')
    result['seek_after_host_exit'] = position
    result['passed'] = True
except Exception as error:
    result['passed'] = False
    result['driver_error'] = str(error)
finally:
    if handle and handle != c.c_void_p(-1).value:
        try: request(['quit'])
        except (OSError,RuntimeError,TimeoutError): pass
        k.CloseHandle(handle)
    (output/'final-result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result,indent=2))
raise SystemExit(0 if result['passed'] else 1)
