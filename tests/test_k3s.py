import copy
import io
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from urllib.error import HTTPError
from unittest.mock import patch

from jinja2 import Environment, StrictUndefined
import yaml


ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def compile_sls(path, node, pillar=None):
    template = Environment(undefined=StrictUndefined).from_string(path.read_text())
    return yaml.safe_load(template.render(
        grains={"id": node, "pythonversion": [3, 14, 0, "final", 0]},
        salt={"pillar.get": lambda key, default=None: (pillar or {}).get(key, default)},
    ))


def validate_sls(path, states):
    if path.name == "top.sls":
        if not isinstance(states, dict):
            raise AssertionError(f"{path} must compile to a mapping")
        return
    if not isinstance(states, dict):
        raise AssertionError(f"{path} must compile to a mapping")
    for state_id, declaration in states.items():
        if state_id == "include":
            if not isinstance(declaration, list):
                raise AssertionError(f"{path}: include must compile to a list")
            continue
        if not isinstance(declaration, dict) or not declaration:
            raise AssertionError(f"{path}: state {state_id!r} must compile to a mapping")
        for function, arguments in declaration.items():
            if not isinstance(function, str) or not isinstance(arguments, list):
                raise AssertionError(
                    f"{path}: state {state_id!r} has an invalid declaration"
                )
            if any(not isinstance(argument, dict) or len(argument) != 1
                   for argument in arguments):
                raise AssertionError(
                    f"{path}: state {state_id!r} has invalid function arguments"
                )


PROVISION = load("provision", "salt/tailscale/provision.py")
NODE = load("node", "salt/tailscale/node.py")
DEPLOY = load("deploy", "salt/tailscale/deploy.py")


def render(state, node, pillar=None, filename="init.sls"):
    return compile_sls(ROOT / "salt" / state / filename, node, pillar)


class PillarTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name)
        self.token = self.path / "token"
        self.token.write_text("test-k3s-token\n")
        patcher = patch.object(PROVISION, "TOKEN_FILE", self.token)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_token_pillar_preserves_existing_behavior(self):
        self.assertEqual(PROVISION.read_token(), "test-k3s-token")

    def test_missing_token_does_not_prevent_tailscale_bootstrap(self):
        self.token.unlink()
        self.assertEqual(PROVISION.read_token(), "")

    def test_empty_token_is_not_published(self):
        self.token.write_text("")
        self.assertEqual(PROVISION.read_token(), "")


class PolicyTests(unittest.TestCase):
    @patch.object(PROVISION.subprocess, "check_output")
    @patch.object(PROVISION, "api")
    def test_provision_scopes_credentials_and_is_idempotent(self, api, output):
        output.side_effect = lambda command, **kwargs: json.dumps(
            {"minions": ["mlops-node-0", "mlops-node-9"]}
            if command[0] == "salt-key" else PROVISION.pwd.getpwuid(os.getuid()).pw_name
        )
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
                root = path / "pillar" / "hosts"
                self.assertEqual(
                    {file.parent.name for file in root.glob("*/TS_API_KEY")},
                    {"salt-master-01"},
                )
                self.assertEqual(
                    {file.parent.name for file in root.glob("*/TAILSCALE_AUTH_KEY")},
                    {"salt-master-01", "mlops-node-0", "mlops-node-9"},
                )
                self.assertEqual((root / "salt-master-01/TS_API_KEY").read_text(), "test-api-key")
                for secret in root.glob("*/*"):
                    self.assertEqual(secret.stat().st_mode & 0o777, 0o600)
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

class ConfigurationTests(unittest.TestCase):
    def test_gpu_state_workflow_queues_state_runs(self):
        workflow = yaml.safe_load(
            (ROOT / ".github/workflows/salt.yml").read_text()
        )
        steps = workflow["jobs"]["salt-apply"]["steps"]
        commands = {
            step["name"]: step["run"]
            for step in steps
            if step.get("name") in {
                "Apply inference backend state to GPU minions",
                "Apply HTTPS reverse proxy to GPU minions",
                "Install Hugging Face credentials on model downloaders",
            }
        }

        self.assertIn(
            "state.apply mlops.backend queue=True",
            commands["Apply inference backend state to GPU minions"],
        )
        self.assertIn(
            "state.apply httpd queue=True",
            commands["Apply HTTPS reverse proxy to GPU minions"],
        )
        self.assertIn(
            "state.apply mlops.huggingface queue=True",
            commands["Install Hugging Face credentials on model downloaders"],
        )

    def test_qwen38_flash_next_preset_keeps_experts_on_cpu_and_uses_mtp(self):
        states = compile_sls(
            ROOT / "salt/mlops/rtx-4090/Qwen38-Flash-Next/init.sls",
            "mlops-node-6",
            {},
        )
        managed = states["rtx4090_models_preset_ini"]["file.managed"]
        contents = next(item["contents"] for item in managed if "contents" in item)
        self.assertIn("[Qwen3.8-Flash-Next-Q2_K_XL-256K]", contents)
        self.assertIn("cpu-moe = true", contents)
        self.assertIn("moe-cache-mib = 8192", contents)
        self.assertIn("load-mode = mmap", contents)
        self.assertIn("lazy-mode = on", contents)
        self.assertIn("spec-type = draft-mtp", contents)
        self.assertIn("spec-draft-n-max = 5", contents)
        self.assertIn("ctx-size = 262144", contents)
        self.assertIn(
            "model-draft = /home/mlops/models/Qwen3.8-Flash-Next-GGUF/MTP/"
            "mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf",
            contents,
        )
        self.assertIn("rtx4090_download_qwen38_flash_main", states)
        self.assertIn("rtx4090_download_qwen38_flash_mtp", states)
        self.assertIn("rtx4090_download_qwen38_flash_mmproj", states)

    def test_all_salt_states_compile_to_valid_state_data(self):
        variants = {
            "k3s/agent/init.sls": [
                ("mlops-node-0", {"K3S_AGENT_TOKEN": "test-token"}),
                ("mlops-node-0", {}),
                ("salt-master-01", {"K3S_AGENT_TOKEN": "test-token"}),
            ],
            "k3s/control-plane/init.sls": [
                ("k3s-control-plane-01", {}),
                ("mlops-node-0", {}),
            ],
            "httpd/init.sls": [
                ("mlops-node-4", {}),
                ("mlops-node-4", {"HTTPD_SERVER_NAME": "llm.example.test"}),
                ("mlops-node-4", {
                    "HTTPD_SERVER_NAME": "llm.example.test",
                    "HTTPD_SSL_CERT": "/tmp/cert.pem",
                    "HTTPD_SSL_KEY": "/tmp/key.pem",
                }),
                ("mlops-node-4", {
                    "HTTPD_SSL_CERT": "/tmp/cert.pem",
                    "HTTPD_SSL_KEY": "/tmp/key.pem",
                }),
                ("mlops-node-4", {"HTTPD_SSL_CERT": "/tmp/cert.pem"}),
            ],
            "k3s/network/init.sls": [
                ("k3s-control-plane-01", {}),
                ("mlops-node-0", {}),
            ],
            "mlops/backend/init.sls": [
                ("mlops-node-6", {}),
                ("mlops-node-6", {"INFERENCE_BACKEND_KEY": "test-key"}),
            ],
            "mlops/halo-395/init.sls": [("mlops-node-7", {})],
            "mlops/halo-495/init.sls": [("mlops-node-7", {})],
            "mlops/huggingface.sls": [
                ("mlops-node-7", {}),
                ("mlops-node-7", {"HUGGING_FACE_ACCESS_KEY": "test-key"}),
            ],
            "mlops/r9700/init.sls": [("mlops-node-7", {})],
            "mlops/rtx-4090/Muse-Glimmer-30b/init.sls": [("mlops-node-6", {})],
            "mlops/rtx-4090/MuseGlimmerQwen38Multi/init.sls": [("mlops-node-6", {})],
            "mlops/rtx-4090/Qwen38-27B-GSQ-RCO-IQ3_S/init.sls": [("mlops-node-6", {})],
            "mlops/rtx-4090/Qwen38-Flash-Next/init.sls": [("mlops-node-6", {})],
            "mlops/storage/client.sls": [
                ("mlops-node-5", {}),
                ("mlops-node-0", {}),
                ("salt-master-01", {}),
            ],
            "mlops/storage/init.sls": [
                ("mlops-node-5", {}),
                ("mlops-node-0", {}),
            ],
            "salt/master/init.sls": [
                ("salt-master-01", {}),
                ("salt-master-01", {"SALT_TAILNET_ENFORCE": True}),
            ],
            "system/tuned.sls": [
                ("mlops-node-0", {}),
                ("salt-master-01", {}),
            ],
            "tailscale/init.sls": [
                ("mlops-node-0", {}),
                ("mlops-node-0", {"TAILSCALE_AUTH_KEY": "test-key"}),
            ],
        }
        files = sorted((ROOT / "salt").rglob("*.sls"))
        self.assertTrue(files)
        for path in files:
            relative_path = path.relative_to(ROOT / "salt").as_posix()
            cases = variants.get(relative_path, [("mlops-node-0", {})])
            for node, pillar in cases:
                with self.subTest(state=relative_path, node=node, pillar=bool(pillar)):
                    states = compile_sls(path, node, pillar)
                    validate_sls(path, states)


    def test_httpd_proxy_uses_tailscale_name_and_certificate(self):
        states = compile_sls(ROOT / "salt/httpd/init.sls", "mlops-node-7", {})
        managed = states["httpd-proxy-config"]["file.managed"]
        contents = next(item["contents"] for item in managed if "contents" in item)
        self.assertIn("ServerName mlops-node-7.tailb11f97.ts.net", contents)
        certificate = states["httpd-proxy-tls-cert"]["cmd.run"][0]
        self.assertIn("tailscale cert", certificate["name"])
        self.assertIn(
            "--cert-file /etc/pki/tls/certs/httpd-proxy-mlops-node-7.crt",
            certificate["name"],
        )
        self.assertIn(
            "--key-file /etc/pki/tls/private/httpd-proxy-mlops-node-7.key",
            certificate["name"],
        )
        self.assertIn("mlops-node-7.tailb11f97.ts.net", certificate["name"])

    def test_httpd_proxy_requires_external_certificate_for_custom_name(self):
        states = compile_sls(
            ROOT / "salt/httpd/init.sls",
            "mlops-node-7",
            {"HTTPD_SERVER_NAME": "llm.example.test"},
        )
        self.assertIn("httpd-proxy-tailscale-name-required", states)
        self.assertNotIn("httpd-proxy-tls-cert", states)

        states = compile_sls(
            ROOT / "salt/httpd/init.sls",
            "mlops-node-7",
            {
                "HTTPD_SERVER_NAME": "llm.example.test",
                "HTTPD_SSL_CERT": "/tmp/cert.pem",
                "HTTPD_SSL_KEY": "/tmp/key.pem",
            },
        )
        self.assertNotIn("httpd-proxy-tls-cert", states)
        managed = states["httpd-proxy-config"]["file.managed"]
        contents = next(item["contents"] for item in managed if "contents" in item)
        self.assertIn("ServerName llm.example.test", contents)


class EnrollmentTests(unittest.TestCase):
    @patch.object(NODE.subprocess, "run")
    @patch.object(NODE, "run")
    def test_firewall_uses_actual_interface_zone_and_checks_both_scopes(self, run, execute):
        run.return_value = json.dumps([{"dev": "ens5", "metric": 100}])
        execute.return_value.returncode = 0
        execute.return_value.stdout = "FedoraServer\n"
        self.assertFalse(NODE.firewall("k3s-control-plane-01"))
        calls = [call.args[0] for call in execute.call_args_list]
        self.assertIn("--get-zone-of-interface=ens5", calls[0])
        self.assertEqual(len(calls[1:]), 6)
        self.assertTrue(all("--zone=FedoraServer" in command for command in calls[1:]))
        self.assertEqual(sum("--permanent" in command for command in calls[1:]), 3)

    @patch.object(NODE, "status")
    def test_network_config_uses_real_tailnet_ip_and_is_idempotent(self, status):
        status.return_value = {
            "BackendState": "Running",
            "TailscaleIPs": ["fd7a:115c:a1e0::1234", "100.90.80.70"],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "20-tailscale.yaml"
            with patch.object(NODE, "Path", return_value=path):
                self.assertTrue(NODE.configure("k3s-control-plane-01"))
                self.assertFalse(NODE.configure("k3s-control-plane-01"))
            self.assertEqual(yaml.safe_load(path.read_text()), {
                "node-ip": "100.90.80.70",
                "advertise-address": "100.90.80.70",
                "flannel-iface": "tailscale0",
            })

    @patch.object(NODE, "status", return_value={"BackendState": "NeedsLogin"})
    def test_network_config_refuses_unenrolled_or_non_cluster_nodes(self, status):
        with self.assertRaisesRegex(RuntimeError, "Running"):
            NODE.configure("mlops-node-0")
        with self.assertRaisesRegex(ValueError, "three Kubernetes"):
            NODE.configure("mlops-node-9")

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
