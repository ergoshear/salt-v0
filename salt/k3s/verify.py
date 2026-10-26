import ipaddress
import json
import subprocess
import time
import uuid


WORKERS = ["mlops-node-0", "mlops-node-1", "mlops-node-5"]


def kubectl(*arguments, data=None):
    return subprocess.check_output(
        ["k3s", "kubectl", *arguments], input=data, text=True
    )


def probe(namespace, index):
    return {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": f"probe-{index}", "namespace": namespace},
        "spec": {
            "nodeName": WORKERS[index], "restartPolicy": "Never",
            "automountServiceAccountToken": False,
            "containers": [{
                "name": "probe", "image": "busybox:1.37.0",
                "command": ["sh", "-c",
                            "mkdir -p /tmp/health; echo ok > /tmp/health/index.html; "
                            "exec httpd -f -p 8080 -h /tmp/health"],
                "resources": {
                    "requests": {"cpu": "5m", "memory": "8Mi"},
                    "limits": {"cpu": "100m", "memory": "32Mi"},
                },
                "securityContext": {
                    "runAsNonRoot": True, "runAsUser": 65534,
                    "allowPrivilegeEscalation": False,
                    "capabilities": {"drop": ["ALL"]},
                    "seccompProfile": {"type": "RuntimeDefault"},
                },
                "readinessProbe": {
                    "httpGet": {"path": "/", "port": 8080},
                    "periodSeconds": 2,
                },
            }],
        },
    }


def node_addresses(nodes):
    control_planes = [
        node["metadata"]["name"] for node in nodes
        if "node-role.kubernetes.io/control-plane" in node["metadata"].get("labels", {})
    ]
    if len(control_planes) != 1:
        raise RuntimeError("Expected exactly one labeled Kubernetes control-plane node")
    by_name = {node["metadata"]["name"]: node for node in nodes}
    missing = set(WORKERS) - set(by_name)
    if missing:
        raise RuntimeError(f"Missing Kubernetes workers: {sorted(missing)}")
    result = {}
    for name in [*control_planes, *WORKERS]:
        node = by_name[name]
        addresses = [
            ipaddress.ip_address(address["address"])
            for address in node["status"]["addresses"]
            if address["type"] == "InternalIP" and ":" not in address["address"]
        ]
        if not addresses or any(
            address not in ipaddress.ip_network("100.64.0.0/10") for address in addresses
        ):
            raise RuntimeError(f"{name} does not advertise a Tailscale InternalIP")
        result[name] = str(addresses[0])
    return result


def verify():
    nodes = json.loads(kubectl("get", "nodes", "-o", "json"))["items"]
    for name, address in node_addresses(nodes).items():
        print(f"{name}: Tailscale InternalIP {address}", flush=True)
    namespace = "salt-network-check-" + uuid.uuid4().hex[:12]
    kubectl("create", "namespace", namespace)
    try:
        manifest = {"apiVersion": "v1", "kind": "List",
                    "items": [probe(namespace, index) for index in range(len(WORKERS))]}
        kubectl("apply", "-f", "-", data=json.dumps(manifest))
        kubectl("-n", namespace, "wait", "--for=condition=Ready", "pod",
                "--all", "--timeout=180s")
        pods = json.loads(kubectl("-n", namespace, "get", "pods", "-o", "json"))["items"]
        addresses = {pod["metadata"]["name"]: pod["status"]["podIP"] for pod in pods}
        for index, worker in enumerate(WORKERS):
            prefix = ["-n", namespace, "exec", f"probe-{index}", "--"]
            peer = addresses[f"probe-{(index + 1) % len(WORKERS)}"]
            result = kubectl(*prefix, "wget", "-qO-", "-T", "10", f"http://{peer}:8080")
            if result.strip() != "ok":
                raise RuntimeError(f"{worker}: cross-worker HTTP response was invalid")
            kubectl(*prefix, "nslookup", "kubernetes.default.svc.cluster.local")
            print(f"{worker}: cross-worker pod HTTP and cluster DNS passed", flush=True)
    finally:
        kubectl("delete", "namespace", namespace, "--wait=false")

    for attempt in range(18):
        result = subprocess.run(
            ["k3s", "kubectl", "top", "nodes", "--no-headers"],
            capture_output=True, text=True,
        )
        names = {line.split()[0] for line in result.stdout.splitlines() if line.split()}
        if result.returncode == 0 and set(WORKERS) <= names:
            print("Both worker kubelet metrics are available", flush=True)
            return
        time.sleep(5)
    raise RuntimeError("Worker metrics verification failed: " + result.stdout + result.stderr)


if __name__ == "__main__":
    verify()
