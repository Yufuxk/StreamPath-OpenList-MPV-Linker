import os
import shutil
import sys
import time


HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
RUNTIME = os.path.join(os.environ.get("TEMP", os.path.expanduser("~")), "sp_accept")
ROOT = os.path.join(PROJECT_ROOT, "stream_path_data", "cache", "iso_temp")
EVIDENCE = os.path.join(RUNTIME, "item7_evidence", sys.argv[1], "live")
os.makedirs(EVIDENCE, exist_ok=True)
deadline = time.time() + 300
captured = set()

# 应在注入前启动；持续镜像每个会话，避免会话清理时抢拷失败。
while time.time() < deadline:
    try:
        sessions = [name for name in os.listdir(ROOT) if name.startswith("iso_")]
    except OSError:
        sessions = []
    for session in sessions:
        source_dir = os.path.join(ROOT, session)
        target_dir = os.path.join(EVIDENCE, session)
        os.makedirs(target_dir, exist_ok=True)
        try:
            files = os.listdir(source_dir)
        except OSError:
            continue
        for filename in files:
            source = os.path.join(source_dir, filename)
            if not os.path.isfile(source):
                continue
            temp = os.path.join(target_dir, filename + ".tmp")
            target = os.path.join(target_dir, filename)
            try:
                shutil.copy2(source, temp)
                os.replace(temp, target)
                captured.add((session, filename))
            except (FileNotFoundError, PermissionError, OSError):
                try:
                    if os.path.exists(temp):
                        os.remove(temp)
                except OSError:
                    pass
    time.sleep(0.2)

print("captured files:", len(captured))
