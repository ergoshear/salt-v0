import hashlib
import json
from pathlib import Path
import time


TOKEN_FILE = Path(
    "/var/cache/salt/master/minions/"
    "k3s-control-plane-01/files/k3s-control-plane-01/k3s-token"
)
DIRECTORY = Path("/etc/salt/tailscale")


def ext_pillar(minion_id, pillar):
    data = {}
    if TOKEN_FILE.exists():
        token = TOKEN_FILE.read_text().strip()
        if token:
            data["K3S_TOKEN"] = token
    if minion_id == "salt-master-01":
        data["TS_API_KEY"] = (DIRECTORY / "api-key").read_text().strip()
    cache = DIRECTORY / (hashlib.sha256(minion_id.encode()).hexdigest() + ".json")
    if not cache.exists():
        raise RuntimeError("Missing Tailscale enrollment key; apply salt.master first")
    enrollment = json.loads(cache.read_text())
    if enrollment["expires"] <= time.time():
        raise RuntimeError("Tailscale enrollment key expired; apply salt.master")
    data["TAILSCALE_AUTH_KEY"] = enrollment["key"]
    return data
