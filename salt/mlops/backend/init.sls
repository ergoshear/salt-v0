{% set key = salt['pillar.get']('INFERENCE_BACKEND_KEY', '') %}
inference-backend-key:
{% if key %}
  file.managed:
    - name: /home/mlops/.config/llama/backend-key
    - user: mlops
    - group: mlops
    - mode: '0600'
    - makedirs: True
    - show_changes: False
    - contents: {{ key | tojson }}
{% else %}
  file.exists:
    - name: /home/mlops/.config/llama/backend-key
{% endif %}

inference-backend-header:
  cmd.run:
    - name: |
        /usr/bin/python3 - <<'PY'
        import os
        import pwd
        from pathlib import Path
        directory = Path("/home/mlops/.config/llama")
        key = (directory / "backend-key").read_text().strip()
        if not key or any(c in key for c in '\r\n"'):
            raise ValueError("Inference key must be a nonempty single-line opaque value")
        os.umask(0o077)
        path = directory / "auth-header"
        path.write_text("Authorization: Bearer " + key + "\n")
        user = pwd.getpwnam("mlops")
        os.chown(path, user.pw_uid, user.pw_gid)
        path.chmod(0o600)
        os.chown(directory / "backend-key", user.pw_uid, user.pw_gid)
        (directory / "backend-key").chmod(0o600)
        PY
    - hide_output: True
    - require:
      - file: inference-backend-key

inference-firewall-package:
  pkg.installed:
    - pkgs:
      - nftables
      - firewalld

inference-firewalld:
  service.running:
    - name: firewalld
    - enable: True
    - require:
      - pkg: inference-firewall-package

inference-firewalld-tailnet:
  firewalld.present:
    - name: public
    - rich_rules:
      - 'rule family="ipv4" source address="100.64.0.0/10" port port="8080" protocol="tcp" accept'
      - 'rule family="ipv6" source address="fd7a:115c:a1e0::/48" port port="8080" protocol="tcp" accept'
    - prune_rich_rules: False
    - require:
      - service: inference-firewalld
      - cmd: inference-firewall-apply

inference-firewall-script:
  file.managed:
    - name: /usr/local/sbin/inference-firewall
    - source: salt://mlops/backend/firewall.py
    - mode: '0700'

inference-firewall-unit:
  file.managed:
    - name: /etc/systemd/system/inference-firewall.service
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Only Kubernetes inference gateways may reach port 8080
        After=tailscaled.service
        Before=user@1000.service
        [Service]
        Type=oneshot
        ExecStart=/usr/bin/python3 /usr/local/sbin/inference-firewall
        [Install]
        WantedBy=multi-user.target

inference-firewall-timer-unit:
  file.managed:
    - name: /etc/systemd/system/inference-firewall.timer
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Refresh authenticated inference proxy addresses
        [Timer]
        OnBootSec=5s
        OnUnitActiveSec=30s
        [Install]
        WantedBy=timers.target

inference-firewall-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: inference-firewall-unit
      - file: inference-firewall-timer-unit

inference-firewall-apply:
  cmd.run:
    - name: /usr/bin/python3 /usr/local/sbin/inference-firewall
    - timeout: 60
    - require:
      - pkg: inference-firewall-package
      - file: inference-firewall-script

inference-firewall-timer:
  service.running:
    - name: inference-firewall.timer
    - enable: True
    - require:
      - cmd: inference-firewall-reload
      - cmd: inference-firewall-apply

inference-firewall-boot:
  service.enabled:
    - name: inference-firewall.service
    - require:
      - cmd: inference-firewall-reload
