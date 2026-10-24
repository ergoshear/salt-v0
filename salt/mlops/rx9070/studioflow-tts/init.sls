{% if grains['id'] == 'mlops-node-3' %}
include:
  - tailscale

studioflow_tts_packages:
  pkg.installed:
    - pkgs:
      - git
      - podman

studioflow_tts_github_known_hosts:
  file.managed:
    - name: /etc/studioflow-tts/known_hosts
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - contents: |
        github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl

studioflow_tts_checkout_helper:
  file.managed:
    - name: /usr/local/libexec/studioflow-tts-checkout
    - user: root
    - group: root
    - mode: '0700'
    - show_changes: False
    - makedirs: True
    - contents: |
        #!/usr/bin/python3
        import os
        import subprocess
        from pathlib import Path

        repository = "git@github.com:ergoshear/studioflow-tts.git"
        checkout = Path("/opt/studioflow-tts")
        env = os.environ.copy()
        env["GIT_SSH_COMMAND"] = (
            "/usr/bin/ssh -i /home/mlops/.ssh/studioflow-tts "
            "-o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes "
            "-o UserKnownHostsFile=/etc/studioflow-tts/known_hosts "
            "-o GlobalKnownHostsFile=/dev/null"
        )

        def run_git(*args, capture=False):
            return subprocess.run(
                ["/usr/bin/git", *args],
                check=True,
                env=env,
                text=True,
                stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            )

        if (checkout / ".git").is_dir():
            current = run_git("-C", str(checkout), "rev-parse", "HEAD", capture=True).stdout.strip()
            run_git("-C", str(checkout), "fetch", "--quiet", "--depth=1", "origin", "main")
            latest = run_git("-C", str(checkout), "rev-parse", "FETCH_HEAD", capture=True).stdout.strip()
            changed = current != latest
            if changed:
                run_git("-C", str(checkout), "reset", "--hard", "FETCH_HEAD")
        else:
            run_git("clone", "--quiet", "--depth=1", "--branch", "main", repository, str(checkout))
            changed = True

        print("changed={} comment=StudioFlow-source-{}".format(
            "yes" if changed else "no",
            "updated" if changed else "current",
        ))

studioflow_tts_checkout:
  cmd.run:
    - name: /usr/bin/python3 /usr/local/libexec/studioflow-tts-checkout
    - stateful: True
    - hide_output: True
    - require:
      - pkg: studioflow_tts_packages
      - file: studioflow_tts_checkout_helper
      - file: studioflow_tts_github_known_hosts

{% for directory in ['voices', 'hf_cache', 'checkpoints'] %}
studioflow_tts_{{ directory }}_directory:
  file.directory:
    - name: /var/lib/studioflow-tts/{{ directory }}
    - user: root
    - group: root
    - mode: '0755'
    - makedirs: True
{% endfor %}

studioflow_tts_gpu_ready:
  cmd.run:
    - name: test -c /dev/kfd && test -c /dev/dri/renderD128
    - require:
      - pkg: studioflow_tts_packages

studioflow_tts_build_images:
  cmd.run:
    - name: |
        set -eu
        podman build --quiet --tag localhost/studioflow-fish-speech:latest \
          --file /opt/studioflow-tts/Containerfile.fish-speech /opt/studioflow-tts
        podman build --quiet --tag localhost/studioflow-zonos:latest \
          --file /opt/studioflow-tts/Containerfile.zonos /opt/studioflow-tts
        podman build --quiet --tag localhost/studioflow-whisper:latest \
          --file /opt/studioflow-tts/Containerfile.whisper /opt/studioflow-tts
        git -C /opt/studioflow-tts rev-parse HEAD > /var/lib/studioflow-tts/container-images-revision
    - timeout: 3600
    - require:
      - cmd: studioflow_tts_checkout
      - cmd: studioflow_tts_gpu_ready
    - unless: >-
        test -f /var/lib/studioflow-tts/container-images-revision &&
        test "$(cat /var/lib/studioflow-tts/container-images-revision)" =
        "$(git -C /opt/studioflow-tts rev-parse HEAD)" &&
        podman image exists localhost/studioflow-fish-speech:latest &&
        podman image exists localhost/studioflow-zonos:latest &&
        podman image exists localhost/studioflow-whisper:latest

studioflow_fish_speech_unit:
  file.managed:
    - name: /etc/systemd/system/studioflow-fish-speech.service
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        [Unit]
        Description=StudioFlow Fish Speech ROCm service
        Wants=network-online.target
        After=network-online.target
        After=tailscaled.service

        [Service]
        Type=simple
        ExecStartPre=-/usr/bin/podman rm -f studioflow-fish-speech
        ExecStart=/usr/bin/podman run --rm --name studioflow-fish-speech \
          --device=/dev/kfd --device=/dev/dri \
          --security-opt=label=disable --ipc=host \
          --volume=/var/lib/studioflow-tts/voices:/app/voices:z \
          --volume=/var/lib/studioflow-tts/hf_cache:/app/hf_cache:z \
          --volume=/var/lib/studioflow-tts/checkpoints:/app/checkpoints:z \
          --publish=127.0.0.1:8001:8001 \
          localhost/studioflow-fish-speech:latest
        ExecStop=/usr/bin/podman stop -t 10 studioflow-fish-speech
        Restart=on-failure
        RestartSec=10
        TimeoutStopSec=30

        [Install]
        WantedBy=multi-user.target

studioflow_zonos_unit:
  file.managed:
    - name: /etc/systemd/system/studioflow-zonos.service
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        [Unit]
        Description=StudioFlow Zonos ROCm service
        Wants=network-online.target
        After=network-online.target
        After=tailscaled.service

        [Service]
        Type=simple
        ExecStartPre=-/usr/bin/podman rm -f studioflow-zonos
        ExecStart=/usr/bin/podman run --rm --name studioflow-zonos \
          --device=/dev/kfd --device=/dev/dri \
          --security-opt=label=disable --ipc=host \
          --volume=/var/lib/studioflow-tts/voices:/app/voices:z \
          --volume=/var/lib/studioflow-tts/hf_cache:/app/hf_cache:z \
          --volume=/var/lib/studioflow-tts/checkpoints:/app/checkpoints:z \
          --publish=127.0.0.1:8002:8002 \
          localhost/studioflow-zonos:latest
        ExecStop=/usr/bin/podman stop -t 10 studioflow-zonos
        Restart=on-failure
        RestartSec=10
        TimeoutStopSec=30

        [Install]
        WantedBy=multi-user.target

studioflow_whisper_unit:
  file.managed:
    - name: /etc/systemd/system/studioflow-whisper.service
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        [Unit]
        Description=StudioFlow Whisper OpenVINO Intel GPU service
        Wants=network-online.target
        After=network-online.target
        After=tailscaled.service

        [Service]
        Type=simple
        ExecStartPre=-/usr/bin/podman rm -f studioflow-whisper
        ExecStart=/usr/bin/podman run --rm --name studioflow-whisper \
          --device=/dev/dri/renderD128 \
          --security-opt=label=disable --ipc=host \
          --volume=/var/lib/studioflow-tts/voices:/app/voices:z \
          --volume=/var/lib/studioflow-tts/hf_cache:/app/hf_cache:z \
          --volume=/var/lib/studioflow-tts/checkpoints:/app/checkpoints:z \
          --publish=127.0.0.1:8003:8003 \
          localhost/studioflow-whisper:latest
        ExecStop=/usr/bin/podman stop -t 10 studioflow-whisper
        Restart=on-failure
        RestartSec=10
        TimeoutStopSec=30

        [Install]
        WantedBy=multi-user.target

studioflow_tts_systemd_reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: studioflow_fish_speech_unit
      - file: studioflow_zonos_unit
      - file: studioflow_whisper_unit

{% for name in ['fish-speech', 'zonos', 'whisper'] %}
studioflow_{{ name.replace('-', '_') }}_service:
  service.running:
    - name: studioflow-{{ name }}
    - enable: True
    - require:
      - cmd: studioflow_tts_gpu_ready
      - cmd: studioflow_tts_build_images
      - cmd: studioflow_tts_systemd_reload
      - file: studioflow_tts_voices_directory
      - file: studioflow_tts_hf_cache_directory
      - file: studioflow_tts_checkpoints_directory
    - watch:
      - cmd: studioflow_tts_build_images
      - file: studioflow_{{ name.replace('-', '_') }}_unit
{% endfor %}

studioflow_fish_speech_tailscale_serve:
  cmd.run:
    - name: tailscale serve --bg --https=8001 http://127.0.0.1:8001
    - unless: tailscale serve status | grep -Fq '127.0.0.1:8001'
    - require:
      - service: tailscale-service
      - service: studioflow_fish_speech_service

studioflow_zonos_tailscale_serve:
  cmd.run:
    - name: tailscale serve --bg --https=8002 http://127.0.0.1:8002
    - unless: tailscale serve status | grep -Fq '127.0.0.1:8002'
    - require:
      - service: tailscale-service
      - service: studioflow_zonos_service

studioflow_whisper_tailscale_serve:
  cmd.run:
    - name: tailscale serve --bg --https=8003 http://127.0.0.1:8003
    - unless: tailscale serve status | grep -Fq '127.0.0.1:8003'
    - require:
      - service: tailscale-service
      - service: studioflow_whisper_service
{% else %}
studioflow_tts_target_guard:
  test.fail_without_changes:
    - name: StudioFlow TTS services are restricted to mlops-node-3
{% endif %}