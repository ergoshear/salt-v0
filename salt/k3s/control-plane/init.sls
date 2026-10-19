{% if grains['id'] != 'k3s-control-plane-01' %}
k3s-control-plane-prerequisites:
  test.fail_without_changes:
    - name: k3s control plane requires k3s-control-plane-01
{% else %}
{% set helm_job_image = 'rancher/klipper-helm:v0.13.3-build20261014' %}
include:
  - k3s.network

k3s-pkgs-install:
  pkg.installed:
    - names:
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
        tls-san:
          - k3s.ergoshear.dev
          - k3s-control-plane-01.tailb11f97.ts.net
        node-taint:
          - "node-role.kubernetes.io/control-plane=true:NoSchedule"

k3s-control-plane-systemd-network:
  file.managed:
    - name: /etc/systemd/system/k3s.service.d/network.conf
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - contents: |
        [Unit]
        Requires=tailscaled.service
        After=tailscaled.service network-online.target
        [Service]
        ExecStartPre=/usr/bin/python3 /usr/local/sbin/salt-tailscale-node configure k3s-control-plane-01

k3s-control-plane-systemd-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: k3s-control-plane-systemd-network

k3s-control-plane-installer:
  file.managed:
    - name: /usr/local/src/k3s-install.sh
    - source: https://get.k3s.io
    - skip_verify: True
    - mode: '0700'
    - makedirs: True

k3s-install:
  cmd.run:
    - name: sh /usr/local/src/k3s-install.sh
    - unless: test -x /usr/local/bin/k3s
    - require:
      - file: k3s-control-plane-config
      - file: k3s-control-plane-installer
      - cmd: k3s-control-plane-systemd-reload
      - cmd: k3s-tailscale-config

k3s-service:
  service.running:
    - name: k3s
    - enable: True
    - require:
      - cmd: k3s-install
    - watch:
      - file: k3s-control-plane-config
      - file: k3s-control-plane-systemd-network
      - cmd: k3s-tailscale-config

k3s-traefik-helm-job-image:
  cmd.run:
    - name: >-
        /usr/local/bin/k3s kubectl patch helmcharts.helm.cattle.io traefik
        -n kube-system --type=merge
        -p '{"spec":{"jobImage":"{{ helm_job_image }}"}}'
    - unless: >-
        test "$(/usr/local/bin/k3s kubectl get helmcharts.helm.cattle.io traefik
        -n kube-system -o jsonpath='{.spec.jobImage}')" = "{{ helm_job_image }}"
    - require:
      - service: k3s-service

k3s-traefik-crd-helm-job-image:
  cmd.run:
    - name: >-
        /usr/local/bin/k3s kubectl patch helmcharts.helm.cattle.io traefik-crd
        -n kube-system --type=merge
        -p '{"spec":{"jobImage":"{{ helm_job_image }}"}}'
    - unless: >-
        test "$(/usr/local/bin/k3s kubectl get helmcharts.helm.cattle.io traefik-crd
        -n kube-system -o jsonpath='{.spec.jobImage}')" = "{{ helm_job_image }}"
    - require:
      - service: k3s-service

k3s-kubectl:
  file.symlink:
    - name: /usr/local/bin/kubectl
    - target: /usr/local/bin/k3s
    - unless: test -x /usr/local/bin/kubectl
    - require:
      - cmd: k3s-install

k3s-network-verifier:
  file.managed:
    - name: /usr/local/sbin/salt-k3s-verify
    - source: salt://k3s/verify.py
    - mode: '0700'

k3s-publish-token:
  cmd.run:
    - name: salt-call cp.push /var/lib/rancher/k3s/server/node-token upload_path=k3s-control-plane-01/k3s-token
    - onlyif: test -s /var/lib/rancher/k3s/server/node-token
    - require:
      - service: k3s-service
{% endif %}
