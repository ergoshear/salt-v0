{% set node = grains['id'] %}
{% set auth = salt['pillar.get']('TAILSCALE_AUTH_KEY', '') %}
{% if not auth %}
tailscale-missing-enrollment:
  test.fail_without_changes:
    - name: Missing TAILSCALE_AUTH_KEY pillar; apply salt.master and refresh pillar
{% else %}
tailscale-repository:
  file.managed:
    - name: /etc/yum.repos.d/tailscale.repo
    - source: https://pkgs.tailscale.com/stable/fedora/tailscale.repo
    - skip_verify: True

tailscale-package:
  pkg.installed:
    - name: tailscale
    - require:
      - file: tailscale-repository

tailscale-service:
  service.running:
    - name: tailscaled
    - enable: True
    - require:
      - pkg: tailscale-package

tailscale-auth-key:
  file.managed:
    - name: /etc/tailscale/salt-authkey
    - contents: {{ auth | tojson }}
    - mode: '0600'
    - user: root
    - group: root
    - makedirs: True
    - show_changes: False

tailscale-node-helper:
  file.managed:
    - name: /usr/local/sbin/salt-tailscale-node
    - source: salt://tailscale/node.py
    - mode: '0700'

tailscale-enroll:
  cmd.run:
    - name: /usr/bin/python3 /usr/local/sbin/salt-tailscale-node enroll {{ node | tojson }}
    - stateful: True
    - shell: /bin/sh
    - require:
      - service: tailscale-service
      - file: tailscale-auth-key
      - file: tailscale-node-helper

salt-tailnet-master-reachable:
  cmd.run:
    - name: /usr/bin/python3 -c 'import socket; socket.create_connection(("salt-master-01.tailb11f97.ts.net", 4506), timeout=10).close()'
    - require:
      - cmd: tailscale-enroll

salt-tailnet-master-config:
  file.managed:
    - name: /etc/salt/minion.d/zz-tailnet-master.conf
    - mode: '0600'
    - makedirs: True
    - contents: |
        master: salt-master-01.tailb11f97.ts.net
    - require:
      - cmd: salt-tailnet-master-reachable

salt-tailnet-minion:
  service.running:
    - name: salt-minion
    - enable: True
    - watch:
      - file: salt-tailnet-master-config
{% endif %}
