#!/usr/bin/python3
"""Restore the private model backup and maintain the official Strata runtime."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


HOME = Path("/home/mlops")
BACKUP = Path("/srv/storage/strata")
SHARE = HOME / ".local/share/strata"
CLI = SHARE / "terminal/current/bin/strata"
PROFILE = HOME / ".config/strata/iq3_s-256k.json"
UNIT = "strata-qwen38-flash-next.service"
MODEL = "qwen3.8-flash-next-iq3_s"


def sha256(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def backup_manifest():
    if not os.path.ismount("/srv/storage"):
        raise RuntimeError("/srv/storage is not mounted")
    complete = json.loads((BACKUP / "BACKUP_COMPLETE").read_text())
    manifest = BACKUP / "SHA256SUMS"
    if sha256(manifest) != complete["sha256sums"]:
        raise RuntimeError("Backup manifest checksum mismatch")
    entries = {}
    for line in manifest.read_text().splitlines():
        checksum, name = line.split("  ", 1)
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("Unsafe backup manifest path")
        entries[name] = checksum
    if len(entries) != complete["files"]:
        raise RuntimeError("Backup manifest file count mismatch")
    return entries


def run_json(arguments):
    result = subprocess.run(arguments, check=True, capture_output=True, text=True,
                            timeout=3300)
    result = json.loads(result.stdout)
    if not result.get("ok"):
        raise RuntimeError(f"Strata operation failed: {result}")
    return result


def restore():
    entries = backup_manifest()
    bootstrap = not CLI.is_file()
    changed = False
    (HOME / "models").mkdir(parents=True, exist_ok=True)
    for name in ("models", "packs", "mtp"):
        result = subprocess.run(
            ["rsync", "-a", "--itemize-changes", str(BACKUP / name) + "/",
             str(HOME / "models" / name) + "/"],
            check=True, capture_output=True, text=True,
        )
        changed |= bool(result.stdout)
    if bootstrap:
        archive = BACKUP / "setup/runtime.tar"
        if sha256(archive) != entries["setup/runtime.tar"]:
            raise RuntimeError("Backed-up runtime checksum mismatch")
        SHARE.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive) as bundle:
            bundle.extractall(SHARE.parent, filter="data")
        (SHARE / "terminal/current").unlink(missing_ok=True)
        (SHARE / "terminal/current").symlink_to(SHARE / "terminal/0.1.47")
        changed = True
    stamp = HOME / ".local/state/strata/restore.sha256"
    manifest_hash = sha256(BACKUP / "SHA256SUMS")
    if changed or not stamp.exists() or stamp.read_text() != manifest_hash:
        for name, expected in entries.items():
            parts = Path(name).parts
            if parts[0] in ("models", "packs", "mtp"):
                target = HOME / "models" / name
            else:
                continue
            if sha256(target) != expected:
                raise RuntimeError(f"Restored file checksum mismatch: {target}")
        stamp.parent.mkdir(parents=True, exist_ok=True)
        stamp.write_text(manifest_hash)
    return changed


def update(backend=None, max_context=262144):
    entries = backup_manifest()
    source = BACKUP / "setup/launch.json"
    if sha256(source) != entries["setup/launch.json"]:
        raise RuntimeError("Backed-up profile checksum mismatch")
    config = json.loads(source.read_text())
    args = config["args"]
    if "--max-context" in args:
        args[args.index("--max-context") + 1] = str(max_context)
    else:
        args.extend(["--max-context", str(max_context)])
    if not isinstance(config.get("api_key"), str) or not config["api_key"].strip():
        raise ValueError("The backed-up Strata API key must be nonempty")
    command = [str(CLI), "update"]
    if backend:
        command.extend(["--backend", backend])
    report = run_json([*command, "--check", "--output", "json"])
    if report["serving"] and subprocess.run(
        ["systemctl", "is-active", "--quiet", UNIT], check=False,
    ).returncode != 0:
        raise RuntimeError("Stop unmanaged Strata instances before activating the service")
    statuses = [report[name]["status"] for name in ("engine", "control")]
    if any(status not in ("current", "available", "install") for status in statuses):
        raise RuntimeError(f"Strata update is blocked: {statuses}")
    changed = any(status != "current" for status in statuses)
    if changed:
        subprocess.run(["sudo", "-n", "systemctl", "stop", UNIT], check=True)
        if run_json([*command, "--check", "--output", "json"])["serving"]:
            raise RuntimeError("Stop unmanaged Strata instances before updating")
        # Resolve vision against the staged package, not the backed-up CUDA package.
        with tempfile.TemporaryDirectory(prefix="strata-update-") as directory:
            smoke = json.loads(json.dumps(config))
            reader = "strata-vision-hip" if backend == "hip" else "strata-vision"
            smoke["vision"]["exe"] = str(Path(directory) / reader)
            if backend == "hip":
                smoke["vision"]["cpu_exe"] = str(Path(directory) / "strata-vision")
            smoke_profile = Path(directory) / "profile.json"
            smoke_profile.write_text(json.dumps(smoke))
            smoke_profile.chmod(0o600)
            run_json([*command, "--model-config", str(smoke_profile), "--output", "json"])
        report = run_json([*command, "--check", "--output", "json"])
        if any(report[name]["status"] != "current" for name in ("engine", "control")):
            raise RuntimeError("Strata did not converge to the offered release")
    terminal = (SHARE / "terminal/current").resolve(strict=True)
    active_control = SHARE / "components/control/active.json"
    if active_control.exists():
        pointer = json.loads(active_control.read_text())
        terminal = SHARE / "components/control" / pointer["folder"]
        if not (terminal / "data/expert-profile.bin").is_file():
            raise RuntimeError("Updated Control is missing the expert profile")
    engine = SHARE / "components/engine" / report["engine"]["installed"]["folder"]
    config["exe"] = "component:strata-engine"
    if backend:
        config["backend"] = backend
    config["cwd"] = str(terminal)
    config["vision"]["exe"] = str(
        engine / ("strata-vision-hip" if backend == "hip" else "strata-vision")
    )
    if backend == "hip":
        config["vision"]["cpu_exe"] = str(engine / "strata-vision")
    args = config["args"]
    args[args.index("--expert-profile") + 1] = str(terminal / "data/expert-profile.bin")
    config["args_written"] = list(args)
    config["log"] = str(HOME / ".local/state/strata/iq3_s-256k.engine.log")
    config["open_browser"] = False
    content = json.dumps(config, indent=2) + "\n"
    PROFILE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not PROFILE.exists() or PROFILE.read_text() != content:
        temporary = PROFILE.with_suffix(".incoming")
        temporary.write_text(content)
        temporary.chmod(0o600)
        temporary.replace(PROFILE)
        changed = True
    PROFILE.chmod(0o600)
    return changed


def health(max_context=262144):
    key = json.loads(PROFILE.read_text())["api_key"]
    request = Request("http://127.0.0.1:8080/v1/models",
                      headers={"Authorization": "Bearer " + key})
    deadline = time.monotonic() + 900
    last_error = None
    while time.monotonic() < deadline:
        try:
            with urlopen(request, timeout=15) as response:
                models = json.load(response)["data"]
            if any(model["id"] == MODEL
                   and model.get("status", {}).get("value") == "loaded"
                   and model.get("meta", {}).get("n_ctx") == max_context
                   and "image" in model.get("architecture", {}).get("input_modalities", [])
                   for model in models):
                return
            last_error = f"Expected loaded {max_context}-token model with vision is not ready"
        except HTTPError as error:
            if error.code not in (502, 503):
                raise
            last_error = str(error)
        except (URLError, TimeoutError) as error:
            last_error = str(error)
        time.sleep(5)
    raise RuntimeError(f"Strata readiness timed out: {last_error}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("restore", "update", "health"))
    parser.add_argument("--backend", choices=("cuda", "hip"))
    parser.add_argument("--max-context", type=int, choices=(131072, 262144), default=262144)
    options = parser.parse_args()
    action = options.action
    os.umask(0o077)
    if action == "health":
        health(options.max_context)
        print(json.dumps({"changed": False, "comment": "Strata readiness verified"}))
    else:
        changed = restore() if action == "restore" else update(options.backend, options.max_context)
        print(json.dumps({"changed": changed, "comment": f"Strata {action} complete"}))


if __name__ == "__main__":
    main()
