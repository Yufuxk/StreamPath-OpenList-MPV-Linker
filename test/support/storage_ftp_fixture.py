import json
import logging
import sys

sys.path.insert(0, sys.argv[2])
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer

logging.getLogger("pyftpdlib").setLevel(logging.CRITICAL)
authorizer = DummyAuthorizer()
authorizer.add_user("fixture", "fixture", sys.argv[1], perm="elradfmwMT")
class FixtureFTPHandler(FTPHandler):
    auth_failed_timeout = 0

    def ftp_REST(self, position):
        if len(sys.argv) > 3 and sys.argv[3] == "no-rest":
            self.respond("502 REST is not implemented.")
        else:
            super().ftp_REST(position)

    def ftp_MLSD(self, path):
        mode = sys.argv[3] if len(sys.argv) > 3 else "mlsd"
        if mode == "list":
            self.respond("500 Unknown command.")
        elif mode == "denied":
            self.respond("550 Permission denied.")
        elif mode == "stall":
            print("listing-started", flush=True)
            self.respond("150 Opening data connection.")
        else:
            super().ftp_MLSD(path)


FixtureFTPHandler.authorizer = authorizer
server = FTPServer(("127.0.0.1", 0), FixtureFTPHandler)
print(json.dumps({"port": server.socket.getsockname()[1]}), flush=True)
server.serve_forever()
