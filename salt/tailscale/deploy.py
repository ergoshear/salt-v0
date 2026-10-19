import json
import subprocess
import time


CLUSTER = ["k3s-control-plane-01", "mlops-node-0", "mlops-node-1"]


def salt(nodes, function, *arguments):
    result = subprocess.run(
        ["salt", "--static", "--out=json", "--timeout=300",
         "-L", ",".join(nodes), function, *arguments],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise RuntimeError(
            f"Salt {function} failed (exit {result.returncode}): {result.stdout}\n{result.stderr}"
        )
    data = json.loads(result.stdout)
    if set(data) != set(nodes):
        raise RuntimeError(f"Salt {function}: expected {nodes}, received {list(data)}")
    for node, response in data.items():
        if function == "state.apply":
            if not isinstance(response, dict) or not response:
                raise RuntimeError(f"{node}: invalid state response: {response}")
            failed = [
                value.get("comment", "state failed") if isinstance(value, dict) else str(value)
                for value in response.values()
                if not isinstance(value, dict) or value.get("result") is not True
            ]
            if failed:
                raise RuntimeError(f"{node}: {failed}")
        elif response is not True:
            raise RuntimeError(f"{node}: {function} failed: {response}")
    print(f"{function} succeeded on {', '.join(nodes)}", flush=True)


def deploy():
    accepted = json.loads(subprocess.check_output(
        ["salt-key", "--out=json", "--list=accepted"], text=True
    ))["minions"]
    missing = set(CLUSTER) - set(accepted)
    if missing:
        raise RuntimeError(f"Required Kubernetes minions are not accepted: {sorted(missing)}")
    for attempt in range(30):
        ready = subprocess.run(
            ["salt-run", "--out=json", "manage.status"], capture_output=True, text=True
        )
        if ready.returncode == 0:
            break
        time.sleep(2)
    else:
        raise RuntimeError("Salt master did not become ready after bootstrap")
    salt(accepted, "saltutil.refresh_pillar", "wait=True")
    salt(accepted, "state.apply", "tailscale", "queue=True")
    salt(["k3s-control-plane-01"], "state.apply", "k3s.control-plane", "queue=True")
    salt(CLUSTER[1:], "saltutil.refresh_pillar", "wait=True")
    salt(CLUSTER[1:], "state.apply", "k3s.agent", "queue=True")
    result = subprocess.run([
        "salt", "--static", "--out=json", "--timeout=300", "k3s-control-plane-01",
        "cmd.run_all",
        "k3s kubectl wait --for=condition=Ready node/mlops-node-0 node/mlops-node-1 --timeout=180s",
    ], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("Kubernetes Ready verification failed:\n" + result.stdout + result.stderr)
    response = json.loads(result.stdout).get("k3s-control-plane-01")
    if not isinstance(response, dict) or response.get("retcode") != 0:
        raise RuntimeError("Kubernetes Ready verification failed:\n" + result.stdout + result.stderr)
    print("Both Kubernetes workers are Ready", flush=True)


if __name__ == "__main__":
    deploy()
