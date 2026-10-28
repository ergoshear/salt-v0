{% set node = grains['id'] %}
{% if node == 'mlops-node-5' %}
mlops-storage-client-local:
  test.succeed_without_changes:
    - name: The storage server uses its local filesystem mount
{% elif node.startswith('mlops-node-') %}
mlops-storage-client-package:
  pkg.installed:
    - name: nfs-utils

mlops-storage-client-mount:
  mount.mounted:
    - name: /srv/storage
    - device: mlops-node-5.lan:/
    - fstype: nfs
    - mkmnt: True
    - opts: rw,hard,vers=4.1,proto=tcp,noatime,_netdev,nofail
    - dump: 0
    - pass_num: 0
    - persist: True
    - mount: True
    - match_on: device
    - retry:
        attempts: 10
        interval: 30
    - require:
      - pkg: mlops-storage-client-package
{% else %}
mlops-storage-client-target-guard:
  test.fail_without_changes:
    - name: The storage client state is restricted to mlops-node-* minions
{% endif %}
