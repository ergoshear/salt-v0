# salt

## GitHub Actions test and apply

The [test workflow](.github/workflows/salt-test.yml) runs configuration tests
on a GitHub-hosted runner, then a local `salt.master` dry run on the
`self-hosted`, `salt-master-01` runner. Only after success does it call the
[apply workflow](.github/workflows/salt-apply.yml), explicitly forwarding
the required `TS_API_KEY` GitHub Actions secret. A manual apply skips the
dry-run gate. The push workflow serializes runs against the shared checkout.

The runner needs Salt, Python 3, and passwordless sudo for the workflow
commands. The apply workflow writes the API key to
`/etc/salt/tailscale/api-key` inside a root-only directory without logging it,
bootstraps `salt.master`, and then **targets remote minions**: Tailscale on
all accepted minions, followed by the Kubernetes server and two workers.
Offline minions or failed states fail deployment rather than claiming success.
The final gate waits for both Kubernetes workers to become Ready.

## Tailscale

The `tailscale` state applies to every Salt minion. It installs the official
stable Fedora package, enables `tailscaled`, and enrolls the machine in
`tailb11f97.ts.net` using its Salt ID as its Tailscale hostname.
Existing authenticated nodes retain their identity; Salt converges hostname
and advertised tags without logging out or resetting unrelated preferences.

- Every minion receives `tag:salt-managed`.
- Only `k3s-control-plane-01`, `mlops-node-0`, and `mlops-node-1` also receive
  `tag:k8s`. Ordinary minions never receive `tag:k8s-operator`.
- The native external pillar exposes `TS_API_KEY` only to `salt-master-01`.
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

Salt enables firewalld on the three Kubernetes nodes, trusts `tailscale0`
and the default pod/service CIDRs (`10.42.0.0/16`, `10.43.0.0/16`), and enables
IPv4 forwarding. It preserves existing rules and services. The server's
public zone permits web ingress on TCP 80/443 and API access from the existing
home CIDR `173.72.146.35/32`; its internet interface must use that zone.
VXLAN and kubelet traffic stay inside Tailscale. No public overlay ports,
basement router forwards, or AWS security-group changes are required.
Tailscale can use DERP when direct UDP connectivity is unavailable.

The server publishes its token using Salt `cp.push`; the external pillar
continues exposing `K3S_TOKEN` to all authenticated minions, as before.
Treat all minions as trusted with this cluster credential. No credentials
are committed to this repository.

## Salt master

The `salt.master` state applies only to `salt-master-01`. It manages:

- `file_roots`: `/srv/actions-runner/_work/salt/salt/salt`
- `pillar_roots`: `/srv/actions-runner/_work/salt/salt/pillar`
- Native external pillar under `/var/cache/salt/master/extmods/pillar`.
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

Run configuration, policy-merge, credential isolation, and enrollment tests:

```sh
python3 -m unittest discover -s tests -v
```

Tests require Jinja2 and PyYAML. After deployment, verify the tunnel addresses,
node readiness, cross-worker pod traffic, pod DNS, metrics, and existing
Argo CD HTTPS ingress. Registration alone does not validate pod networking.
Do not print API keys, auth keys, or whole pillar data during verification.

## TuneD

The `system.tuned` state applies to all minions, installing and enabling
TuneD with a custom `aws` profile inheriting Fedora's `virtual-guest` profile.
