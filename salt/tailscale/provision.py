#!/usr/bin/python3
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen


DIRECTORY = Path("/etc/salt/tailscale")
TAILNET = "tailb11f97.ts.net"
CLUSTER = {"k3s-control-plane-01", "mlops-node-0", "mlops-node-1"}
GRANT = {
    "src": ["tag:k8s"],
    "dst": ["tag:k8s"],
    "ip": ["tcp:6443", "tcp:10250", "udp:8472"],
}


def api(key, path, payload=None, method=None, headers=None):
    auth = base64.b64encode((key + ":").encode()).decode()
    request = Request(
        "https://api.tailscale.com/api/v2/tailnet/" + TAILNET + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        method=method,
        headers={
            "Authorization": "Basic " + auth,
            "Accept": "application/json",
            "Content-Type": "application/json",
            **(headers or {}),
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            return json.load(response), response.headers
    except HTTPError as error:
        raise RuntimeError(f"Tailscale API {request.method} {path}: HTTP {error.code}") from None


def merge_policy(policy):
    owners = policy.setdefault("tagOwners", {})
    owners.setdefault("tag:salt-managed", ["autogroup:admin"])
    owners.setdefault("tag:k8s", ["autogroup:admin"])
    grants = policy.setdefault("grants", [])
    if GRANT not in grants:
        grants.append(GRANT)
    return policy


def provision():
    os.umask(0o077)
    DIRECTORY.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (DIRECTORY / "provision.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        key = (DIRECTORY / "api-key").read_text().strip()
        if not key:
            raise ValueError("TS_API_KEY is empty")
        policy, headers = api(key, "/acl")
        original = json.dumps(policy, sort_keys=True)
        merge_policy(policy)
        if json.dumps(policy, sort_keys=True) != original:
            etag = headers.get("ETag")
            if not etag:
                raise RuntimeError("Tailscale policy response has no ETag; refusing unsafe update")
            backup = DIRECTORY / "policy-before-salt.json"
            if not backup.exists():
                backup.write_text(original + "\n")
            api(key, "/acl", policy, "POST", {"If-Match": etag})
            print("Added Salt tag ownership and Kubernetes grants; existing rules preserved")
        accepted = json.loads(subprocess.check_output(
            ["salt-key", "--out=json", "--list=accepted"], text=True
        ))["minions"]
        for node in sorted(set(accepted) | {"salt-master-01"}):
            cache = DIRECTORY / (hashlib.sha256(node.encode()).hexdigest() + ".json")
            if cache.exists() and json.loads(cache.read_text())["expires"] > time.time() + 600:
                continue
            tags = ["tag:salt-managed"]
            if node in CLUSTER:
                tags.append("tag:k8s")
            result, _ = api(key, "/keys", {
                "capabilities": {"devices": {"create": {
                    "reusable": True, "ephemeral": False,
                    "preauthorized": True, "tags": tags,
                }}},
                "expirySeconds": 3600,
                "description": "Salt enrollment: " + node,
            })
            secret = result["key"]
            if not secret.startswith("tskey-auth-"):
                raise ValueError("Tailscale API returned an invalid enrollment key")
            temporary = cache.with_suffix(".tmp")
            temporary.write_text(json.dumps({"key": secret, "expires": time.time() + 3500}))
            temporary.replace(cache)
        print(f"Tailscale enrollment keys ready for {len(set(accepted) | {'salt-master-01'})} minions")


if __name__ == "__main__":
    provision()
