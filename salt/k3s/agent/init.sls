{% set node = grains['id'] %}
{% set token = salt['pillar.get']('K3S_AGENT_TOKEN', '') %}
{% if node not in ['mlops-node-0', 'mlops-node-1'] or not token %}
k3s-agent-prerequisites:
  test.fail_without_changes:
    - name: k3s agents are restricted to mlops-node-0 and mlops-node-1 and require K3S_AGENT_TOKEN pillar
{% else %}
include:
  - k3s.network

k3s-agent-config:
  file.managed:
    - name: /etc/rancher/k3s/config.yaml
    - user: root
    - group: root
    - mode: '0600'
    - makedirs: True
    - show_changes: False
    - contents: |
        server: https://k3s-control-plane-01.tailb11f97.ts.net:6443
        token: {{ token | tojson }}
        node-name: {{ node }}

k3s-agent-systemd-network:
  file.managed:
    - name: /etc/systemd/system/k3s-agent.service.d/network.conf
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - contents: |
        [Unit]
        Requires=tailscaled.service
        After=tailscaled.service network-online.target
        [Service]
        ExecStartPre=/usr/bin/python3 /usr/local/sbin/salt-tailscale-node configure {{ node }}

k3s-agent-systemd-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: k3s-agent-systemd-network

k3s-agent-installer:
  file.managed:
    - name: /usr/local/src/k3s-install.sh
    - source: https://get.k3s.io
    - skip_verify: True
    - mode: '0700'
    - makedirs: True

k3s-agent-install:
  cmd.run:
    - name: sh /usr/local/src/k3s-install.sh
    - env:
      - INSTALL_K3S_EXEC: agent
    - unless: test -x /usr/local/bin/k3s
    - require:
      - file: k3s-agent-installer
      - file: k3s-agent-config
      - cmd: k3s-agent-systemd-reload
      - cmd: k3s-tailscale-config

k3s-agent-service:
  service.running:
    - name: k3s-agent
    - enable: True
    - require:
      - cmd: k3s-agent-install
    - watch:
      - file: k3s-agent-config
      - file: k3s-agent-systemd-network
      - cmd: k3s-tailscale-config
{% endif %}
