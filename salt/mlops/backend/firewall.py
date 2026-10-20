#!/usr/bin/python3
"""Restrict host inference to the authenticated Kubernetes egress proxies."""
import ipaddress
import json
import subprocess


PROXIES = {"egress-proxies-0", "egress-proxies-1"}


def rules(status):
    addresses = []
    for peer in status.get("Peer", {}).values():
        name = peer.get("HostName")
        if (
            name in PROXIES
            and "tag:k8s" in peer.get("Tags", [])
            and peer.get("DNSName", "").rstrip(".") == f"{name}.tailb11f97.ts.net"
        ):
            addresses.extend(ipaddress.ip_address(ip) for ip in peer.get("TailscaleIPs", []))
    commands = [
        "flush table inet inference_boundary",
        "add chain inet inference_boundary input { type filter hook input priority -20; policy accept; }",
        'add rule inet inference_boundary input iifname "lo" tcp dport 8080 accept',
    ]
    for address in sorted(set(addresses), key=str):
        family = "ip" if address.version == 4 else "ip6"
        commands.append(
            f'add rule inet inference_boundary input iifname "tailscale0" '
            f"{family} saddr {address} tcp dport 8080 accept"
        )
    commands.append("add rule inet inference_boundary input tcp dport 8080 drop")
    return "\n".join(commands) + "\n"


def main():
    # A dedicated table survives firewalld reloads and filters before Tailscale's
    # blanket accept rule, including already-established inference connections.
    subprocess.run(
        ["nft", "add", "table", "inet", "inference_boundary"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        status = json.loads(subprocess.check_output(["tailscale", "status", "--json"]))
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        status = {}
    subprocess.run(["nft", "-f", "-"], input=rules(status), text=True, check=True)


if __name__ == "__main__":
    main()
