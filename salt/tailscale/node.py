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
    command = [
        "tailscale", "up", "--auth-key=file:/etc/tailscale/salt-authkey",
        "--hostname=" + node, "--advertise-tags=" + ",".join(tags),
    ]
    if current["BackendState"] != "Running":
        subprocess.run([*command, "--timeout=60s"], check=True, stdout=subprocess.PIPE, text=True)
        if status()["BackendState"] != "Running":
            raise RuntimeError("Tailscale enrollment did not reach Running")
        return True
    preferences = json.loads(run("tailscale", "debug", "prefs"))
    changed = False
    if preferences.get("Hostname") != node:
        subprocess.run(
            ["tailscale", "set", "--hostname=" + node],
            check=True, stdout=subprocess.PIPE, text=True,
        )
        changed = True
    if sorted(preferences.get("AdvertiseTags") or []) != sorted(tags):
        # Tags are authentication identity in Tailscale; `tailscale set` cannot
        # change them. Re-authenticate with the managed key and desired tags.
        subprocess.run([*command, "--force-reauth"], check=True, stdout=subprocess.PIPE, text=True)
        preferences = json.loads(run("tailscale", "debug", "prefs"))
        if preferences.get("Hostname") != node or sorted(preferences.get("AdvertiseTags") or []) != sorted(tags):
            raise RuntimeError("Tailscale preferences did not converge after re-authentication")
        changed = True
    return changed


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


def firewall(node):
    if node != "k3s-control-plane-01":
        raise ValueError("Public ingress rules belong only on the control plane")
    routes = json.loads(run("ip", "-j", "route", "show", "default"))
    if not routes:
        raise RuntimeError("Cannot determine the control plane's internet interface")
    interface = min(routes, key=lambda route: route.get("metric", 0))["dev"]
    result = subprocess.run(
        ["firewall-cmd", "--get-zone-of-interface=" + interface],
        capture_output=True, text=True,
    )
    if result.returncode == 0 and result.stdout.strip() != "no zone":
        zone = result.stdout.strip()
    elif result.stdout.strip() == "no zone":
        zone = run("firewall-cmd", "--get-default-zone").strip()
    else:
        raise RuntimeError("Cannot determine firewalld zone: " + result.stderr)
    changed = False
    rules = [
        ("port", "80/tcp"), ("port", "443/tcp"),
        ("rich-rule", 'rule family="ipv4" source address="173.72.146.35/32" port port="6443" protocol="tcp" accept'),
    ]
    for scope in [[], ["--permanent"]]:
        for kind, value in rules:
            command = ["firewall-cmd", *scope, "--zone=" + zone]
            query = subprocess.run(
                [*command, "--query-" + kind + "=" + value],
                capture_output=True, text=True,
            )
            if query.returncode == 1:
                run(*command, "--add-" + kind + "=" + value)
                changed = True
            elif query.returncode != 0:
                raise RuntimeError("Cannot query firewalld rule: " + query.stderr)
    return changed


if __name__ == "__main__":
    action, node = sys.argv[1:]
    changed = {"enroll": enroll, "configure": configure, "firewall": firewall}[action](node)
    print(json.dumps({"changed": changed, "comment": "Tailscale " + action + " complete"}))
