import copy
import hashlib
import io
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest
from urllib.error import HTTPError
from unittest.mock import patch

from jinja2 import Environment, StrictUndefined
import yaml


ROOT = Path(__file__).resolve().parents[1]
CLUSTER = {"k3s-control-plane-01", "mlops-node-0", "mlops-node-1"}


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PILLAR = load("pillar", "salt/salt/k3s_token_pillar.py")
PROVISION = load("provision", "salt/tailscale/provision.py")
NODE = load("node", "salt/tailscale/node.py")
DEPLOY = load("deploy", "salt/tailscale/deploy.py")


def render(state, node, pillar=None):
    pillar = pillar or {}
    template = Environment(undefined=StrictUndefined).from_string(
        (ROOT / "salt" / state / "init.sls").read_text()
    )
    return yaml.safe_load(template.render(
        grains={"id": node},
        salt={"pillar.get": lambda key, default=None: pillar.get(key, default)},
    ))


def options(states, state_id, function):
    return {
        key: value
        for option in states[state_id][function]
        for key, value in option.items()
    }


class PillarTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name)
        self.token = self.path / "token"
        self.token.write_text("test-k3s-token\n")
        (self.path / "api-key").write_text("test-api-key")
        for node in CLUSTER | {"salt-master-01", "mlops-node-9"}:
            cache = self.path / (hashlib.sha256(node.encode()).hexdigest() + ".json")
            cache.write_text(json.dumps({
                "key": "test-auth-" + node, "expires": time.time() + 3600,
            }))
        patcher = patch.multiple(PILLAR, DIRECTORY=self.path, TOKEN_FILE=self.token)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_management_key_is_master_only_and_auth_keys_are_per_minion(self):
        for node in CLUSTER | {"salt-master-01", "mlops-node-9"}:
            data = PILLAR.ext_pillar(node, {})
            self.assertEqual("TS_API_KEY" in data, node == "salt-master-01")
            self.assertEqual(data["TAILSCALE_AUTH_KEY"], "test-auth-" + node)
            self.assertEqual(data["K3S_TOKEN"], "test-k3s-token")

    def test_unknown_minion_cannot_get_another_enrollment_key(self):
        with self.assertRaisesRegex(RuntimeError, "Missing"):
            PILLAR.ext_pillar("../../salt-master-01", {})

    def test_expired_key_fails_explicitly(self):
        node = "mlops-node-0"
        cache = self.path / (hashlib.sha256(node.encode()).hexdigest() + ".json")
        cache.write_text(json.dumps({"key": "old", "expires": 0}))
        with self.assertRaisesRegex(RuntimeError, "expired"):
            PILLAR.ext_pillar(node, {})


class PolicyTests(unittest.TestCase):
    @patch.object(PROVISION.subprocess, "check_output")
    @patch.object(PROVISION, "api")
    def test_provision_creates_tagged_keys_with_valid_descriptions(self, api, output):
        output.return_value = json.dumps({"minions": ["mlops-node-0", "mlops-node-9"]})
        api.side_effect = lambda key, path, *args: (
            ({"tagOwners": {
                "tag:salt-managed": ["autogroup:admin"],
                "tag:k8s": ["autogroup:admin"],
            }, "grants": [copy.deepcopy(PROVISION.GRANT)]}, {})
            if path == "/acl" else ({"key": "tskey-auth-test"}, {})
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "api-key").write_text("test-api-key")
            with patch.object(PROVISION, "DIRECTORY", path):
                PROVISION.provision()
                for call in api.call_args_list[1:]:
                    payload = call.args[2]
                    self.assertRegex(payload["description"], r"^salt-[a-f0-9]{32}$")
                    self.assertTrue(payload["capabilities"]["devices"]["create"]["reusable"])
                    self.assertEqual(payload["expirySeconds"], 3600)
                calls = api.call_count
                PROVISION.provision()
                self.assertEqual(api.call_count, calls + 1)

    @patch.object(PROVISION, "urlopen")
    def test_api_error_preserves_actionable_message_without_credentials(self, open_url):
        open_url.side_effect = HTTPError(
            "https://api.tailscale.com", 400, "Bad Request", {},
            io.BytesIO(b'{"message":"requested tags are invalid"}'),
        )
        with self.assertRaisesRegex(RuntimeError, "GET /keys: HTTP 400: requested tags"):
            PROVISION.api("secret-management-key", "/keys")

    def test_merge_preserves_existing_policy_and_tag_owners(self):
        policy = {
            "tagOwners": {"tag:k8s": ["tag:k8s-operator"]},
            "acls": [{"action": "accept", "src": ["user@example.com"], "dst": ["*:*"]}],
            "ssh": [{"action": "check", "src": ["autogroup:member"]}],
            "grants": [{"src": ["tag:existing"], "dst": ["tag:existing"], "ip": ["*"]}],
        }
        original = copy.deepcopy(policy)
        merged = PROVISION.merge_policy(policy)
        self.assertEqual(merged["tagOwners"]["tag:k8s"], ["tag:k8s-operator"])
        self.assertEqual(merged["acls"], original["acls"])
        self.assertEqual(merged["ssh"], original["ssh"])
        self.assertEqual(merged["grants"][0], original["grants"][0])
        self.assertIn(PROVISION.GRANT, merged["grants"])
        self.assertEqual(PROVISION.merge_policy(copy.deepcopy(merged)), merged)

    def test_only_cluster_tag_gets_kubernetes_access(self):
        self.assertEqual(PROVISION.GRANT["src"], ["tag:k8s"])
        self.assertEqual(PROVISION.GRANT["dst"], ["tag:k8s"])
        self.assertEqual(
            set(PROVISION.GRANT["ip"]), {"tcp:6443", "tcp:10250", "udp:8472"}
        )


class StateTests(unittest.TestCase):
    def test_targeting_and_fail_closed_guards(self):
        top = yaml.safe_load((ROOT / "salt/top.sls").read_text())["base"]
        self.assertIn("tailscale", top["*"])
        self.assertEqual(
            {node for node, states in top.items() if "k3s.agent" in states},
            {"mlops-node-0", "mlops-node-1"},
        )
        for node in ["mlops-node-2", "mlops-nodes-0", "salt-master-01"]:
            self.assertEqual(
                set(render("k3s/agent", node, {"K3S_TOKEN": "test"})),
                {"k3s-agent-prerequisites"},
            )
        self.assertIn("k3s-agent-prerequisites", render("k3s/agent", "mlops-node-0"))
        self.assertIn("tailscale-missing-enrollment", render("tailscale", "mlops-node-0"))

    def test_agent_configs_protect_token_and_use_tailnet(self):
        token = 'test:"token\\with\nspecial-characters'
        for node in CLUSTER - {"k3s-control-plane-01"}:
            state = render("k3s/agent", node, {"K3S_TOKEN": token})
            managed = options(state, "k3s-agent-config", "file.managed")
            self.assertFalse(managed["show_changes"])
            self.assertEqual(managed["mode"], "0600")
            content = yaml.safe_load(managed["contents"])
            self.assertEqual(content["token"], token)
            self.assertEqual(
                content["server"], "https://k3s-control-plane-01.tailb11f97.ts.net:6443"
            )
            self.assertNotIn(token, json.dumps(options(state, "k3s-agent-install", "cmd.run")))

    def test_enrollment_hides_key_and_does_not_put_it_on_command_line(self):
        state = render("tailscale", "mlops-node-0", {"TAILSCALE_AUTH_KEY": "secret-auth"})
        managed = options(state, "tailscale-auth-key", "file.managed")
        self.assertFalse(managed["show_changes"])
        self.assertEqual(managed["mode"], "0600")
        command = options(state, "tailscale-enroll", "cmd.run")
        self.assertNotIn("secret-auth", command["name"])
        self.assertFalse(command["python_shell"])

    def test_firewalls_use_tailscale_and_no_public_overlay_ports(self):
        for node in CLUSTER:
            state = render("k3s/network", node)
            trusted = options(state, "k3s-firewall-cluster", "firewalld.present")
            self.assertEqual(trusted["interfaces"], ["tailscale0"])
            self.assertEqual(trusted["sources"], ["10.42.0.0/16", "10.43.0.0/16"])
            self.assertNotIn("51820", json.dumps(state))
            if node != "k3s-control-plane-01":
                self.assertNotIn("k3s-firewall-public", state)

    def test_server_retains_taint_and_dns_sans(self):
        state = render("k3s/control-plane", "k3s-control-plane-01")
        config = yaml.safe_load(
            options(state, "k3s-control-plane-config", "file.managed")["contents"]
        )
        self.assertEqual(config["node-taint"], [
            "node-role.kubernetes.io/control-plane=true:NoSchedule"
        ])
        self.assertIn("k3s.ergoshear.dev", config["tls-san"])
        self.assertIn("k3s-control-plane-01.tailb11f97.ts.net", config["tls-san"])

    def test_master_refresh_is_independent_of_minion_pillar(self):
        state = render("salt/master", "salt-master-01")
        self.assertIn("salt-master-tailscale-refresh", state)
        config = yaml.safe_load(options(state, "salt-master-config", "file.managed")["contents"])
        self.assertEqual(config["ext_pillar"], [{"k3s_cluster": []}])


class EnrollmentTests(unittest.TestCase):
    @patch.object(DEPLOY.subprocess, "run")
    def test_failed_remote_state_is_identified_and_secrets_are_redacted(self, execute):
        execute.return_value.returncode = 0
        execute.return_value.stdout = json.dumps({"mlops-node-0": {
            "test_|-tailscale-missing-enrollment_|-Missing enrollment pillar_|-fail": {
                "result": False, "name": "Missing enrollment pillar",
                "comment": "Failure!", "changes": {"stderr": "tskey-auth-test-secret"},
            },
        }})
        with self.assertRaises(RuntimeError) as error:
            DEPLOY.salt(["mlops-node-0"], "state.apply", "tailscale")
        self.assertIn("Missing enrollment pillar", str(error.exception))
        self.assertNotIn("tskey-auth-test-secret", str(error.exception))

    @patch.object(NODE.subprocess, "run")
    @patch.object(NODE, "run")
    @patch.object(NODE, "status", return_value={"BackendState": "Running"})
    def test_enrolled_node_is_idempotent(self, status, run, execute):
        run.return_value = json.dumps({
            "Hostname": "mlops-node-0",
            "AdvertiseTags": ["tag:k8s", "tag:salt-managed"],
        })
        self.assertFalse(NODE.enroll("mlops-node-0"))
        execute.assert_not_called()

    @patch.object(NODE.subprocess, "run")
    @patch.object(NODE, "status")
    def test_new_node_uses_key_file_and_correct_tags(self, status, execute):
        status.side_effect = [{"BackendState": "NeedsLogin"}, {"BackendState": "Running"}]
        self.assertTrue(NODE.enroll("mlops-node-9"))
        command = execute.call_args.args[0]
        self.assertIn("--auth-key=file:/etc/tailscale/salt-authkey", command)
        self.assertIn("--advertise-tags=tag:salt-managed", command)
        self.assertFalse(any("operator" in arg for arg in command))


if __name__ == "__main__":
    unittest.main()
