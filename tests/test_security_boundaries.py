import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_k3s import PROVISION, load, render, options


FIREWALL = load("inference_firewall", "salt/mlops/backend/firewall.py")


class SecurityBoundaryTests(unittest.TestCase):
    def test_only_workers_receive_agent_token_and_all_legacy_copies_are_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            hosts = root / "pillar/hosts"
            for node in ["retired-node", "mlops-node-9", "salt-master-01", "mlops-node-0"]:
                folder = hosts / node
                folder.mkdir(parents=True)
                (folder / "K3S_TOKEN").write_text("old-server-token")
                (folder / "K3S_AGENT_TOKEN").write_text("old-agent-token")
            with patch.object(PROVISION, "DIRECTORY", root):
                PROVISION.restrict_cluster_credentials(
                    "new-agent-token", PROVISION.pwd.getpwuid(os.getuid())
                )
            self.assertEqual(list(hosts.glob("*/K3S_TOKEN")), [])
            self.assertEqual(
                {p.parent.name for p in hosts.glob("*/K3S_AGENT_TOKEN")},
                {"mlops-node-0", "mlops-node-1"},
            )
            self.assertTrue(all(
                p.read_text() == "new-agent-token" for p in hosts.glob("*/K3S_AGENT_TOKEN")
            ))

    def test_no_fallback_to_server_token(self):
        self.assertIn(
            "k3s-agent-prerequisites",
            render("k3s/agent", "mlops-node-0", {"K3S_TOKEN": "server-secret"}),
        )
        server = render("k3s/control-plane", "k3s-control-plane-01")
        command = options(server, "k3s-publish-token", "cmd.run")
        self.assertNotIn("server/node-token", command["name"])
        self.assertIn("server/agent-token", command["name"])
        self.assertIn("agent-token-file:", options(
            server, "k3s-control-plane-config", "file.managed"
        )["contents"])

    def test_inference_filters_both_families_before_blanket_tailnet_accept(self):
        rules = FIREWALL.rules({"Peer": {
            "proxy": {"HostName": "egress-proxies-0", "Tags": ["tag:k8s"],
                      "DNSName": "egress-proxies-0.tailb11f97.ts.net.", "TailscaleIPs": [
                "100.80.230.67", "fd7a:115c:a1e0::d72f:e644",
            ]},
            "unrelated": {"HostName": "mlops-node-3", "TailscaleIPs": ["100.104.240.113"]},
            "imposter": {"HostName": "egress-proxies-0", "TailscaleIPs": ["100.1.2.3"]},
        }})
        self.assertIn("priority -20", rules)
        self.assertIn('iifname "tailscale0" ip saddr 100.80.230.67', rules)
        self.assertIn('iifname "tailscale0" ip6 saddr fd7a:115c:a1e0::d72f:e644', rules)
        self.assertNotIn("100.104.240.113", rules)
        self.assertNotIn("100.1.2.3", rules)
        self.assertTrue(rules.rstrip().endswith("tcp dport 8080 drop"))
        self.assertIn("tcp dport 8080 drop", FIREWALL.rules({}))

    def test_firewall_status_lookup_times_out_and_fails_closed(self):
        with (
            patch.object(
                FIREWALL.subprocess,
                "check_output",
                side_effect=subprocess.TimeoutExpired(["tailscale", "status", "--json"], 15),
            ) as status_lookup,
            patch.object(FIREWALL.subprocess, "run") as nft_run,
        ):
            FIREWALL.main()

        status_lookup.assert_called_once_with(["tailscale", "status", "--json"], timeout=15)
        self.assertTrue(all(call.kwargs["timeout"] == 15 for call in nft_run.call_args_list))
        command, options = nft_run.call_args
        self.assertEqual(command[0], ["nft", "-f", "-"])
        self.assertIn("tcp dport 8080 drop", options["input"])

    def test_firewall_apply_has_a_state_timeout(self):
        backend = render("mlops/backend", "mlops-node-6")
        apply_state = options(backend, "inference-firewall-apply", "cmd.run")
        self.assertEqual(apply_state["timeout"], 60)

    def test_all_inference_units_require_key_and_authenticated_warmup(self):
        for state, prefix in [
            ("halo-395", "halo395"), ("halo-495", "halo495"),
            ("r9700", "r9700"),
            ("rtx-4090/Qwen38-27B-GSQ-RCO-IQ3_S", "rtx4090"),
        ]:
            rendered = render("mlops/" + state, "mlops-node-7")
            unit = options(rendered, prefix + "_router_systemd_unit", "file.managed")
            if state == "halo-395":
                # The DiffusionGemma proxy reads its API key from this file.
                self.assertIn(
                    'DG_API_KEY_FILE=/home/mlops/.config/llama/backend-key',
                    unit["contents"],
                )
            else:
                self.assertIn(
                    "--api-key-file /home/mlops/.config/llama/backend-key",
                    unit["contents"],
                )
            self.assertIn({"cmd": "inference-backend-header"}, unit["require"])
            if "curl -s" in unit["contents"]:
                self.assertIn("--header @/home/mlops/.config/llama/auth-header", unit["contents"])


if __name__ == "__main__":
    unittest.main()
