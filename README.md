# salt

## GitHub Actions test and apply

The [Salt workflow](.github/workflows/salt.yml) runs configuration tests
on a GitHub-hosted runner, then a local `salt.master` dry run on the
`self-hosted`, `salt-master-01` runner, checking out `main` for both the dry
run and apply so the master's configured file roots receive the main checkout.
Only after success does it apply the highstate using the required
`TS_API_KEY`, `LITELLM_BACKEND_KEY`, and `HUGGING_FACE_ACCESS_KEY` GitHub
Actions secrets. Manual dispatch runs the dry-run gate by default; enable
`skip_dry_run` only for a direct recovery apply. The apply writes model
credentials as private, master-owned file-tree pillars for only
`mlops-node-4`, `mlops-node-6`, `mlops-node-7`, and `mlops-node-9`, checks that
the compiled pillars are scoped to those hosts, and applies the backend and
Hugging Face states on those minions. The secrets are never committed or
printed. The workflow serializes runs against the shared checkout.

The runner needs Salt, Python 3, and passwordless sudo for the workflow
commands. The workflow writes the API key to
`/etc/salt/tailscale/api-key` inside a root-only directory without logging it,
bootstraps `salt.master`, and then **targets remote minions**: Tailscale on
all accepted minions, followed by the Kubernetes server and two workers.
Offline minions or failed states fail deployment rather than claiming success.
The final gates wait for both Kubernetes workers to become Ready, verify
their Tailscale InternalIPs, test pod HTTP traffic in both directions and pod
DNS using disposable BusyBox pods, and verify both workers' kubelet metrics.
Probe pods run unprivileged without service-account tokens in a unique
temporary namespace, which is deleted even if a check fails.

## Tailscale

The `tailscale` state applies to every Salt minion. It installs the official
stable Fedora package, enables `tailscaled`, and enrolls the machine in
`tailb11f97.ts.net` using its Salt ID as its Tailscale hostname.
Existing authenticated nodes retain their identity; Salt converges hostname
and advertised tags without logging out or resetting unrelated preferences.

- Every minion receives `tag:salt-managed`.
- Only `k3s-control-plane-01`, `mlops-node-0`, and `mlops-node-1` also receive
  `tag:k8s`. Ordinary minions never receive `tag:k8s-operator`.
- Salt's built-in `file_tree` external pillar exposes `TS_API_KEY` only to `salt-master-01`.
  Each minion receives only its own `TAILSCALE_AUTH_KEY`, not the API key.
- Enrollment keys are reusable for retries, preauthorized, non-ephemeral,
  tagged, and expire after one hour. Root-only caches are refreshed before
  expiry by a master systemd timer every ten minutes, independent of minion pillar.
  Existing enrolled nodes do not need an unexpired auth key to stay connected.
- The API key itself expires according to Tailscale's management settings;
  rotate the GitHub secret and rerun deployment before expiry.

The master provisioner reads the live tailnet policy as JSON, preserves
existing rules/owners, adds missing ownership for the managed tags, and adds
a grant between `tag:k8s` nodes for TCP 6443, TCP 10250, and UDP 8472.
Existing `tag:k8s` ownership by `tag:k8s-operator` is preserved.
It uses the policy ETag to reject concurrent edits rather than overwrite them,
and saves the initial policy in root-only
`/etc/salt/tailscale/policy-before-salt.json`. JSON serialization does not
retain policy comments. The API key owner must be authorized to update policy
and issue keys bearing both managed tags. Errors fail provisioning explicitly.
This does not restrict any broader access already granted by existing policy.

## Kubernetes networking and workers

Only the exact IDs `mlops-node-0` and `mlops-node-1` match `k3s.agent`.
Explicitly applying the agent state to any other minion fails without
installing an agent. The root-only agent configuration consumes `K3S_TOKEN`;
secret file diffs are suppressed.

Agents connect to
`https://k3s-control-plane-01.tailb11f97.ts.net:6443`. MagicDNS must be enabled
in the tailnet. The public `k3s.ergoshear.dev` endpoint remains available.
Both names are server certificate SANs.

Salt derives each node's IPv4 address from its authenticated local Tailscale
status, writes k3s's network configuration drop-in, and uses `tailscale0`
for Flannel. K3s's systemd dependency and pre-start check ensure networking
is available before startup, including after reboot. The first server
migration changes its InternalIP and restarts k3s, briefly interrupting service.
The control plane retains its `NoSchedule` taint.
Salt pins the Traefik Helm install jobs to the latest patched `klipper-helm`
image using K3s's supported `HelmChart.spec.jobImage` field.
Salt uses the kubectl bundled with k3s rather than requiring a standalone
Fedora `kubectl` package, and preserves an existing executable CLI.

Salt enables firewalld on the three Kubernetes nodes, trusts `tailscale0`
and the default pod/service CIDRs (`10.42.0.0/16`, `10.43.0.0/16`), and enables
IPv4 forwarding. It preserves existing rules and services. The server's
internet interface's actual zone permits web ingress on TCP 80/443 and API
access from the existing home CIDR `173.72.146.35/32`, without moving the
interface out of its existing zone.
VXLAN and kubelet traffic stay inside Tailscale. No public overlay ports,
basement router forwards, or AWS security-group changes are required.
Tailscale can use DERP when direct UDP connectivity is unavailable.

The server publishes its token using Salt `cp.push`; the provisioner reads it
after server apply and on each timer refresh, and the built-in external pillar
continues exposing `K3S_TOKEN` to all authenticated minions, as before.
Treat all minions as trusted with this cluster credential. No credentials
are committed to this repository.

The management API file and key caches remain root-only. Published pillar
files are owned by the configured Salt master service user with mode `0600`,
in service-owned `0700` directories; the parent permits only that service
group to traverse it. This supports a non-root master with a non-login shell
without invoking shell-based pillar commands or exposing credentials publicly.

## Salt master

The `salt.master` state applies only to `salt-master-01`. It manages:

- `file_roots`: `/srv/actions-runner/_work/salt/salt/salt`
- `pillar_roots`: `/srv/actions-runner/_work/salt/salt/pillar`
- Per-minion external pillar files under `/etc/salt/tailscale/pillar/hosts`.
- `file_recv` for the control-plane token transfer.
- A `salt.execute` schedule applying highstate to connected minions every
  five minutes, starting five minutes after master startup.

For manual bootstrap, first securely provision `/etc/salt/tailscale/api-key`,
then run from the trusted checkout:

```sh
sudo salt-call --local \
  --file-root=/srv/actions-runner/_work/salt/salt/salt \
  --pillar-root=/srv/actions-runner/_work/salt/salt/pillar \
  state.apply salt.master --retcode-passthrough
sudo python3 salt/tailscale/deploy.py
```

The checkout must remain available and trusted. Newly accepted minions receive
enrollment credentials after the next master refresh; their next highstate
then enrolls them.

## Validation

Run the Salt state compilation and validity checks, policy-merge, credential
isolation, and enrollment tests:

```sh
uv run --no-project --with-requirements tests/requirements.txt python -m unittest discover -s tests -v
```

Test dependencies are listed in `tests/requirements.txt` and managed by uv.
The state checks render every SLS file across relevant template branches and
validate the compiled YAML/Salt state structure without asserting particular
configuration values.

To install pre-commit, its test dependencies, and enable the repository hook
once per clone:

```sh
just pre-commit setup
```

Setup runs the tests once to cache their dependencies. The hook uses uv's
offline mode so commits do not need access to PyPI. After changing
`tests/requirements.txt` or clearing uv's cache, run the validation command
above while online to prepare the dependencies again.

The hook always runs the full test suite, regardless of which files are staged.
After deployment, verify the tunnel addresses,
node readiness, cross-worker pod traffic, pod DNS, metrics, and existing
Argo CD HTTPS ingress. Registration alone does not validate pod networking.
Do not print API keys, auth keys, or whole pillar data during verification.

## MLOps access

Every `mlops-node-*` minion receives the `mlops.user` state. It ensures the
`mlops` account, a dedicated `NOPASSWD` sudoers entry, and the configured
ed25519 public key. SSH password and keyboard-interactive authentication are
disabled; `sshd` requires public-key authentication.

## HTTPS reverse proxy

Nodes `mlops-node-4`, `mlops-node-6`, `mlops-node-7`, and `mlops-node-9`
receive the `httpd` state. It installs `httpd` and `mod_ssl`, terminates TLS on
443, proxies to `http://127.0.0.1:8080/`, and redirects port 80 to HTTPS. It
opens `http` and `https` in firewalld, enables the
`httpd_can_network_connect` SELinux boolean, and runs `httpd -t` before
restarting the service on configuration changes.

The state replaces `/etc/httpd/conf.d/ssl.conf` and the default SSL virtual
host with the managed proxy virtual host. Pillar overrides:

- `HTTPD_SERVER_NAME`: TLS common name and redirect target (defaults to the
  minion ID).
- `HTTPD_PROXY_HOST` and `HTTPD_PROXY_PORT`: upstream address and port
  (defaults `127.0.0.1` and `8080`).
- `HTTPD_SSL_CERT` and `HTTPD_SSL_KEY`: existing certificate and key paths.
  Set both or neither; setting only one fails the state.
- `HTTPD_HTTP_REDIRECT`: set to false to keep an HTTP virtual host instead of
  redirecting (default true).
- `HTTPD_FIREWALL_ZONE`: firewalld zone to open (default `public`).

Without certificate pillar values, Salt creates a self-signed certificate at
`/etc/pki/tls/certs/httpd-proxy-<minion-id>.crt` with its key in
`/etc/pki/tls/private/`, and regenerates it when `HTTPD_SERVER_NAME` changes.
The self-signed certificate is not renewed automatically; use the certificate
pillar values for a publicly trusted certificate. Port 8080 remains limited by
`mlops.backend` to loopback and authenticated proxy identities, so the
reverse proxy reaches the backend over loopback.

## MLOps storage

Only `mlops-node-5` receives `mlops.storage`. It removes that host's unused
4 TB WDC physical volume from the existing `fedora` volume group, clears the
LVM PV signature, formats its partition as ext4, and mounts it at
`/srv/storage`. Salt persists the mount in `/etc/fstab` using the disk's
stable `/dev/disk/by-id` path. This intentionally replaces the partition's
LVM metadata with a new filesystem. It exports that filesystem read/write over
NFSv4 on the LAN, restricted to `mlops-node-*.lan` clients. Other Salt minions
whose IDs match `mlops-node-*` mount `mlops-node-5.lan:/` at `/srv/storage`
with a persistent fstab entry; node 5 keeps its local disk mount. The NFS
firewall rule allows TCP 2049 only from the `192.168.202.0/24` LAN. A new
mlops node must use a matching `.lan` hostname to receive the export.

## Security deployment ordering

Inference states now include `mlops.backend`. The apply workflow seeds the
single-line `LITELLM_BACKEND_KEY` GitHub Actions secret as the
`INFERENCE_BACKEND_KEY` pillar and the `HUGGING_FACE_ACCESS_KEY` secret as the
`HUGGING_FACE_ACCESS_KEY` pillar only for nodes 4, 6, 7 and 9. The
`mlops.huggingface` state installs the Hugging Face CLI token at
`/home/mlops/.cache/huggingface/token` with mode 0600 on all model downloaders.
For manual host
recovery, the key can also be securely preseeded at
`/home/mlops/.config/llama/backend-key`, owned by `mlops`, mode 0600.
Use the same value in the `inference-backend` Kubernetes Secret in the
`litellm` and `hermes-workspace` namespaces. No key belongs in Git, CLI
arguments, state output or a global pillar. Stage client credentials first.
The llama-server key file and warmup authorization header are private files.
The independent nftables input hook precedes Tailscale/firewalld accepts and
limits both address families to tagged, canonical egress-proxy identities.
The boot service precedes the existing UID 1000 GPU user service; the timer
refreshes proxy addresses every 30 seconds. Missing proxy information denies
all remote inference. The Kubernetes proxy NetworkPolicy is also required:
all pods otherwise share those two tailnet identities.

Do **not** apply cloud Salt rule removal before migrating and verifying all
accepted minions. `tailscale` checks the tailnet master request port before
writing its minion master setting. Recheck every accepted key with Salt
`test.ping`, the effective minion `master` setting and established connections.
Only then enable the master-only `SALT_TAILNET_ENFORCE` pillar, apply
`salt.master`, and remove cloud ingress 4505–4506. No public client exceptions
are intended. Host enforcement covers IPv4 and IPv6, including an existing
connection arriving outside `tailscale0`.

The control plane creates a separate random agent-only token using k3s
`agent-token-file`. Only `server/agent-token` is published. The provisioner
removes **all** legacy `K3S_TOKEN` host pillar files, including retired hosts,
and supplies `K3S_AGENT_TOKEN` only to workers 0 and 1. The master state removes
the old cached server-token upload. Apply the control plane, refresh master
provisioning/pillars, apply workers, and verify both workers before rotating
the previously over-distributed **server** token.

Rotation must use supported `k3s token rotate`, not manual replacement of
`server/token`: bootstrap data is encrypted using that credential. First
take a datastore-appropriate recoverable backup with its original server
token (SQLite and embedded etcd need different backup procedures). Keep
rotation output in a root-only recovery file, restart the server as required
by the installed k3s version, and verify worker reconnects, DNS, metrics and
cross-worker pod traffic. Refresh/clear old minion pillar caches as well.
An old datastore backup still needs its matching original token for restore.

The 2026-10-20 live inference changes are independent of the Salt master
rollout. Salt transport migration, host/cloud Salt enforcement and k3s
server-token rotation remain outstanding until trusted master access exists.

## TuneD

The `system.tuned` state applies to all minions, installing and enabling
TuneD with a custom `aws` profile inheriting Fedora's `virtual-guest` profile.
