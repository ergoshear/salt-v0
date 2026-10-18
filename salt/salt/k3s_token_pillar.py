#!/usr/bin/python3
import json
from pathlib import Path


TOKEN_FILE = Path(
    "/var/cache/salt/master/minions/"
    "k3s-control-plane-01/files/k3s-control-plane-01/k3s-token"
)

try:
    token = TOKEN_FILE.read_text(encoding="utf-8").strip()
except FileNotFoundError:
    token = ""

print(json.dumps({"K3S_TOKEN": token} if token else {}))
