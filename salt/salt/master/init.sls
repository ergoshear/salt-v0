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
          - cmd_yaml: /usr/bin/python3 /srv/actions-runner/_work/salt/salt/salt/salt/k3s_token_pillar.py
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

salt-master-service:
  service.running:
    - name: salt-master
    - enable: True
    - watch:
      - file: salt-master-config
