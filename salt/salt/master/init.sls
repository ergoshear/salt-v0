salt-master-tailscale-directory:
  file.directory:
    - name: /etc/salt/tailscale
    - user: root

salt-master-pillar-directory:
  file.directory:
    - name: /etc/salt/tailscale/pillar
    - require:
      - file: salt-master-tailscale-directory

salt-master-tailscale-provisioner:
  file.managed:
    - name: /usr/local/sbin/salt-tailscale-provision
    - source: salt://tailscale/provision.py
    - mode: '0700'

salt-master-obsolete-pillar-modules:
  file.absent:
    - names:
      - /etc/salt/ext_pillar/k3s_cluster.py
      - /var/cache/salt/master/extmods/pillar/k3s_cluster.py
      - /var/cache/salt/master/minions/k3s-control-plane-01/files/k3s-control-plane-01/k3s-token

{% if salt['pillar.get']('SALT_TAILNET_ENFORCE', False) %}
salt-master-firewall-package:
  pkg.installed:
    - name: nftables

salt-master-firewall-config:
  file.managed:
    - name: /etc/salt/tailscale/firewall.nft
    - mode: '0600'
    - contents: |
        add table inet salt_boundary
        flush table inet salt_boundary
        add chain inet salt_boundary input { type filter hook input priority -20; policy accept; }
        add rule inet salt_boundary input iifname != "tailscale0" tcp dport { 4505, 4506 } drop
    - require:
      - file: salt-master-tailscale-directory

salt-master-firewall-unit:
  file.managed:
    - name: /etc/systemd/system/salt-tailnet-firewall.service
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Salt control traffic must use Tailscale (IPv4 and IPv6)
        Before=salt-master.service
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/sbin/nft -f /etc/salt/tailscale/firewall.nft
        [Install]
        WantedBy=multi-user.target

salt-master-firewall-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: salt-master-firewall-unit

salt-master-firewall:
  service.running:
    - name: salt-tailnet-firewall
    - enable: True
    - require:
      - pkg: salt-master-firewall-package
      - cmd: salt-master-firewall-reload
    - watch:
      - file: salt-master-firewall-config
{% endif %}

salt-master-config:
  file.managed:
    - name: /etc/salt/master.d/master.conf
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - contents: |
        file_roots:
          base:
            - /srv/actions-runner/_work/salt/salt/salt
        pillar_roots:
          base:
            - /srv/actions-runner/_work/salt/salt/pillar
        file_recv: True
        ext_pillar:
          - file_tree:
              root_dir: /etc/salt/tailscale/pillar
              follow_dir_links: False
              template: True
              render_default: yaml
        schedule:
          highstate:
            function: salt.execute
            args:
              - '*'
              - state.highstate
            minutes: 5
            maxrunning: 1
            jid_include: True
            run_on_start: False

salt-master-tailscale-credentials:
  cmd.run:
    - name: /usr/bin/python3 /usr/local/sbin/salt-tailscale-provision
    - require:
      - file: salt-master-tailscale-directory
      - file: salt-master-pillar-directory
      - file: salt-master-tailscale-provisioner
      - file: salt-master-config

salt-master-tailscale-refresh-service:
  file.managed:
    - name: /etc/systemd/system/salt-tailscale-refresh.service
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Refresh Salt Tailscale enrollment credentials
        [Service]
        Type=oneshot
        ExecStart=/usr/bin/python3 /usr/local/sbin/salt-tailscale-provision

salt-master-tailscale-refresh-timer:
  file.managed:
    - name: /etc/systemd/system/salt-tailscale-refresh.timer
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Refresh Salt Tailscale credentials every ten minutes
        [Timer]
        OnBootSec=2min
        OnUnitActiveSec=10min
        [Install]
        WantedBy=timers.target

salt-master-tailscale-systemd-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: salt-master-tailscale-refresh-service
      - file: salt-master-tailscale-refresh-timer

salt-master-tailscale-refresh:
  service.running:
    - name: salt-tailscale-refresh.timer
    - enable: True
    - require:
      - cmd: salt-master-tailscale-credentials
      - cmd: salt-master-tailscale-systemd-reload
    - watch:
      - file: salt-master-tailscale-refresh-timer

salt-master-service:
  service.running:
    - name: salt-master
    - enable: True
    - require:
      - cmd: salt-master-tailscale-credentials
    - watch:
      - file: salt-master-config
