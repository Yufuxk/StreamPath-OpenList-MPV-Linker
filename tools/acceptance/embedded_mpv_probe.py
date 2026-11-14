"""隔离验证真实 MPV 的 HWND、输入与动态脱嵌；不加载用户配置。"""
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
from pathlib import Path
import subprocess
import threading
import time
import uuid

u = c.WinDLL('user32', use_last_error=True)
k = c.WinDLL('kernel32', use_last_error=True)
u.CreateWindowExW.argtypes = [w.DWORD,w.LPCWSTR,w.LPCWSTR,w.DWORD,c.c_int,c.c_int,c.c_int,c.c_int,w.HWND,w.HMENU,w.HINSTANCE,c.c_void_p]
u.CreateWindowExW.restype = w.HWND
u.GetParent.argtypes = [w.HWND]
u.GetParent.restype = w.HWND
u.GetWindowLongPtrW.argtypes = [w.HWND,c.c_int]
u.GetWindowLongPtrW.restype = c.c_ssize_t
u.EnableWindow.argtypes = [w.HWND,w.BOOL]
u.IsWindowEnabled.argtypes = [w.HWND]
u.SendMessageW.argtypes = [w.HWND,w.UINT,w.WPARAM,w.LPARAM]
u.SendMessageW.restype = w.LPARAM
u.DestroyWindow.argtypes = [w.HWND]
k.CreateFileW.argtypes = [w.LPCWSTR,w.DWORD,w.DWORD,c.c_void_p,w.DWORD,w.DWORD,w.HANDLE]
k.CreateFileW.restype = w.HANDLE
k.PeekNamedPipe.argtypes = [w.HANDLE,c.c_void_p,w.DWORD,c.c_void_p,c.POINTER(w.DWORD),c.c_void_p]
k.ReadFile.argtypes = [w.HANDLE,c.c_void_p,w.DWORD,c.POINTER(w.DWORD),c.c_void_p]
k.WriteFile.argtypes = k.ReadFile.argtypes
k.CloseHandle.argtypes = [w.HANDLE]
u.SetProcessDpiAwarenessContext.argtypes = [c.c_void_p]
u.SetProcessDpiAwarenessContext(c.c_void_p(-4))

def probe(executable, host, directory):
    pipe = r'\\.\pipe\streampath_embed_probe_' + uuid.uuid4().hex
    observer = directory / 'input.lua'
    observer.write_text("mp.add_key_binding('F8', 'probe-key', function() mp.set_property_number('speed', 1.5) end)\nmp.add_key_binding('MBTN_LEFT', 'probe-mouse', function() mp.set_property_number('volume', 37) end)\n", encoding='utf-8')
    process = subprocess.Popen([executable, '--no-config', '--load-scripts=no',
        '--idle=yes', '--force-window=yes', '--ao=null', '--pause=yes',
        '--input-ipc-server=' + pipe, '--wid=' + str(host),
        '--script=' + str(observer), '--log-file=' + str(directory/'mpv.log'),
        'av://lavfi:testsrc2=size=320x180:rate=24'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW)
    handle = None
    pending = b''
    report = {'executable': executable, 'pid': process.pid}
    def request(command):
        nonlocal pending
        payload = json.dumps({'command': command, 'request_id': 1}).encode() + b'\n'
        count = w.DWORD()
        if not k.WriteFile(handle, payload, len(payload), c.byref(count), None):
            raise OSError('WriteFile failed')
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                obj = json.loads(line)
                if obj.get('request_id') == 1:
                    if obj.get('error') != 'success':
                        raise RuntimeError(obj)
                    return obj.get('data')
            available = w.DWORD()
            if not k.PeekNamedPipe(handle,None,0,None,c.byref(available),None):
                raise OSError('Pipe closed')
            if available.value:
                buf = c.create_string_buffer(available.value)
                if not k.ReadFile(handle,buf,len(buf),c.byref(count),None):
                    raise OSError('ReadFile failed')
                pending += buf.raw[:count.value]
            else:
                time.sleep(.01)
        raise TimeoutError(command)
    try:
        deadline = time.monotonic()+8
        while time.monotonic() < deadline:
            candidate = k.CreateFileW(pipe,0xC0000000,0,None,3,0,None)
            if candidate != c.c_void_p(-1).value:
                handle = candidate
                break
            if process.poll() is not None:
                raise RuntimeError('MPV exited: '+str(process.returncode))
            time.sleep(.05)
        if handle is None:
            raise TimeoutError('IPC unavailable')
        report['version'] = request(['get_property','mpv-version'])
        time.sleep(.3)
        window = int(request(['get_property','window-id']))
        report['parent_matches'] = u.GetParent(window) == host
        report['initial_input_enabled'] = bool(u.IsWindowEnabled(window))
        u.EnableWindow(window,True)
        u.SendMessageW(window,0x100,0x77,1)
        u.SendMessageW(window,0x101,0x77,0xC0000001)
        time.sleep(.15)
        report['key_input'] = request(['get_property','speed']) == 1.5
        u.SendMessageW(window,0x201,1,(30 << 16)|30)
        u.SendMessageW(window,0x202,0,(30 << 16)|30)
        time.sleep(.15)
        report['mouse_input'] = request(['get_property','volume']) == 37
        request(['set_property','fullscreen',True])
        time.sleep(.15)
        report['fullscreen_stays_child'] = u.GetParent(window) == host and bool(u.GetWindowLongPtrW(window,-16)&0x40000000)
        request(['set_property','window-minimized',True])
        request(['set_property','wid',-1])
        time.sleep(.4)
        detached = int(request(['get_property','window-id']))
        report['detached'] = not (u.GetWindowLongPtrW(detached,-16)&0x40000000) and u.GetParent(detached) != host
        report['same_process_alive'] = process.poll() is None
        report['passed'] = all(report.get(name) for name in ['parent_matches','key_input','mouse_input','fullscreen_stays_child','detached','same_process_alive'])
    except Exception as error:
        report['error'] = str(error)
        report['passed'] = False
    finally:
        if handle:
            try:
                request(['quit'])
            except (OSError,RuntimeError,TimeoutError):
                pass
            k.CloseHandle(handle)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    return report

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('executable',nargs='+')
    parser.add_argument('--output',required=True)
    args = parser.parse_args()
    output = Path(args.output).resolve()
    output.mkdir(parents=True,exist_ok=True)
    reports = []
    for index, executable in enumerate(args.executable):
        root = u.CreateWindowExW(0,'STATIC','StreamPath isolated probe',0x00CF0000,0,0,640,360,None,None,None,None)
        host = u.CreateWindowExW(0,'STATIC','MPV surface',0x40000000,0,0,640,360,root,None,None,None)
        directory = output/str(index)
        directory.mkdir(exist_ok=True)
        result = []
        worker = threading.Thread(target=lambda: result.append(probe(executable,host,directory)))
        worker.start()
        msg = w.MSG()
        while worker.is_alive():
            while u.PeekMessageW(c.byref(msg),None,0,0,1):
                u.TranslateMessage(c.byref(msg))
                u.DispatchMessageW(c.byref(msg))
            time.sleep(.005)
        worker.join()
        u.DestroyWindow(root)
        reports.extend(result)
    (output/'results.json').write_text(json.dumps(reports,indent=2),encoding='utf-8')
    print(json.dumps(reports,indent=2))
