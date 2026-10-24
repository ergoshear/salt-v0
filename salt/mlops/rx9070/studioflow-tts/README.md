# StudioFlow TTS

This Salt state deploys the StudioFlow text-to-speech and audio-alignment
services on the AMD GPU host `mlops-node-3`. It checks out the application
source, builds three Podman images, manages their systemd services, and
publishes the services over the host's Tailscale HTTPS endpoint.

The state definition is in [`init.sls`](./init.sls). The application source is
maintained separately in the private
[`ergoshear/studioflow-tts`](https://github.com/ergoshear/studioflow-tts)
repository and is checked out to `/opt/studioflow-tts` on the host.

## Services

| Service | systemd unit | Local address | Tailscale HTTPS URL |
| --- | --- | --- | --- |
| Fish Speech | `studioflow-fish-speech` | `127.0.0.1:8001` | `https://<hostname>:8001/v1` |
| Zonos | `studioflow-zonos` | `127.0.0.1:8002` | `https://<hostname>:8002/v1` |
| Whisper alignment | `studioflow-whisper` | `127.0.0.1:8003` | `https://<hostname>:8003/v1` |

The local ports are bound to loopback, not exposed directly on the host's
network interfaces. Tailscale Serve terminates HTTPS on the matching port and
proxies to the local service. The LiteLLM backend uses the
`mlops-node-3.tailb11f97.ts.net` hostname and the `/v1` API path.

## Requirements

- Salt access to the `mlops-node-3` minion.
- A working AMD GPU driver exposing `/dev/kfd` and `/dev/dri`.
- Tailscale connected on the host.
- The private deploy key at `/home/mlops/.ssh/studioflow-tts` on `mlops-node-3`,
  with its public key registered as a read-only deploy key on the private
  application repository.
- Network access from the host to GitHub and the registries or package sources
  needed to build the application images.

The state installs Git and Podman, pins GitHub's published Ed25519 SSH host
key, and uses the deploy key for checkout. It fails if the repository cannot be
accessed or the required GPU devices are unavailable.

## Apply the state

The state is included for `mlops-node-3` in [`top.sls`](../../../top.sls), so a
highstate applies it automatically. To apply it directly from the Salt master:

```sh
salt 'mlops-node-3' state.apply mlops.rx9070.studioflow-tts
```

On apply, Salt fetches the latest `main` revision of the application
repository, builds the Fish Speech, Zonos, and Whisper images when the checkout
changes, then starts or updates the corresponding systemd services.

## Persistent data

The services share these host directories, mounted into their containers:

| Host directory | Purpose |
| --- | --- |
| `/var/lib/studioflow-tts/voices` | Voice samples and related data |
| `/var/lib/studioflow-tts/hf_cache` | Hugging Face model cache |
| `/var/lib/studioflow-tts/checkpoints` | Model checkpoints |

These directories persist across container rebuilds and restarts. Back them up
before making changes that could remove or replace their contents.

## Operations

Check service status:

```sh
sudo systemctl status studioflow-fish-speech studioflow-zonos studioflow-whisper
```

Follow a service's logs:

```sh
sudo journalctl -u studioflow-fish-speech -f
```

Check the images and Tailscale Serve configuration:

```sh
sudo podman images
sudo tailscale serve status
```

If a service does not start, check that the GPU device nodes are present, the
deploy key can read the private repository, and the relevant container logs
report no model download or startup errors.
