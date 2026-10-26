import json
import re
import subprocess
import time


CLUSTER = ["k3s-control-plane-01", "mlops-node-0", "mlops-node-1", "mlops-node-5"]


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
                re.sub(r"tskey-[A-Za-z0-9_-]+", "[REDACTED]", (
                    f"{state_id}: {value.get('name')}: {value.get('comment')}: "
                    + json.dumps({
                        key: value.get("changes", {}).get(key)
                        for key in ["stdout", "stderr"]
                    })
                )) if isinstance(value, dict) else str(value)
                for state_id, value in response.items()
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
            ["salt-run", "--log-level=error", "--out=json", "manage.status"],
            capture_output=True, text=True,
        )
        if ready.returncode == 0:
            break
        time.sleep(2)
    else:
        raise RuntimeError("Salt master did not become ready after bootstrap")
    salt(accepted, "saltutil.refresh_pillar", "wait=True")
    salt(accepted, "state.apply", "tailscale", "queue=True")
    salt(["k3s-control-plane-01"], "state.apply", "k3s.control-plane", "queue=True")
    subprocess.run(["python3", "/usr/local/sbin/salt-tailscale-provision"], check=True)
    salt(CLUSTER[1:], "saltutil.refresh_pillar", "wait=True")
    salt(CLUSTER[1:], "state.apply", "k3s.agent", "queue=True")
    check_cluster(
        "k3s kubectl wait --for=condition=Ready "
        "node/mlops-node-0 node/mlops-node-1 node/mlops-node-5 --timeout=180s",
        "All Kubernetes workers are Ready",
    )
    check_cluster(
        "/usr/bin/python3 /usr/local/sbin/salt-k3s-verify",
        "Tailscale addresses, cross-worker pod traffic, DNS, and kubelet metrics verified",
    )


def recover_passwd():
    salt(
        ["k3s-control-plane-01"],
        "state.apply",
        "k3s.passwd_recovery",
        "queue=True",
    )


def check_cluster(command, description):
    result = subprocess.run([
        "salt", "--static", "--out=json", "--timeout=600", "k3s-control-plane-01",
        "cmd.run_all", command,
    ], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(description + " failed:\n" + result.stdout + result.stderr)
    response = json.loads(result.stdout).get("k3s-control-plane-01")
    if not isinstance(response, dict) or response.get("retcode") != 0:
        raise RuntimeError(description + " failed:\n" + result.stdout + result.stderr)
    print(response.get("stdout", ""), flush=True)
    print(description, flush=True)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--recover-passwd-only",
        action="store_true",
        help="Recover the K3s control-plane passwd file only if its startup guard fired",
    )
    arguments = parser.parse_args()
    if arguments.recover_passwd_only:
        recover_passwd()
    else:
        deploy()
