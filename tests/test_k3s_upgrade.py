import importlib.util
from pathlib import Path
import unittest

from jinja2 import Environment, StrictUndefined
import yaml


ROOT = Path(__file__).resolve().parents[1]


def load_upgrade_module():
    path = ROOT / "salt/tailscale/upgrade_k3s.py"
    spec = importlib.util.spec_from_file_location("upgrade_k3s", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def render_salt_state(state_file, node, pillar=None):
    path = ROOT / "salt/k3s" / state_file
    template = Environment(undefined=StrictUndefined).from_string(path.read_text())
    return yaml.safe_load(template.render(
        grains={"id": node},
        salt={
            "pillar.get": lambda key, default=None: (pillar or {}).get(key, default),
        },
    ))


def render_upgrade_state(node, pillar=None):
    return render_salt_state("upgrade.sls", node, pillar)


UPGRADE = load_upgrade_module()


class K3sUpgradeTests(unittest.TestCase):
    def test_latest_stable_redirect_must_be_a_k3s_release_tag(self):
        self.assertEqual(
            UPGRADE.parse_release_location(
                "https://github.com/k3s-io/k3s/releases/tag/v1.36.5+k3s1"
            ),
            "v1.36.5+k3s1",
        )
        for location in (
            "https://example.com/k3s/releases/tag/v1.36.5+k3s1",
            "https://github.com/k3s-io/k3s/releases/tag/latest",
        ):
            with self.subTest(location=location):
                with self.assertRaises(RuntimeError):
                    UPGRADE.parse_release_location(location)

    def test_exact_target_version_is_validated(self):
        self.assertEqual(
            UPGRADE.resolve_target_version("v1.37.1+k3s1"),
            "v1.37.1+k3s1",
        )
        with self.assertRaisesRegex(RuntimeError, "Invalid target K3s release version"):
            UPGRADE.resolve_target_version("v1.37.1; echo unsafe")

    def test_upgrade_plan_updates_server_then_agents_and_skips_current_nodes(self):
        nodes = {
            "k3s.ergoshear.dev": {"ready": True, "version": "v1.36.4+k3s1"},
            "mlops-node-0": {"ready": True, "version": "v1.36.4+k3s1"},
            "mlops-node-1": {"ready": True, "version": "v1.36.5+k3s1"},
        }
        self.assertEqual(
            UPGRADE.upgrade_plan(nodes, "v1.36.5+k3s1"),
            [
                ("k3s-control-plane-01", "k3s.ergoshear.dev"),
                ("mlops-node-0", "mlops-node-0"),
            ],
        )

    def test_upgrade_plan_is_a_noop_when_all_nodes_are_current(self):
        nodes = {
            name: {"ready": True, "version": "v1.36.5+k3s1"}
            for name in UPGRADE.EXPECTED_NODES
        }
        self.assertEqual(UPGRADE.upgrade_plan(nodes, "v1.36.5+k3s1"), [])

    def test_upgrade_plan_allows_one_minor_version_upgrade(self):
        nodes = {
            name: {"ready": True, "version": "v1.36.5+k3s1"}
            for name in UPGRADE.EXPECTED_NODES
        }
        self.assertEqual(
            UPGRADE.upgrade_plan(nodes, "v1.37.1+k3s1"),
            [
                ("k3s-control-plane-01", "k3s.ergoshear.dev"),
                ("mlops-node-0", "mlops-node-0"),
                ("mlops-node-1", "mlops-node-1"),
            ],
        )

    def test_upgrade_plan_rejects_unready_nodes_and_minor_version_skips(self):
        nodes = {
            name: {"ready": True, "version": "v1.36.5+k3s1"}
            for name in UPGRADE.EXPECTED_NODES
        }
        nodes["mlops-node-0"]["ready"] = False
        with self.assertRaisesRegex(RuntimeError, "must be Ready"):
            UPGRADE.upgrade_plan(nodes, "v1.37.1+k3s1")

        nodes["mlops-node-0"]["ready"] = True
        with self.assertRaisesRegex(RuntimeError, "one Kubernetes minor"):
            UPGRADE.upgrade_plan(nodes, "v1.38.1+k3s1")

    def test_upgrade_state_preserves_server_and_agent_roles(self):
        version = "v1.36.5+k3s1"
        server = render_upgrade_state(
            "k3s-control-plane-01", {"K3S_UPGRADE_VERSION": version}
        )
        agent = render_upgrade_state("mlops-node-0", {"K3S_UPGRADE_VERSION": version})
        server_env = next(
            item["env"] for item in server["k3s-upgrade-install"]["cmd.run"]
            if "env" in item
        )
        agent_env = next(
            item["env"] for item in agent["k3s-upgrade-install"]["cmd.run"]
            if "env" in item
        )
        self.assertIn({"INSTALL_K3S_VERSION": version}, server_env)
        self.assertNotIn({"INSTALL_K3S_EXEC": "agent"}, server_env)
        self.assertIn({"INSTALL_K3S_VERSION": version}, agent_env)
        self.assertIn({"INSTALL_K3S_EXEC": "agent"}, agent_env)

    def test_upgrade_state_fails_for_unsupported_nodes_or_missing_version(self):
        unsupported = render_upgrade_state(
            "mlops-node-4", {"K3S_UPGRADE_VERSION": "v1.36.5+k3s1"}
        )
        missing_version = render_upgrade_state("mlops-node-0")
        self.assertIn("test.fail_without_changes", unsupported["k3s-upgrade-prerequisites"])
        self.assertIn("test.fail_without_changes", missing_version["k3s-upgrade-prerequisites"])

    def test_passwd_recovery_is_limited_to_control_plane_and_backs_up_exact_file(self):
        server = render_salt_state("passwd_recovery.sls", "k3s-control-plane-01")
        agent = render_salt_state("passwd_recovery.sls", "mlops-node-0")
        recovery_command = server["k3s-passwd-recovery"]["cmd.run"][0]["name"]
        self.assertIn(
            "/var/lib/rancher/k3s/server/cred/passwd",
            recovery_command,
        )
        self.assertIn("cp -a --", recovery_command)
        self.assertIn('rm -- "$file"', recovery_command)
        self.assertIn("journalctl -u k3s", recovery_command)
        self.assertIn("cred/passwd newer than datastore", recovery_command)
        self.assertIn("K3s is active; skipping passwd recovery", recovery_command)
        self.assertTrue(any(
            "stateful" in argument
            for argument in server["k3s-passwd-recovery"]["cmd.run"]
        ))
        self.assertIn("systemctl start k3s", recovery_command)
        self.assertIn(
            "test.fail_without_changes",
            agent["k3s-passwd-recovery-prerequisites"],
        )

    def test_normal_workflow_recovers_before_deploying_k3s(self):
        workflow = yaml.load(
            (ROOT / ".github/workflows/salt.yml").read_text(),
            Loader=yaml.BaseLoader,
        )
        steps = workflow["jobs"]["salt-apply"]["steps"]
        recovery_step = next(
            index for index, step in enumerate(steps)
            if step.get("name") == "Recover K3s passwd if its startup guard fired"
        )
        deploy_step = next(
            index for index, step in enumerate(steps)
            if step.get("name") == "Enroll minions and deploy Kubernetes nodes"
        )
        self.assertLess(recovery_step, deploy_step)
        self.assertIn("--recover-passwd-only", steps[recovery_step]["run"])

    def test_manual_workflow_upgrade_is_opt_in_and_uses_salt_master(self):
        workflow = yaml.load(
            (ROOT / ".github/workflows/salt.yml").read_text(),
            Loader=yaml.BaseLoader,
        )
        inputs = workflow["on"]["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["update_k3s"]["default"], "false")
        self.assertEqual(inputs["k3s_version"]["default"], "")
        self.assertEqual(inputs["recover_k3s_passwd"]["default"], "false")
        self.assertEqual(inputs["inspect_k3s"]["default"], "false")
        job = workflow["jobs"]["k3s-update"]
        self.assertEqual(job["runs-on"], ["self-hosted", "salt-master-01"])
        self.assertIn("inputs.update_k3s == true", job["if"])
        self.assertIn("inputs.inspect_k3s != true", job["if"])
        upgrade_step = job["steps"][-1]
        self.assertIn("upgrade_k3s.py", upgrade_step["run"])
        self.assertEqual(
            upgrade_step["env"]["K3S_UPGRADE_VERSION"],
            "${{ inputs.k3s_version }}",
        )
        self.assertEqual(
            upgrade_step["env"]["RECOVER_K3S_PASSWD"],
            "${{ inputs.recover_k3s_passwd }}",
        )
        self.assertIn("--recover-passwd", upgrade_step["run"])
        self.assertIn('--version "$K3S_UPGRADE_VERSION"', upgrade_step["run"])
        inspect_job = workflow["jobs"]["k3s-inspect"]
        self.assertIn("inputs.inspect_k3s == true", inspect_job["if"])
        self.assertIn("jobs.lookup_jid", inspect_job["steps"][1]["run"])
        self.assertIn("inputs.update_k3s != true", workflow["jobs"]["salt-apply"]["if"])
        self.assertIn("inputs.inspect_k3s != true", workflow["jobs"]["salt-apply"]["if"])
