
k3s-pkgs-install:
  pkg.installed:
    - names:
      - kubectl
      - helm
      - kustomize

k3s-control-plane-config:
  file.managed:
    - name: /etc/rancher/k3s/config.yaml
    - user: root
    - group: root
    - mode: '0600'
    - makedirs: True
    - contents: |
        node-taint:
          - "node-role.kubernetes.io/control-plane=true:NoSchedule"

k3s-install:
  cmd.run:
    - name: curl -sfL https://get.k3s.io | sh -
    - unless: test -x /usr/local/bin/k3s
    - require:
      - file: k3s-control-plane-config

k3s-service:
  service.running:
    - name: k3s
    - enable: True
    - require:
      - cmd: k3s-install
    - watch:
      - file: k3s-control-plane-config

k3s-publish-token:
  cmd.run:
    - name: salt-call cp.push /var/lib/rancher/k3s/server/node-token upload_path=k3s-control-plane-01/k3s-token
    - onlyif: test -s /var/lib/rancher/k3s/server/node-token
    - require:
      - service: k3s-service
