import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from test_k3s import load, render


MANAGER = load("strata_manager", "salt/mlops/strata/manage.py")
BACKUP_MANIFEST = MANAGER.backup_manifest


class StrataTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        for name, value in {
            "HOME": root / "home", "BACKUP": root / "backup",
            "SHARE": root / "home/share", "CLI": root / "home/share/terminal/current/bin/strata",
            "PROFILE": root / "home/config/profile.json",
        }.items():
            patcher = patch.object(MANAGER, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        MANAGER.BACKUP.mkdir()
        MANAGER.CLI.parent.mkdir(parents=True)
        MANAGER.CLI.touch()
        self.profile = {
            "api_key": "test-private-key", "args": ["--expert-profile", "/old/profile"],
            "vision": {"exe": "/old/strata-vision"},
        }
        source = MANAGER.BACKUP / "setup/launch.json"
        source.parent.mkdir()
        source.write_text(json.dumps(self.profile))
        self.entries = {"setup/launch.json": MANAGER.sha256(source)}
        patcher = patch.object(MANAGER, "backup_manifest", return_value=self.entries)
        patcher.start()
        self.addCleanup(patcher.stop)

    def report(self, status="current"):
        return {
            "ok": True, "engine": {"status": status, "installed": {"folder": "new-cuda"}},
            "control": {"status": "current"}, "serving": [],
        }

    def test_state_checks_updates_on_every_apply_and_uses_managed_service(self):
        states = render("mlops/rtx-4090/StrataQwen38-Flash-Next", "mlops-node-6")
        update = states["strata-update"]["cmd.run"]
        self.assertFalse(any("unless" in item or "onchanges" in item for item in update))
        unit = next(item["contents"] for item in states["strata-unit"]["file.managed"]
                    if "contents" in item)
        self.assertIn("--parallel 3", unit)
        self.assertIn("User=mlops", unit)
        self.assertIn("WantedBy=multi-user.target", unit)
        self.assertIn(
            "ExecStart=/usr/bin/sh "
            "/home/mlops/.local/share/strata/terminal/current/bin/strata serve",
            unit,
        )
        self.assertIn("strata-target-guard",
                      render("mlops/rtx-4090/StrataQwen38-Flash-Next", "mlops-node-0"))

    def test_r9700_state_selects_hip_and_checks_amd_device_access(self):
        states = render("mlops/r9700/StrataQwen38-Flash-Next", "mlops-node-4")
        packages = next(item["names"] for item in states["strata-packages"]["pkg.installed"]
                        if "names" in item)
        self.assertIn("libatomic", packages)
        update = states["strata-update"]["cmd.run"]
        self.assertIn({"name": "/usr/local/libexec/strata-manage update --backend hip --max-context 262144"}, update)

        self.assertFalse(any("unless" in item or "onchanges" in item for item in update))
        ready = states["strata-gpu-ready"]["cmd.run"]
        command = next(item["name"] for item in ready if "name" in item)
        self.assertIn("/dev/kfd", command)
        self.assertIn("/dev/dri/renderD128", command)
        self.assertIn({"runas": "mlops"}, ready)
        self.assertIn({"remove_groups": False}, states["strata-gpu-groups"]["user.present"])
        self.assertIn("strata-target-guard",
                      render("mlops/r9700/StrataQwen38-Flash-Next", "mlops-node-6"))

    @patch.object(MANAGER, "run_json")
    @patch.object(MANAGER.subprocess, "run")
    def test_node6_context_override_is_persistent_and_idempotent(self, run, api):
        api.return_value = self.report()
        states = render("mlops/rtx-4090/StrataQwen38-Flash-Next", "mlops-node-6")
        self.assertIn(
            {"name": "/usr/local/libexec/strata-manage update --backend cuda --max-context 131072"},
            states["strata-update"]["cmd.run"],
        )
        self.assertIn({"name": "/usr/local/libexec/strata-manage health --max-context 131072"},
                      states["strata-ready"]["cmd.run"])
        self.assertTrue(MANAGER.update("cuda", 131072))
        config = json.loads(MANAGER.PROFILE.read_text())
        self.assertEqual(config["args"][config["args"].index("--max-context") + 1], "131072")
        self.assertEqual(config["args"], config["args_written"])
        self.assertFalse(MANAGER.update("cuda", 131072))

    @patch.object(MANAGER, "run_json")
    @patch.object(MANAGER.subprocess, "run")
    def test_current_release_is_checked_without_restarting_and_key_is_preserved(self, run, api):
        api.return_value = self.report()
        self.assertTrue(MANAGER.update())
        self.assertFalse(MANAGER.update())
        run.assert_not_called()
        self.assertEqual(api.call_count, 2)
        self.assertTrue(all("--check" in call.args[0] for call in api.call_args_list))
        config = json.loads(MANAGER.PROFILE.read_text())
        self.assertEqual(config["api_key"], self.profile["api_key"])
        self.assertEqual(config["exe"], "component:strata-engine")
        self.assertTrue(config["vision"]["exe"].endswith("/new-cuda/strata-vision"))
        self.assertEqual(MANAGER.PROFILE.stat().st_mode & 0o777, 0o600)

    @patch.object(MANAGER, "run_json")
    @patch.object(MANAGER.subprocess, "run")
    def test_available_update_stops_owned_service_and_updates_before_configuring(self, run, api):
        api.side_effect = [
            self.report("available"), self.report("available"),
            {"ok": True}, self.report(),
        ]
        self.assertTrue(MANAGER.update())
        run.assert_called_once_with(
            ["sudo", "-n", "systemctl", "stop", MANAGER.UNIT], check=True,
        )
        self.assertNotIn("--check", api.call_args_list[2].args[0])

    @patch.object(MANAGER, "run_json")
    @patch.object(MANAGER.subprocess, "run")
    def test_first_hip_install_uses_staged_vision_reader_and_preserves_key(self, run, api):
        calls = 0

        def respond(arguments):
            nonlocal calls
            calls += 1
            self.assertEqual(arguments[2:4], ["--backend", "hip"])
            if "--model-config" in arguments:
                profile = Path(arguments[arguments.index("--model-config") + 1])
                smoke = json.loads(profile.read_text())
                self.assertTrue(smoke["vision"]["exe"].endswith("/strata-vision-hip"))
                self.assertFalse(Path(smoke["vision"]["exe"]).exists())
                self.assertTrue(smoke["vision"]["cpu_exe"].endswith("/strata-vision"))
                self.assertEqual(profile.stat().st_mode & 0o777, 0o600)
                return {"ok": True}
            report = self.report("install" if calls < 4 else "current")
            report["engine"]["installed"] = {"folder": "new-hip-rx9070"}
            return report

        api.side_effect = respond
        self.assertTrue(MANAGER.update("hip"))
        self.assertEqual(calls, 4)
        config = json.loads(MANAGER.PROFILE.read_text())
        self.assertEqual(config["backend"], "hip")
        self.assertTrue(config["vision"]["exe"].endswith("/new-hip-rx9070/strata-vision-hip"))
        self.assertTrue(config["vision"]["cpu_exe"].endswith("/new-hip-rx9070/strata-vision"))
        self.assertEqual(config["api_key"], self.profile["api_key"])

    @patch.object(MANAGER, "run_json")
    @patch.object(MANAGER.subprocess, "run")
    def test_unmanaged_server_blocks_update(self, run, api):
        report = self.report("available")
        serving = self.report("available")
        serving["serving"] = [{"pid": 123}]
        api.side_effect = [report, serving]
        with self.assertRaisesRegex(RuntimeError, "unmanaged"):
            MANAGER.update()
        self.assertFalse(MANAGER.PROFILE.exists())

    @patch.object(MANAGER, "run_json")
    @patch.object(MANAGER.subprocess, "run")
    def test_unmanaged_current_server_blocks_activation(self, run, api):
        report = self.report()
        report["serving"] = [{"pid": 123}]
        api.return_value = report
        run.return_value.returncode = 3
        with self.assertRaisesRegex(RuntimeError, "before activating"):
            MANAGER.update()
        self.assertFalse(MANAGER.PROFILE.exists())

    @patch.object(MANAGER, "run_json")
    def test_update_failure_is_not_hidden(self, api):
        api.side_effect = subprocess.CalledProcessError(5, ["strata", "update"])
        with self.assertRaises(subprocess.CalledProcessError):
            MANAGER.update()
        self.assertFalse(MANAGER.PROFILE.exists())

    @patch.object(MANAGER, "run_json")
    def test_blocked_update_is_an_error(self, api):
        api.return_value = self.report("failed-before")
        with self.assertRaisesRegex(RuntimeError, "blocked"):
            MANAGER.update()

    @patch.object(MANAGER, "run_json")
    def test_changed_private_backup_is_rejected(self, api):
        (MANAGER.BACKUP / "setup/launch.json").write_text("{}")
        with self.assertRaisesRegex(RuntimeError, "checksum"):
            MANAGER.update()
        api.assert_not_called()

    @patch.object(MANAGER, "run_json")
    def test_updated_control_supplies_its_own_expert_profile(self, api):
        api.return_value = self.report()
        control = MANAGER.SHARE / "components/control"
        profile = control / "new/data/expert-profile.bin"
        profile.parent.mkdir(parents=True)
        profile.touch()
        (control / "active.json").write_text(json.dumps({"folder": "new"}))
        MANAGER.update()
        config = json.loads(MANAGER.PROFILE.read_text())
        self.assertEqual(config["cwd"], str(control / "new"))
        self.assertEqual(config["args"][1], str(profile))

    @patch.object(MANAGER.subprocess, "run")
    def test_restore_verifies_existing_local_models_and_is_idempotent(self, run):
        target = MANAGER.HOME / "models/packs/iq3_s/dense.bin"
        target.parent.mkdir(parents=True)
        target.write_bytes(b"model")
        self.entries["packs/iq3_s/dense.bin"] = hashlib.sha256(b"model").hexdigest()
        (MANAGER.BACKUP / "SHA256SUMS").write_text("test manifest")
        run.return_value.stdout = ""
        self.assertFalse(MANAGER.restore())
        self.assertTrue((MANAGER.HOME / ".local/state/strata/restore.sha256").is_file())
        self.assertFalse(MANAGER.restore())
        self.assertEqual(run.call_count, 6)

    @patch.object(MANAGER.subprocess, "run")
    def test_restore_rejects_wrong_model_content(self, run):
        target = MANAGER.HOME / "models/packs/dense.bin"
        target.parent.mkdir(parents=True)
        target.write_bytes(b"wrong")
        self.entries["packs/dense.bin"] = hashlib.sha256(b"model").hexdigest()
        (MANAGER.BACKUP / "SHA256SUMS").write_text("test manifest")
        run.return_value.stdout = ">f+++++++++ dense.bin"
        with self.assertRaisesRegex(RuntimeError, "checksum"):
            MANAGER.restore()

    @patch.object(MANAGER.subprocess, "run")
    def test_missing_runtime_bootstraps_from_verified_archive(self, run):
        MANAGER.CLI.unlink()
        MANAGER.CLI.parent.rmdir()
        MANAGER.CLI.parent.parent.rmdir()
        source = MANAGER.BACKUP / "launcher"
        source.write_text("#!/bin/sh\n")
        archive = MANAGER.BACKUP / "setup/runtime.tar"
        with tarfile.open(archive, "w") as bundle:
            bundle.add(source, arcname=f"{MANAGER.SHARE.name}/terminal/0.1.47/bin/strata")
        self.entries["setup/runtime.tar"] = MANAGER.sha256(archive)
        (MANAGER.BACKUP / "SHA256SUMS").write_text("test manifest")
        run.return_value.stdout = ""
        self.assertTrue(MANAGER.restore())
        self.assertTrue(MANAGER.CLI.is_file())
        self.assertTrue((MANAGER.SHARE / "terminal/current").is_symlink())
        self.assertFalse(MANAGER.restore())

    def test_missing_completion_marker_blocks_restore(self):
        with patch.object(MANAGER.os.path, "ismount", return_value=True):
            with self.assertRaises(FileNotFoundError):
                BACKUP_MANIFEST()

    def test_backup_manifest_rejects_path_traversal(self):
        manifest = MANAGER.BACKUP / "SHA256SUMS"
        manifest.write_text("1234  ../outside\n")
        (MANAGER.BACKUP / "BACKUP_COMPLETE").write_text(json.dumps({
            "files": 1, "sha256sums": MANAGER.sha256(manifest),
        }))
        with patch.object(MANAGER.os.path, "ismount", return_value=True):
            with self.assertRaisesRegex(ValueError, "Unsafe"):
                BACKUP_MANIFEST()

    @patch.object(MANAGER, "urlopen")
    def test_health_requires_authenticated_loaded_256k_vision_model(self, urlopen):
        MANAGER.PROFILE.parent.mkdir()
        MANAGER.PROFILE.write_text(json.dumps(self.profile))
        body = {"data": [{
            "id": MANAGER.MODEL, "status": {"value": "loaded"},
            "meta": {"n_ctx": 262144}, "architecture": {"input_modalities": ["text", "image"]},
        }]}
        urlopen.return_value.__enter__.return_value = io.StringIO(json.dumps(body))
        MANAGER.health()
        request = urlopen.call_args.args[0]
        self.assertEqual(request.get_header("Authorization"), "Bearer test-private-key")

    @patch.object(MANAGER.time, "sleep")
    @patch.object(MANAGER, "urlopen")
    def test_health_rejects_wrong_context_or_missing_vision(self, urlopen, sleep):
        MANAGER.PROFILE.parent.mkdir()
        MANAGER.PROFILE.write_text(json.dumps(self.profile))
        for context, modalities in [(131072, ["text", "image"]), (262144, ["text"])]:
            with self.subTest(context=context, modalities=modalities):
                body = {"data": [{
                    "id": MANAGER.MODEL, "status": {"value": "loaded"},
                    "meta": {"n_ctx": context},
                    "architecture": {"input_modalities": modalities},
                }]}
                urlopen.return_value.__enter__.return_value = io.StringIO(json.dumps(body))
                with patch.object(MANAGER.time, "monotonic", side_effect=[0, 0, 901]):
                    with self.assertRaisesRegex(RuntimeError, "readiness timed out"):
                        MANAGER.health()


if __name__ == "__main__":
    unittest.main()
