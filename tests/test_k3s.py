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

from jinja2 import Environment, FileSystemLoader, StrictUndefined
import yaml


ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def compile_sls(path, node, pillar=None):
    template = Environment(
        undefined=StrictUndefined, loader=FileSystemLoader(ROOT / "salt"),
    ).from_string(path.read_text())
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
        output.side_effect = lambda command, **kwargs: (
            json.dumps({"minions": ["mlops-node-0", "mlops-node-9"]})
            if command[0] == "salt-key"
            else PROVISION.pwd.getpwuid(os.getuid()).pw_name
        )
        policy = {
            "tagOwners": {
                "tag:salt-managed": ["autogroup:admin"],
                "tag:k8s": ["autogroup:admin"],
            },
            "grants": [copy.deepcopy(PROVISION.GRANT)],
        }

        def api_response(key, path, payload=None, method=None, headers=None):
            if path == "/devices":
                return ({
                    "devices": [{
                        "hostname": "mlops-node-3",
                        "addresses": [
                            "100.104.240.113", "fd7a:115c:a1e0::f2f:f072",
                        ],
                    }],
                }, {})
            if path == "/acl" and method == "POST":
                policy.clear()
                policy.update(copy.deepcopy(payload))
                return ({}, {})
            if path == "/acl":
                return (copy.deepcopy(policy), {"ETag": "test-etag"})
            return ({"key": "tskey-auth-test"}, {})

        api.side_effect = api_response
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "api-key").write_text("test-api-key")
            with patch.object(PROVISION, "DIRECTORY", path):
                PROVISION.provision()
                self.assertEqual(policy["hosts"], {
                    "mlops-node-3-studioflow-v4": "100.104.240.113",
                    "mlops-node-3-studioflow-v6": "fd7a:115c:a1e0::f2f:f072",
                })
                self.assertIn({
                    "src": ["tag:k8s"],
                    "dst": [
                        "mlops-node-3-studioflow-v4",
                        "mlops-node-3-studioflow-v6",
                    ],
                    "ip": ["tcp:8001", "tcp:8002", "tcp:8003"],
                }, policy["grants"])
                self.assertIn(PROVISION.SSH_RULE, policy["ssh"])
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
                self.assertEqual(api.call_count, calls + 2)

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
        managed_hosts = {
            "mlops-node-3-studioflow-v4": "100.104.240.113",
            "mlops-node-3-studioflow-v6": "fd7a:115c:a1e0::f2f:f072",
        }
        original = copy.deepcopy(policy)
        merged = PROVISION.merge_policy(policy, managed_hosts)
        self.assertEqual(PROVISION.SSH_RULE, {
            "action": "check",
            "src": ["christopher@agilityqa.com"],
            "dst": ["tag:salt-managed"],
            "users": ["autogroup:nonroot"],
        })
        self.assertEqual(merged["tagOwners"]["tag:k8s"], ["tag:k8s-operator"])
        self.assertEqual(merged["acls"], original["acls"])
        self.assertIn(original["ssh"][0], merged["ssh"])
        self.assertIn(PROVISION.SSH_RULE, merged["ssh"])
        self.assertEqual(merged["grants"][0], original["grants"][0])
        self.assertIn(PROVISION.GRANT, merged["grants"])
        self.assertEqual(merged["hosts"], managed_hosts)
        self.assertIn({
            "src": ["tag:k8s"],
            "dst": sorted(managed_hosts),
            "ip": ["tcp:8001", "tcp:8002", "tcp:8003"],
        }, merged["grants"])
        self.assertEqual(
            PROVISION.merge_policy(copy.deepcopy(merged), managed_hosts), merged,
        )
        self.assertEqual(
            PROVISION.inference_hosts({"devices": [{
                "hostname": "mlops-node-3",
                "addresses": [
                    "100.104.240.113", "fd7a:115c:a1e0::f2f:f072",
                ],
            }]}),
            managed_hosts,
        )
        with self.assertRaisesRegex(RuntimeError, "found 0"):
            PROVISION.inference_hosts({"devices": []})

class ConfigurationTests(unittest.TestCase):
    def test_mlops_node_five_is_a_supported_k3s_agent(self):
        agent = compile_sls(
            ROOT / "salt/k3s/agent/init.sls",
            "mlops-node-5",
            {"K3S_AGENT_TOKEN": "test-agent-token"},
        )
        self.assertIn("k3s-agent-config", agent)
        upgrade = compile_sls(
            ROOT / "salt/k3s/upgrade.sls",
            "mlops-node-5",
            {"K3S_UPGRADE_VERSION": "v1.37.1+k3s1"},
        )
        self.assertEqual(
            upgrade["k3s-upgrade-install"]["cmd.run"][1]["env"][-1],
            {"INSTALL_K3S_EXEC": "agent"},
        )

    def test_k3s_installers_only_run_when_binary_is_missing(self):
        control_plane = compile_sls(
            ROOT / "salt/k3s/control-plane/init.sls",
            "k3s-control-plane-01",
        )
        agent = compile_sls(
            ROOT / "salt/k3s/agent/init.sls",
            "mlops-node-0",
            {"K3S_AGENT_TOKEN": "test-agent-token"},
        )
        self.assertEqual(
            control_plane["k3s-install"]["cmd.run"][1]["unless"],
            "test -x /usr/local/bin/k3s",
        )
        self.assertEqual(
            agent["k3s-agent-install"]["cmd.run"][2]["unless"],
            "test -x /usr/local/bin/k3s",
        )

    def test_tailscale_nodes_track_latest_package_and_restart_after_upgrade(self):
        states = render(
            "tailscale",
            "mlops-node-3",
            {"TAILSCALE_AUTH_KEY": "test-auth-key"},
        )
        self.assertEqual(
            states["tailscale-package"]["pkg.latest"],
            [{"name": "tailscale"}, {"require": [{"file": "tailscale-repository"}]}],
        )
        self.assertIn(
            {"pkg": "tailscale-package"},
            states["tailscale-service"]["service.running"][-1]["watch"],
        )

    def test_r9700_compatibility_entry_preserves_moved_model_state(self):
        self.assertEqual(
            render("mlops/r9700", "mlops-node-4"),
            render("mlops/r9700/Qwen3.6-35B-A3B-DFlash", "mlops-node-4"),
        )

    def test_kokoro_rocm_service_is_scoped_and_loopback_only(self):
        state_path = ROOT / "salt/mlops/rx9070/kokoro-fastapi-gpu/init.sls"
        states = compile_sls(state_path, "mlops-node-3")
        unit = next(
            item["contents"]
            for item in states["kokoro_systemd_unit"]["file.managed"]
            if "contents" in item
        )
        self.assertIn("ghcr.io/remsky/kokoro-fastapi-rocm:latest", unit)
        self.assertIn("--device=/dev/kfd --device=/dev/dri", unit)
        self.assertIn("--publish=127.0.0.1:8880:8880", unit)
        self.assertNotIn("--gpus all", unit)
        self.assertIn("kokoro_service", states)
        serve = states["kokoro_tailscale_serve"]["cmd.run"]
        self.assertIn(
            {"name": "tailscale serve --bg --https=443 http://127.0.0.1:8880"},
            serve,
        )
        self.assertIn("kokoro_target_guard", compile_sls(state_path, "mlops-node-4"))

    def test_kokoro_disable_state_removes_runtime_and_route_only(self):
        state_path = ROOT / "salt/mlops/rx9070/disabled/kokoro-fastapi-gpu.sls"
        states = compile_sls(state_path, "mlops-node-3")
        self.assertEqual(
            states["rx9070_kokoro_system_stop_1"]["cmd.run"][0]["name"],
            "systemctl disable --now kokoro-fastapi.service",
        )
        self.assertEqual(
            states["rx9070_kokoro_system_unit_absent_1"]["file.absent"][0]["name"],
            "/etc/systemd/system/kokoro-fastapi.service",
        )
        self.assertEqual(
            states["rx9070_kokoro_route_absent_1"]["cmd.run"][0]["name"],
            "tailscale serve --https=443 / off",
        )
        self.assertIn(
            "rx9070_kokoro_target_guard",
            compile_sls(state_path, "mlops-node-4"),
        )

    def test_studioflow_tailscale_serve_uses_litellm_ports(self):
        state_path = ROOT / "salt/mlops/rx9070/studioflow-tts/init.sls"
        states = compile_sls(state_path, "mlops-node-3")
        expected = {
            "studioflow_fish_speech_tailscale_serve":
                "tailscale serve --bg --https=8001 http://127.0.0.1:8001",
            "studioflow_zonos_tailscale_serve":
                "tailscale serve --bg --https=8002 http://127.0.0.1:8002",
            "studioflow_whisper_tailscale_serve":
                "tailscale serve --bg --https=8003 http://127.0.0.1:8003",
        }
        for state_id, command in expected.items():
            with self.subTest(state=state_id):
                self.assertEqual(states[state_id]["cmd.run"][0]["name"], command)

    def test_studioflow_checkout_uses_ssh_deploy_key(self):
        state_path = ROOT / "salt/mlops/rx9070/studioflow-tts/init.sls"
        states = compile_sls(state_path, "mlops-node-3")
        managed = states["studioflow_tts_checkout_helper"]["file.managed"]
        helper = next(item["contents"] for item in managed if "contents" in item)
        self.assertIn("git@github.com:ergoshear/studioflow-tts.git", helper)
        self.assertIn("/home/mlops/.ssh/studioflow-tts", helper)
        self.assertIn("StrictHostKeyChecking=yes", helper)
        self.assertNotIn("STUDIOFLOW_GITHUB_TOKEN", helper)

    def test_studioflow_images_rebuild_when_missing_or_checkout_changes(self):
        state_path = ROOT / "salt/mlops/rx9070/studioflow-tts/init.sls"
        states = compile_sls(state_path, "mlops-node-3")
        build = states["studioflow_tts_build_images"]["cmd.run"]
        command = next(item["name"] for item in build if "name" in item)
        unless = next(item["unless"] for item in build if "unless" in item)
        self.assertIn("container-images-revision", command)
        self.assertIn("git -C /opt/studioflow-tts rev-parse HEAD", unless)
        for image in ("fish-speech", "zonos", "whisper"):
            with self.subTest(image=image):
                self.assertIn(f"podman image exists localhost/studioflow-{image}:latest", unless)

    def test_studioflow_container_units_use_compatible_ipc_options(self):
        state_path = ROOT / "salt/mlops/rx9070/studioflow-tts/init.sls"
        states = compile_sls(state_path, "mlops-node-3")
        for state_id in (
            "studioflow_fish_speech_unit",
            "studioflow_zonos_unit",
            "studioflow_whisper_unit",
        ):
            managed = states[state_id]["file.managed"]
            contents = next(item["contents"] for item in managed if "contents" in item)
            with self.subTest(state=state_id):
                self.assertIn("--ipc=host", contents)
                self.assertNotIn("--shm-size=", contents)

    def test_studioflow_whisper_uses_intel_gpu_device(self):
        state_path = ROOT / "salt/mlops/rx9070/studioflow-tts/init.sls"
        states = compile_sls(state_path, "mlops-node-3")
        managed = states["studioflow_whisper_unit"]["file.managed"]
        contents = next(item["contents"] for item in managed if "contents" in item)
        self.assertIn("--device=/dev/dri/renderD128", contents)
        self.assertNotIn("--device=/dev/kfd", contents)

    def test_studioflow_disable_state_removes_custom_https_ports(self):
        state_path = ROOT / "salt/mlops/rx9070/disabled/studioflow-tts.sls"
        states = compile_sls(state_path, "mlops-node-3")
        for index, port in enumerate((8001, 8002, 8003), start=1):
            with self.subTest(port=port):
                self.assertEqual(
                    states[f"rx9070_studioflow_route_absent_{index}"]["cmd.run"][0]["name"],
                    f"tailscale serve --https={port} / off",
                )

    def test_each_deployment_has_a_matching_disabled_state(self):
        disabled_states = [
            ("mlops/halo-395/DiffusionGemma-26B", "mlops-node-7"),
            ("mlops/halo-395/Ornith-1-5-35B", "mlops-node-7"),
            ("mlops/halo-495/Qwen3-8-27B-GSQ-RCO-IQ3_S", "mlops-node-9"),
            ("mlops/halo-495/Qwen3.6-35B", "mlops-node-9"),
            ("mlops/r9700", "mlops-node-4"),
            ("mlops/r9700/Qwen3.6-35B-A3B-DFlash", "mlops-node-4"),
            ("mlops/r9700/StrataQwen38-Flash-Next", "mlops-node-4"),
            ("mlops/rtx-4090/Muse-Glimmer-30b", "mlops-node-6"),
            ("mlops/rtx-4090/MuseGlimmerQwen38Multi", "mlops-node-6"),
            ("mlops/rtx-4090/Qwen38-27B-GSQ-RCO-IQ3_S", "mlops-node-6"),
            ("mlops/rtx-4090/Qwen38-Flash-Next", "mlops-node-6"),
            ("mlops/rtx-4090/StrataQwen38-Flash-Next", "mlops-node-6"),
            ("mlops/rx9070/kokoro-fastapi-gpu", "mlops-node-3"),
            ("mlops/rx9070/studioflow-tts", "mlops-node-3"),
        ]
        for deployment, node in disabled_states:
            deployment_path = ROOT / "salt" / Path(*deployment.split("/"))
            if deployment_path.name == "r9700":
                disabled_path = deployment_path / "disabled" / "init.sls"
            else:
                disabled_path = (
                    deployment_path.parent
                    / "disabled"
                    / f"{deployment_path.name}.sls"
                )
            with self.subTest(deployment=deployment):
                self.assertTrue(disabled_path.is_file())
                states = compile_sls(disabled_path, node)
                self.assertTrue(any(
                    "file.absent" in declaration
                    for declaration in states.values()
                ))

    def test_top_file_references_existing_states(self):
        root = ROOT / "salt"
        top = compile_sls(root / "top.sls", "mlops-node-4")
        for targets in top.values():
            for declarations in targets.values():
                for declaration in declarations:
                    if not isinstance(declaration, str):
                        continue
                    path = root / declaration.replace(".", "/")
                    with self.subTest(state=declaration):
                        self.assertTrue(
                            path.with_suffix(".sls").is_file()
                            or (path / "init.sls").is_file(),
                            f"Top file references missing state: {declaration}",
                        )

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
            "mlops/r9700/Qwen3.6-35B-A3B-DFlash/init.sls": [("mlops-node-4", {})],
            "mlops/r9700/StrataQwen38-Flash-Next/init.sls": [
                ("mlops-node-4", {}),
                ("mlops-node-6", {}),
            ],
            "mlops/rtx-4090/Muse-Glimmer-30b/init.sls": [("mlops-node-6", {})],
            "mlops/rtx-4090/MuseGlimmerQwen38Multi/init.sls": [("mlops-node-6", {})],
            "mlops/rtx-4090/Qwen38-27B-GSQ-RCO-IQ3_S/init.sls": [("mlops-node-6", {})],
            "mlops/rtx-4090/Qwen38-Flash-Next/init.sls": [("mlops-node-6", {})],
            "mlops/rtx-4090/StrataQwen38-Flash-Next/init.sls": [
                ("mlops-node-6", {}),
                ("mlops-node-0", {}),
            ],
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
    @patch.object(DEPLOY, "salt")
    def test_passwd_recovery_targets_only_k3s_control_plane(self, salt):
        DEPLOY.recover_passwd()
        salt.assert_called_once_with(
            ["k3s-control-plane-01"],
            "state.apply",
            "k3s.passwd_recovery",
            "queue=True",
        )

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
        with self.assertRaisesRegex(ValueError, "four Kubernetes"):
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
            "RunSSH": True,
        })
        self.assertFalse(NODE.enroll("mlops-node-0"))
        execute.assert_not_called()

    @patch.object(NODE.subprocess, "run")
    @patch.object(NODE, "run")
    @patch.object(NODE, "status", return_value={"BackendState": "Running"})
    def test_enrolled_node_enables_tailscale_ssh(self, status, run, execute):
        run.side_effect = [
            json.dumps({
                "Hostname": "mlops-node-0",
                "AdvertiseTags": ["tag:k8s", "tag:salt-managed"],
                "RunSSH": False,
            }),
            json.dumps({"RunSSH": True}),
        ]
        self.assertTrue(NODE.enroll("mlops-node-0"))
        self.assertEqual(execute.call_args.args[0], ["tailscale", "set", "--ssh"])

    @patch.object(NODE.subprocess, "run")
    @patch.object(NODE, "run")
    @patch.object(NODE, "status", return_value={"BackendState": "Running"})
    def test_tag_reauthentication_also_enables_tailscale_ssh(
        self, status, run, execute
    ):
        run.side_effect = [
            json.dumps({
                "Hostname": "mlops-node-0",
                "AdvertiseTags": ["tag:old"],
                "RunSSH": False,
            }),
            json.dumps({
                "Hostname": "mlops-node-0",
                "AdvertiseTags": ["tag:k8s", "tag:salt-managed"],
                "RunSSH": True,
            }),
        ]
        self.assertTrue(NODE.enroll("mlops-node-0"))
        command = execute.call_args.args[0]
        self.assertIn("--force-reauth", command)
        self.assertIn("--ssh", command)

    @patch.object(NODE.subprocess, "run")
    @patch.object(NODE, "run", return_value=json.dumps({"RunSSH": True}))
    @patch.object(NODE, "status")
    def test_new_node_uses_key_file_correct_tags_and_tailscale_ssh(
        self, status, run, execute
    ):
        status.side_effect = [{"BackendState": "NeedsLogin"}, {"BackendState": "Running"}]
        self.assertTrue(NODE.enroll("mlops-node-9"))
        command = execute.call_args.args[0]
        self.assertIn("--auth-key=file:/etc/tailscale/salt-authkey", command)
        self.assertIn("--advertise-tags=tag:salt-managed", command)
        self.assertIn("--ssh", command)
        self.assertFalse(any("operator" in arg for arg in command))


if __name__ == "__main__":
    unittest.main()
