#!/usr/bin/python3
import base64
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen


DIRECTORY = Path("/etc/salt/tailscale")
TAILNET = "tailb11f97.ts.net"
CLUSTER = {"k3s-control-plane-01", "mlops-node-0", "mlops-node-1", "mlops-node-5"}
WORKERS = CLUSTER - {"k3s-control-plane-01"}
INFERENCE_NODE = "mlops-node-3"
INFERENCE_HOST_ALIASES = {
    4: "mlops-node-3-studioflow-v4",
    6: "mlops-node-3-studioflow-v6",
}
INFERENCE_PORTS = ["tcp:8001", "tcp:8002", "tcp:8003"]
GRANT = {
    "src": ["tag:k8s"],
    "dst": ["tag:k8s"],
    "ip": ["tcp:6443", "tcp:10250", "udp:8472"],
}
SSH_RULE = {
    "action": "check",
    "src": ["christopher@agilityqa.com"],
    "dst": ["tag:salt-managed"],
    "users": ["autogroup:nonroot"],
}
TOKEN_FILE = Path(
    "/var/cache/salt/master/minions/"
    "k3s-control-plane-01/files/k3s-control-plane-01/k3s-agent-token"
)


def configured_master_user():
    user = ""
    paths = [Path("/etc/salt/master")]
    paths.extend(sorted(Path("/etc/salt/master.d").glob("*.conf")))
    for path in paths:
        try:
            lines = path.read_text().splitlines()
        except FileNotFoundError:
            continue
        for line in lines:
            match = re.match(r"\s*user\s*:\s*['\"]?([^'\"#\s]+)", line)
            if match:
                user = match.group(1)
    return user or "root"


def read_token():
    try:
        return TOKEN_FILE.read_text().strip()
    except FileNotFoundError:
        return ""


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
        with error:
            detail = json.load(error).get("message", "No API error message")
        raise RuntimeError(
            f"Tailscale API {request.get_method()} {path}: HTTP {error.code}: {detail}"
        ) from None


def inference_hosts(devices):
    matches = [
        device
        for device in devices.get("devices", [])
        if any(
            isinstance(name, str)
            and name.rstrip(".").split(".")[0] == INFERENCE_NODE
            for name in (device.get("hostname"), device.get("name"))
        )
    ]
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected one Tailscale device named {INFERENCE_NODE}, found {len(matches)}"
        )
    hosts = {}
    for address in matches[0].get("addresses", []):
        parsed = ipaddress.ip_address(address)
        alias = INFERENCE_HOST_ALIASES.get(parsed.version)
        if alias:
            hosts[alias] = str(parsed)
    if INFERENCE_HOST_ALIASES[4] not in hosts:
        raise RuntimeError(f"Tailscale device {INFERENCE_NODE} has no IPv4 address")
    return hosts


def merge_policy(policy, inference_hosts):
    owners = policy.setdefault("tagOwners", {})
    owners.setdefault("tag:salt-managed", ["autogroup:admin"])
    owners.setdefault("tag:k8s", ["autogroup:admin"])
    hosts = policy.setdefault("hosts", {})
    for alias in INFERENCE_HOST_ALIASES.values():
        if alias in inference_hosts:
            hosts[alias] = inference_hosts[alias]
        else:
            hosts.pop(alias, None)
    grants = policy.setdefault("grants", [])
    inference_grant = {
        "src": ["tag:k8s"],
        "dst": sorted(inference_hosts),
        "ip": INFERENCE_PORTS,
    }
    for grant in (GRANT, inference_grant):
        if grant not in grants:
            grants.append(grant)
    ssh_rules = policy.setdefault("ssh", [])
    if SSH_RULE not in ssh_rules:
        ssh_rules.append(SSH_RULE)
    return policy


def write_pillar(path, value, owner):
    temporary = DIRECTORY / "pillar-write.tmp"
    temporary.write_text(value)
    os.chown(temporary, owner.pw_uid, owner.pw_gid)
    temporary.replace(path)


def restrict_cluster_credentials(token, owner):
    hosts = DIRECTORY / "pillar" / "hosts"
    # Include retired/unaccepted minions, not just today's accepted key list.
    for path in hosts.glob("*/K3S_TOKEN"):
        path.unlink()
    for path in hosts.glob("*/K3S_AGENT_TOKEN"):
        if path.parent.name not in WORKERS or not token:
            path.unlink()
    if token:
        for node in WORKERS:
            directory = hosts / node
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.chown(directory, owner.pw_uid, owner.pw_gid)
            directory.chmod(0o700)
            write_pillar(directory / "K3S_AGENT_TOKEN", token, owner)


def provision():
    os.umask(0o077)
    DIRECTORY.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (DIRECTORY / "provision.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        key = (DIRECTORY / "api-key").read_text().strip()
        if not key:
            raise ValueError("TS_API_KEY is empty")
        user = subprocess.check_output(
            ["systemctl", "show", "salt-master", "--property=User", "--value"],
            text=True,
        ).strip()
        if not user or user == "root":
            user = configured_master_user()
        owner = pwd.getpwnam(user)
        os.chown(DIRECTORY, -1, owner.pw_gid)
        DIRECTORY.chmod(0o710)
        token = read_token()
        restrict_cluster_credentials(token, owner)
        devices, _ = api(key, "/devices")
        managed_hosts = inference_hosts(devices)
        policy, headers = api(key, "/acl")
        original = json.dumps(policy, sort_keys=True)
        merge_policy(policy, managed_hosts)
        if json.dumps(policy, sort_keys=True) != original:
            etag = headers.get("ETag")
            if not etag:
                raise RuntimeError("Tailscale policy response has no ETag; refusing unsafe update")
            backup = DIRECTORY / "policy-before-salt.json"
            if not backup.exists():
                backup.write_text(original + "\n")
            api(key, "/acl", policy, "POST", {"If-Match": etag})
            print("Reconciled Salt tags, Kubernetes, and node-3 inference grants; existing rules preserved")
        accepted = json.loads(subprocess.check_output(
            ["salt-key", "--out=json", "--list=accepted"], text=True
        ))["minions"]
        for node in sorted(set(accepted) | {"salt-master-01"}):
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", node):
                raise ValueError("Salt minion ID is not a safe Tailscale hostname")
            directory = DIRECTORY / "pillar" / "hosts" / node
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            for folder in [DIRECTORY / "pillar", DIRECTORY / "pillar" / "hosts", directory]:
                os.chown(folder, owner.pw_uid, owner.pw_gid)
                folder.chmod(0o700)
            if node == "salt-master-01":
                write_pillar(directory / "TS_API_KEY", key, owner)
            cache = DIRECTORY / (hashlib.sha256(node.encode()).hexdigest() + ".json")
            if cache.exists() and json.loads(cache.read_text())["expires"] > time.time() + 600:
                write_pillar(directory / "TAILSCALE_AUTH_KEY", json.loads(cache.read_text())["key"], owner)
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
                "description": "salt-" + cache.stem[:32],
            })
            secret = result["key"]
            if not secret.startswith("tskey-auth-"):
                raise ValueError("Tailscale API returned an invalid enrollment key")
            temporary = cache.with_suffix(".tmp")
            temporary.write_text(json.dumps({"key": secret, "expires": time.time() + 3500}))
            temporary.replace(cache)
            write_pillar(directory / "TAILSCALE_AUTH_KEY", secret, owner)
        print(f"Tailscale enrollment keys ready for {len(set(accepted) | {'salt-master-01'})} minions")


if __name__ == "__main__":
    provision()
