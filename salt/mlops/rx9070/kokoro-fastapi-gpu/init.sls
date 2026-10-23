{% if grains['id'] == 'mlops-node-3' %}
include:
  - tailscale

kokoro_podman:
  pkg.installed:
    - name: podman

kokoro_gpu_ready:
  cmd.run:
    - name: test -c /dev/kfd && test -d /dev/dri
    - require:
      - pkg: kokoro_podman

kokoro_rocm_image:
  cmd.run:
    - name: podman pull --quiet ghcr.io/remsky/kokoro-fastapi-rocm:latest
    - unless: podman image exists ghcr.io/remsky/kokoro-fastapi-rocm:latest
    - require:
      - pkg: kokoro_podman
      - cmd: kokoro_gpu_ready

kokoro_systemd_unit:
  file.managed:
    - name: /etc/systemd/system/kokoro-fastapi.service
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Kokoro FastAPI ROCm text-to-speech service
        Wants=network-online.target
        After=network-online.target
        After=tailscaled.service

        [Service]
        Type=simple
        ExecStartPre=-/usr/bin/podman rm -f kokoro-fastapi-rocm
        ExecStart=/usr/bin/podman run --rm --name kokoro-fastapi-rocm \
          --device=/dev/kfd --device=/dev/dri \
          --publish=127.0.0.1:8880:8880 \
          ghcr.io/remsky/kokoro-fastapi-rocm:latest
        ExecStop=/usr/bin/podman stop -t 10 kokoro-fastapi-rocm
        Restart=on-failure
        RestartSec=10
        TimeoutStopSec=30

        [Install]
        WantedBy=multi-user.target

kokoro_systemd_reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: kokoro_systemd_unit

kokoro_service:
  service.running:
    - name: kokoro-fastapi
    - enable: True
    - require:
      - cmd: kokoro_gpu_ready
      - cmd: kokoro_rocm_image
      - cmd: kokoro_systemd_reload
    - watch:
      - file: kokoro_systemd_unit
      - cmd: kokoro_rocm_image

kokoro_tailscale_serve:
  cmd.run:
    - name: tailscale serve --bg --https=443 http://127.0.0.1:8880
    - unless: tailscale serve status | grep -Fq '127.0.0.1:8880'
    - require:
      - service: tailscale-service
      - service: kokoro_service
{% else %}
kokoro_target_guard:
  test.fail_without_changes:
    - name: Kokoro FastAPI ROCm is restricted to mlops-node-3
{% endif %}