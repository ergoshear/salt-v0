# salt

## GitHub Actions test and apply

The [Salt dry-run workflow](.github/workflows/salt-test.yml) runs on pushes to
`main` and can also be started manually with **Run workflow** in GitHub Actions.
It requires a self-hosted runner with both the `self-hosted` and
`salt-master-01` labels, Salt installed, and passwordless `sudo` access to
`salt-call`.

The workflow runs `state.highstate test=True` locally on the runner using the
checked-out `salt/` and `pillar/` directories. It does not target remote minions
or apply the proposed state changes. Salt failures propagate to the job via
`--retcode-passthrough`.

Only after the dry-run job succeeds, it calls the reusable
[Salt highstate apply workflow](.github/workflows/salt-apply.yml). This checks out
the same commit on `salt-master-01` and runs `state.highstate` locally,
applying all states matched by `salt/top.sls` using the absolute roots below.
It does not target remote minions. Apply failures also fail the workflow.
Workflow runs are serialized to avoid overlapping test/apply runs against the
shared checkout.

## Salt master

The `salt.master` state applies only to the `salt-master-01` minion in
`salt/top.sls`. It manages `/etc/salt/master.d/master.conf` with these base roots:

- `file_roots`: `/srv/actions-runner/_work/salt/salt/salt`
- `pillar_roots`: `/srv/actions-runner/_work/salt/salt/pillar`

The master's scheduler uses the `salt.execute` runner to execute
`state.highstate` on all connected minions every five minutes. These are real
state applications, not dry runs. The first scheduled run waits five minutes
after master startup. The state enables `salt-master` and restarts it when the
managed configuration changes.

To bootstrap the configuration from the runner checkout:

```sh
sudo salt-call --local \
  --file-root=/srv/actions-runner/_work/salt/salt/salt \
  --pillar-root=/srv/actions-runner/_work/salt/salt/pillar \
  state.apply salt.master
```

The checkout must remain available and trusted: subsequent scheduled highstates
use its current contents, including updates checked out by GitHub Actions.