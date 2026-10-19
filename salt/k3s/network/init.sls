include:
  - tailscale

k3s-firewall-package:
  pkg.installed:
    - name: firewalld

k3s-firewalld:
  service.running:
    - name: firewalld
    - enable: True
    - require:
      - pkg: k3s-firewall-package

k3s-firewall-cluster:
  firewalld.present:
    - name: trusted
    - interfaces:
      - tailscale0
    - sources:
      - 10.42.0.0/16
      - 10.43.0.0/16
    - prune_services: False
    - require:
      - service: k3s-firewalld

{% if grains['id'] == 'k3s-control-plane-01' %}
k3s-firewall-public:
  firewalld.present:
    - name: public
    - ports:
      - 80/tcp
      - 443/tcp
    - rich_rules:
      - 'rule family="ipv4" source address="173.72.146.35/32" port port="6443" protocol="tcp" accept'
    - prune_services: False
    - require:
      - service: k3s-firewalld
{% endif %}

k3s-ip-forward:
  sysctl.present:
    - name: net.ipv4.ip_forward
    - value: 1

k3s-tailscale-config:
  cmd.run:
    - name: /usr/bin/python3 /usr/local/sbin/salt-tailscale-node configure {{ grains['id'] | tojson }}
    - stateful: True
    - python_shell: False
    - require:
      - cmd: tailscale-enroll
      - firewalld: k3s-firewall-cluster
      - sysctl: k3s-ip-forward
