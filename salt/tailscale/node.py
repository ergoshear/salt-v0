#!/usr/bin/python3
import ipaddress
import json
from pathlib import Path
import subprocess
import sys


CLUSTER = {"k3s-control-plane-01", "mlops-node-0", "mlops-node-1"}


def run(*args):
    return subprocess.check_output(args, text=True)


def status():
    return json.loads(run("tailscale", "status", "--json"))


def enroll(node):
    tags = ["tag:salt-managed"] + (["tag:k8s"] if node in CLUSTER else [])
    current = status()
    if current["BackendState"] != "Running":
        subprocess.run([
            "tailscale", "up", "--auth-key=file:/etc/tailscale/salt-authkey",
            "--hostname=" + node, "--advertise-tags=" + ",".join(tags),
            "--timeout=60s",
        ], check=True)
        if status()["BackendState"] != "Running":
            raise RuntimeError("Tailscale enrollment did not reach Running")
        return True
    preferences = json.loads(run("tailscale", "debug", "prefs"))
    if preferences.get("Hostname") != node or sorted(preferences.get("AdvertiseTags") or []) != sorted(tags):
        subprocess.run([
            "tailscale", "set", "--hostname=" + node,
            "--advertise-tags=" + ",".join(tags),
        ], check=True)
        return True
    return False


def configure(node):
    if node not in CLUSTER:
        raise ValueError("Only the three Kubernetes nodes can configure k3s networking")
    current = status()
    if current["BackendState"] != "Running":
        raise RuntimeError("Tailscale must be Running before configuring k3s")
    address = next(
        str(ipaddress.IPv4Address(ip))
        for ip in current["TailscaleIPs"] if ":" not in ip
    )
    content = f"node-ip: {address}\nflannel-iface: tailscale0\n"
    if node == "k3s-control-plane-01":
        content += f"advertise-address: {address}\n"
    path = Path("/etc/rancher/k3s/config.yaml.d/20-tailscale.yaml")
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text() == content:
        return False
    path.write_text(content)
    return True


if __name__ == "__main__":
    action, node = sys.argv[1:]
    changed = {"enroll": enroll, "configure": configure}[action](node)
    print(json.dumps({"changed": changed, "comment": "Tailscale " + action + " complete"}))
