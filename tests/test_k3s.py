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
CLUSTER = {"k3s-control-plane-01", "mlops-node-0", "mlops-node-1"}


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PROVISION = load("provision", "salt/tailscale/provision.py")
NODE = load("node", "salt/tailscale/node.py")
DEPLOY = load("deploy", "salt/tailscale/deploy.py")
VERIFY = load("verify", "salt/k3s/verify.py")


def render(state, node, pillar=None, filename="init.sls"):
    pillar = pillar or {}
    template = Environment(undefined=StrictUndefined).from_string(
        (ROOT / "salt" / state / filename).read_text()
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
    def test_provision_creates_tagged_keys_with_valid_descriptions(self, api, output):
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
    def test_existing_control_plane_name_is_discovered_without_renaming_it(self):
        nodes = [{
            "metadata": {
                "name": name,
                "labels": {"node-role.kubernetes.io/control-plane": "true"} if index == 0 else {},
            },
            "status": {"addresses": [{"type": "InternalIP", "address": f"100.90.80.{70 + index}"}]},
        } for index, name in enumerate(["existing-server-hostname", *VERIFY.WORKERS])]
        self.assertEqual(set(VERIFY.node_addresses(nodes)), {
            "existing-server-hostname", "mlops-node-0", "mlops-node-1"
        })
        nodes[1]["status"]["addresses"][0]["address"] = "192.168.202.10"
        with self.assertRaisesRegex(RuntimeError, "Tailscale InternalIP"):
            VERIFY.node_addresses(nodes)

    def test_network_probes_are_pinned_to_each_worker_without_service_tokens(self):
        for index, node in enumerate(VERIFY.WORKERS):
            probe = VERIFY.probe("test-network-namespace", index)
            self.assertEqual(probe["metadata"]["namespace"], "test-network-namespace")
            self.assertEqual(probe["spec"]["nodeName"], node)
            self.assertFalse(probe["spec"]["automountServiceAccountToken"])
            self.assertTrue(probe["spec"]["containers"][0]["securityContext"]["runAsNonRoot"])
            self.assertEqual(
                probe["spec"]["containers"][0]["readinessProbe"]["httpGet"]["port"], 8080
            )

    def test_targeting_and_fail_closed_guards(self):
        top = yaml.safe_load((ROOT / "salt/top.sls").read_text())["base"]
        self.assertIn("tailscale", top["*"])
        self.assertIn("mlops.rtx-4090", top["mlops-node-6"])
        self.assertIn("mlops.storage", top["mlops-node-5"])
        self.assertEqual(top["mlops-node-*"], [
            {"match": "glob"},
            "mlops.storage.client",
        ])
        self.assertTrue((ROOT / "salt/mlops/rtx-4090/init.sls").is_file())
        self.assertFalse((ROOT / "salt/mlops/rtx-4090/ini.sls").exists())
        self.assertEqual(
            {node for node, states in top.items() if "k3s.agent" in states},
            {"mlops-node-0", "mlops-node-1"},
        )
        for node in ["mlops-node-2", "mlops-nodes-0", "salt-master-01"]:
            self.assertEqual(
                set(render("k3s/agent", node, {"K3S_AGENT_TOKEN": "test"})),
                {"k3s-agent-prerequisites"},
            )
        self.assertEqual(
            set(render("mlops/storage", "mlops-node-4")),
            {"mlops-storage-target-guard"},
        )
        self.assertIn("k3s-agent-prerequisites", render("k3s/agent", "mlops-node-0"))
        self.assertIn("tailscale-missing-enrollment", render("tailscale", "mlops-node-0"))

    def test_storage_state_detaches_and_mounts_the_specific_disk(self):
        state = render("mlops/storage", "mlops-node-5")
        disk = (
            "/dev/disk/by-id/"
            "ata-WDC_WD40EZAZ-19SF3B0_WD-WX42DA063C4T-part1"
        )

        self.assertTrue({
            "mlops-storage-vgreduce",
            "mlops-storage-pv-absent",
            "mlops-storage-filesystem",
            "mlops-storage-mount",
        } <= set(state))
        vgreduce = options(state, "mlops-storage-vgreduce", "cmd.run")
        self.assertEqual(vgreduce["name"], f"vgreduce fedora {disk}")
        self.assertIn(disk, vgreduce["onlyif"])

        pv = options(state, "mlops-storage-pv-absent", "lvm.pv_absent")
        self.assertEqual(pv["name"], disk)
        self.assertEqual(pv["require"], [{"cmd": "mlops-storage-vgreduce"}])

        filesystem = options(state, "mlops-storage-filesystem", "blockdev.formatted")
        self.assertEqual(filesystem["name"], disk)
        self.assertEqual(filesystem["fs_type"], "ext4")
        self.assertFalse(filesystem["force"])
        self.assertEqual(
            filesystem["require"], [{"lvm": "mlops-storage-pv-absent"}]
        )

        mount = options(state, "mlops-storage-mount", "mount.mounted")
        self.assertEqual(mount["name"], "/srv/storage")
        self.assertEqual(mount["device"], disk)
        self.assertEqual(mount["fstype"], "ext4")
        self.assertTrue(mount["persist"])
        self.assertEqual(mount["pass_num"], 2)
        self.assertEqual(mount["require"], [{"blockdev": "mlops-storage-filesystem"}])

    def test_storage_server_exports_read_write_only_for_mlop_node_names(self):
        state = render("mlops/storage", "mlops-node-5")
        directory = options(state, "mlops-storage-directory-permissions", "file.directory")
        self.assertEqual(directory["name"], "/srv/storage")
        self.assertEqual(directory["user"], "mlops")
        self.assertEqual(directory["group"], "mlops")
        self.assertEqual(directory["dir_mode"], "0770")

        context = options(state, "mlops-storage-selinux-context", "selinux.fcontext_policy_present")
        self.assertEqual(context["name"], "/srv/storage(/.*)?")
        self.assertEqual(context["sel_type"], "public_content_rw_t")

        exports = options(state, "mlops-storage-nfs-exports", "file.managed")
        self.assertIn(
            "/srv/storage mlops-node-*.lan(rw,sync,root_squash,no_subtree_check,fsid=0)",
            exports["contents"],
        )
        firewall = options(state, "mlops-storage-nfs-firewall", "firewalld.present")
        self.assertEqual(firewall["rich_rules"], [
            'rule family="ipv4" source address="192.168.202.0/24" '
            'port port="2049" protocol="tcp" accept',
        ])
        self.assertFalse(firewall["prune_rich_rules"])

        service = options(state, "mlops-storage-nfs-server", "service.running")
        self.assertEqual(service["name"], "nfs-server")
        self.assertTrue(service["enable"])

    def test_storage_clients_mount_nfs_except_on_local_storage_host(self):
        state = render(
            "mlops/storage", "mlops-node-0", filename="client.sls"
        )
        self.assertEqual(set(state), {
            "mlops-storage-client-package",
            "mlops-storage-client-mount",
        })
        mount = options(state, "mlops-storage-client-mount", "mount.mounted")
        self.assertEqual(mount["name"], "/srv/storage")
        self.assertEqual(mount["device"], "mlops-node-5.lan:/")
        self.assertEqual(mount["fstype"], "nfs")
        self.assertIn("vers=4.1", mount["opts"])
        self.assertIn("rw", mount["opts"])
        self.assertTrue(mount["persist"])
        self.assertTrue(mount["mount"])
        self.assertEqual(mount["retry"], {"attempts": 10, "interval": 30})

        local = render(
            "mlops/storage", "mlops-node-5", filename="client.sls"
        )
        self.assertEqual(set(local), {"mlops-storage-client-local"})
        self.assertIn(
            "mlops-storage-client-target-guard",
            render("mlops/storage", "salt-master-01", filename="client.sls"),
        )

    def test_agent_configs_protect_token_and_use_tailnet(self):
        token = 'test:"token\\with\nspecial-characters'
        for node in CLUSTER - {"k3s-control-plane-01"}:
            state = render("k3s/agent", node, {"K3S_AGENT_TOKEN": token})
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
        self.assertEqual(command["shell"], "/bin/sh")

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
        packages = options(state, "k3s-pkgs-install", "pkg.installed")["names"]
        self.assertNotIn("kubectl", packages)
        self.assertEqual(
            options(state, "k3s-kubectl", "file.symlink")["target"],
            "/usr/local/bin/k3s",
        )
        config = yaml.safe_load(
            options(state, "k3s-control-plane-config", "file.managed")["contents"]
        )
        self.assertEqual(config["node-taint"], [
            "node-role.kubernetes.io/control-plane=true:NoSchedule"
        ])
        self.assertIn("k3s.ergoshear.dev", config["tls-san"])
        self.assertIn("k3s-control-plane-01.tailb11f97.ts.net", config["tls-san"])

    def test_traefik_helm_jobs_use_the_patched_image(self):
        state = render("k3s/control-plane", "k3s-control-plane-01")
        image = "rancher/klipper-helm:v0.13.3-build20261014"
        for state_id, chart in (
            ("k3s-traefik-helm-job-image", "traefik"),
            ("k3s-traefik-crd-helm-job-image", "traefik-crd"),
        ):
            command = options(state, state_id, "cmd.run")
            self.assertIn(f"patch helmcharts.helm.cattle.io {chart}", command["name"])
            self.assertIn(image, command["name"])
            self.assertIn(image, command["unless"])

    def test_master_refresh_is_independent_of_minion_pillar(self):
        state = render("salt/master", "salt-master-01")
        self.assertIn("salt-master-tailscale-refresh", state)
        config = yaml.safe_load(options(state, "salt-master-config", "file.managed")["contents"])
        self.assertEqual(config["ext_pillar"][0], {"file_tree": {
            "root_dir": "/etc/salt/tailscale/pillar",
            "follow_dir_links": False,
            "template": True,
            "render_default": "yaml",
        }})


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
