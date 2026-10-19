import json
from pathlib import Path


TOKEN_FILE = Path(
    "/var/cache/salt/master/minions/"
    "k3s-control-plane-01/files/k3s-control-plane-01/k3s-token"
)


def token_pillar():
    try:
        token = TOKEN_FILE.read_text().strip()
    except FileNotFoundError:
        token = ""
    return {"K3S_TOKEN": token} if token else {}


if __name__ == "__main__":
    print(json.dumps(token_pillar()))
