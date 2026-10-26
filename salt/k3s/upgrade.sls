{% set node = grains['id'] %}
{% set version = salt['pillar.get']('K3S_UPGRADE_VERSION', '') %}
{% if node not in ['k3s-control-plane-01', 'mlops-node-0', 'mlops-node-1', 'mlops-node-5'] or not version %}
k3s-upgrade-prerequisites:
  test.fail_without_changes:
    - name: K3s upgrades require a supported cluster minion and K3S_UPGRADE_VERSION
{% else %}
k3s-upgrade-installer:
  file.managed:
    - name: /usr/local/src/k3s-install.sh
    - source: https://get.k3s.io
    - skip_verify: True
    - mode: '0700'
    - makedirs: True

k3s-upgrade-install:
  cmd.run:
    - name: sh /usr/local/src/k3s-install.sh
    - env:
      - INSTALL_K3S_VERSION: {{ version | tojson }}
{% if node in ['mlops-node-0', 'mlops-node-1', 'mlops-node-5'] %}
      - INSTALL_K3S_EXEC: agent
{% endif %}
    - require:
      - file: k3s-upgrade-installer
{% endif %}
