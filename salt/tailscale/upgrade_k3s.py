import json
import re
import subprocess
import time
from urllib.error import HTTPError
from urllib.parse import unquote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


CHANNEL_URL = "https://update.k3s.io/v1-release/channels/stable"
CLUSTER_MINIONS = ["k3s-control-plane-01", "mlops-node-0", "mlops-node-1"]
CONTROL_PLANE = "k3s-control-plane-01"
CONTROL_PLANE_NODE = "k3s.ergoshear.dev"
AGENT_NODES = [("mlops-node-0", "mlops-node-0"), ("mlops-node-1", "mlops-node-1")]
EXPECTED_NODES = {CONTROL_PLANE_NODE, *(node for _, node in AGENT_NODES)}
VERSION_PATTERN = re.compile(r"v(\d+)\.(\d+)\.(\d+)\+k3s(\d+)")
REDIRECT_CODES = {301, 302, 303, 307, 308}
READINESS_TIMEOUT = 300
POLL_INTERVAL = 5


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        return None


def parse_version(version):
    if not isinstance(version, str):
        raise ValueError(f"Invalid K3s version: {version!r}")
    match = VERSION_PATTERN.fullmatch(version)
    if not match:
        raise ValueError(f"Invalid K3s version: {version!r}")
    return tuple(int(part) for part in match.groups())


def parse_release_location(location):
    if not location:
        raise RuntimeError("K3s stable channel did not return a release redirect")
    parsed_location = urlsplit(location)
    if (
        parsed_location.scheme != "https"
        or parsed_location.netloc != "github.com"
        or not parsed_location.path.startswith("/k3s-io/k3s/releases/tag/")
    ):
        raise RuntimeError(f"Unexpected K3s stable channel redirect: {location}")
    version = unquote(parsed_location.path.rsplit("/", 1)[-1])
    try:
        parse_version(version)
    except ValueError as error:
        raise RuntimeError(f"Unexpected K3s stable release tag: {version}") from error
    return version


def latest_stable_version():
    request = Request(CHANNEL_URL, method="GET")
    opener = build_opener(_NoRedirect())
    try:
        with opener.open(request, timeout=30) as response:
            location = response.geturl()
    except HTTPError as error:
        if error.code not in REDIRECT_CODES:
            raise
        location = error.headers.get("Location")
    return parse_release_location(location)


def salt(nodes, function, *arguments, timeout=300):
    result = subprocess.run(
        [
            "salt",
            "--static",
            "--out=json",
            f"--timeout={timeout}",
            "-L",
            ",".join(nodes),
            function,
            *arguments,
        ],
        capture_output=True,
        text=True,
        timeout=timeout + 30,
    )
    if result.returncode:
        raise RuntimeError(
            f"Salt {function} failed (exit {result.returncode}): "
            f"{result.stdout}\n{result.stderr}"
        )
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"Salt {function} returned invalid JSON: {result.stdout}") from error
    if not isinstance(data, dict) or set(data) != set(nodes):
        raise RuntimeError(f"Salt {function}: expected {nodes}, received {list(data)}")

    for minion, response in data.items():
        if function == "test.ping" and response is not True:
            raise RuntimeError(f"{minion}: Salt ping failed: {response}")
        if function == "state.apply":
            if not isinstance(response, dict) or not response:
                raise RuntimeError(f"{minion}: invalid Salt state response: {response}")
            failures = [
                state_id
                for state_id, state in response.items()
                if not isinstance(state, dict) or state.get("result") is not True
            ]
            if failures:
                raise RuntimeError(f"{minion}: failed Salt states: {failures}")
        if function == "cmd.run_all":
            if not isinstance(response, dict) or response.get("retcode") != 0:
                raise RuntimeError(f"{minion}: command failed: {response}")
    return data


def read_cluster_nodes():
    response = salt(
        [CONTROL_PLANE],
        "cmd.run_all",
        "/usr/local/bin/k3s kubectl get nodes -o json",
        timeout=60,
    )[CONTROL_PLANE]
    try:
        node_list = json.loads(response["stdout"])["items"]
        nodes = {}
        for item in node_list:
            name = item["metadata"]["name"]
            version = item["status"]["nodeInfo"]["kubeletVersion"]
            ready = any(
                condition.get("type") == "Ready" and condition.get("status") == "True"
                for condition in item["status"].get("conditions", [])
            )
            nodes[name] = {"ready": ready, "version": version}
    except (KeyError, TypeError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Could not parse Kubernetes node status: {response}") from error
    return nodes


def upgrade_plan(nodes, target_version):
    target = parse_version(target_version)
    if set(nodes) != EXPECTED_NODES:
        raise RuntimeError(
            f"Expected Kubernetes nodes {sorted(EXPECTED_NODES)}, got {sorted(nodes)}"
        )
    if not all(state.get("ready") is True for state in nodes.values()):
        raise RuntimeError("All Kubernetes nodes must be Ready before starting an upgrade")

    versions = {name: parse_version(state.get("version")) for name, state in nodes.items()}
    server_version = versions[CONTROL_PLANE_NODE]
    if any(server_version[:2] < versions[node][:2] for _, node in AGENT_NODES):
        raise RuntimeError("The control-plane version must not be behind an agent version")

    for node, current in versions.items():
        if current[0] != target[0] or target[1] - current[1] > 1:
            raise RuntimeError(
                f"Upgrade from {nodes[node]['version']} to {target_version} must be staged "
                "one Kubernetes minor version at a time"
            )
        if current > target:
            raise RuntimeError(
                f"Refusing to downgrade {node} from {nodes[node]['version']} to {target_version}"
            )

    plan = []
    if versions[CONTROL_PLANE_NODE] != target:
        plan.append((CONTROL_PLANE, CONTROL_PLANE_NODE))
    for minion, node in AGENT_NODES:
        if versions[node] != target:
            plan.append((minion, node))
    return plan


def apply_upgrade(minion, version):
    pillar = json.dumps({"K3S_UPGRADE_VERSION": version}, separators=(",", ":"))
    salt(
        [minion],
        "state.apply",
        "k3s.upgrade",
        f"pillar={pillar}",
        "queue=True",
    )


def wait_for_nodes(expected_versions):
    deadline = time.monotonic() + READINESS_TIMEOUT
    last_status = "Kubernetes API has not returned node status"
    while True:
        try:
            nodes = read_cluster_nodes()
            if set(nodes) == EXPECTED_NODES:
                not_ready = sorted(name for name, state in nodes.items() if not state["ready"])
                wrong_version = {
                    name: state["version"]
                    for name, state in nodes.items()
                    if state["version"] != expected_versions[name]
                }
                if not not_ready and not wrong_version:
                    return
                last_status = (
                    f"not Ready: {not_ready}; unexpected versions: {wrong_version}"
                )
            else:
                last_status = f"expected nodes {sorted(EXPECTED_NODES)}, got {sorted(nodes)}"
        except RuntimeError as error:
            last_status = str(error)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError(
                f"Kubernetes did not become Ready within {READINESS_TIMEOUT}s: {last_status}"
            )
        print(f"Waiting for Kubernetes nodes to recover: {last_status}", flush=True)
        time.sleep(min(POLL_INTERVAL, remaining))


def upgrade_cluster():
    version = latest_stable_version()
    print(f"Latest stable K3s release: {version}", flush=True)

    accepted = json.loads(
        subprocess.check_output(
            ["salt-key", "--out=json", "--list=accepted"],
            text=True,
        )
    )["minions"]
    missing = set(CLUSTER_MINIONS) - set(accepted)
    if missing:
        raise RuntimeError(f"Required Kubernetes minions are not accepted: {sorted(missing)}")
    salt(CLUSTER_MINIONS, "test.ping", timeout=60)

    nodes = read_cluster_nodes()
    plan = upgrade_plan(nodes, version)
    if not plan:
        print(f"All Kubernetes nodes are Ready on {version}; nothing to do.", flush=True)
        return

    expected_versions = {name: state["version"] for name, state in nodes.items()}
    for minion, node in plan:
        print(f"Upgrading {minion} to {version}", flush=True)
        apply_upgrade(minion, version)
        expected_versions[node] = version
        wait_for_nodes(expected_versions)
        print(f"{node} is Ready on {version}", flush=True)

    print(f"K3s upgrade completed; all Kubernetes nodes are Ready on {version}.", flush=True)


if __name__ == "__main__":
    upgrade_cluster()
