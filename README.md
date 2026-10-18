# salt

## GitHub Actions dry run

The [Salt dry-run workflow](.github/workflows/salt-test.yml) runs on pushes to
`main` and can also be started manually with **Run workflow** in GitHub Actions.
It requires a self-hosted runner with both the `self-hosted` and
`salt-master-01` labels, Salt installed, and passwordless `sudo` access to
`salt-call`.

The workflow runs `state.highstate test=True` locally on the runner using the
checked-out `salt/` and `pillar/` directories. It does not target remote minions
or apply the proposed state changes. Salt failures propagate to the job via
`--retcode-passthrough`.