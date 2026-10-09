import json
import select
import socket
import socketserver
import sys
import threading
import time

hold = threading.Event()
held = threading.Event()


class Proxy(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class Forward(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5) as upstream:
                upstream.settimeout(None)
                while True:
                    readable, _, _ = select.select([self.request, upstream], [], [], 1)
                    for stream in readable:
                        data = stream.recv(65536)
                        if not data:
                            return
                        if stream is upstream and hold.is_set():
                            if not held.is_set():
                                held.set()
                                print(json.dumps({'event': 'held'}), flush=True)
                            while hold.is_set():
                                time.sleep(0.01)
                        (self.request if stream is upstream else upstream).sendall(data)
        except OSError:
            # 客户端关闭会话后结束此测试连接。
            return


with Proxy(('127.0.0.1', 0), Forward) as proxy:
    threading.Thread(target=proxy.serve_forever, daemon=True).start()
    print(json.dumps({'port': proxy.server_address[1]}), flush=True)
    for line in sys.stdin:
        command = line.strip()
        if command == 'hold':
            held.clear()
            hold.set()
            print(json.dumps({'event': 'armed'}), flush=True)
        elif command == 'release':
            hold.clear()
        elif command == 'quit':
            hold.clear()
            break
    proxy.shutdown()
