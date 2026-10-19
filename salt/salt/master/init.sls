salt-master-tailscale-directory:
  file.directory:
    - name: /etc/salt/tailscale
    - user: root
    - group: root
    - mode: '0700'

salt-master-tailscale-provisioner:
  file.managed:
    - name: /usr/local/sbin/salt-tailscale-provision
    - source: salt://tailscale/provision.py
    - mode: '0700'

salt-master-k3s-pillar:
  file.managed:
    - name: /var/cache/salt/master/extmods/pillar/k3s_cluster.py
    - source: salt://salt/k3s_token_pillar.py
    - user: root
    - group: root
    - mode: '0600'
    - makedirs: True

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
        extension_modules: /var/cache/salt/master/extmods
        ext_pillar:
          - k3s_cluster: []
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
      - file: salt-master-tailscale-provisioner

salt-master-tailscale-refresh:
  cron.present:
    - name: /usr/bin/python3 /usr/local/sbin/salt-tailscale-provision
    - user: root
    - minute: '*/10'
    - require:
      - cmd: salt-master-tailscale-credentials

salt-master-service:
  service.running:
    - name: salt-master
    - enable: True
    - require:
      - cmd: salt-master-tailscale-credentials
    - watch:
      - file: salt-master-config
      - file: salt-master-k3s-pillar
