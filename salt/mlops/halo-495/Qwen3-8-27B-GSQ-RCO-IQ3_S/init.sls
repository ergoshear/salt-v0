{% set user = 'mlops' %}
{% set home = '/home/' ~ user %}
include:
  - mlops.backend
  - mlops.huggingface
{% set qwen36_dir = home ~ '/models/Qwen3.6-35B-A3B-MTP-GGUF' %}
{% set qwen38_dir = home ~ '/models/Qwen3.8-27B-GSQ-RCO-GGUF' %}

# ==============================================================================
# 1. Base Packages & System Dependencies (Fedora 44)
# ==============================================================================
halo495_base_packages:
  pkg.installed:
    - names:
      - podman
      - toolbox
      - python3-pip
      - git
      - wget2-wget
      - jq
      - tuned
      - firewalld
      - pciutils
      - vulkan-tools

# ==============================================================================
# 2. User Account, Groups, and Rootless Podman SubUID/SubGID Mappings
# ==============================================================================
halo495_user_account:
  user.present:
    - name: {{ user }}
    - home: {{ home }}
    - groups:
      - video
      - render
      - wheel
    - remove_groups: False
    - require:
      - pkg: halo495_base_packages

halo495_subuid_mapping:
  file.append:
    - name: /etc/subuid
    - text: "{{ user }}:100000:65536"
    - unless: grep -q "^{{ user }}:" /etc/subuid
    - require:
      - user: halo495_user_account

halo495_subgid_mapping:
  file.append:
    - name: /etc/subgid
    - text: "{{ user }}:100000:65536"
    - unless: grep -q "^{{ user }}:" /etc/subgid
    - require:
      - user: halo495_user_account

# ==============================================================================
# 3. Home Directory Permissions & Podman Migration
# ==============================================================================
halo495_home_dir_permissions:
  file.directory:
    - name: {{ home }}
    - user: {{ user }}
    - group: {{ user }}
    - dir_mode: '0755'
    - require:
      - user: halo495_user_account

halo495_local_share_dir:
  file.directory:
    - name: {{ home }}/.local/share
    - user: {{ user }}
    - group: {{ user }}
    - makedirs: True
    - dir_mode: '0755'
    - require:
      - file: halo495_home_dir_permissions

halo495_podman_migrate:
  cmd.run:
    - name: podman system migrate
    - runas: {{ user }}
    - onchanges:
      - file: halo495_subuid_mapping
      - file: halo495_subgid_mapping
      - file: halo495_home_dir_permissions

# ==============================================================================
# 4. PAM Locked Memory & 184GB Unified GTT Pool (amdgpu)
# ==============================================================================
halo495_memlock_limits:
  file.managed:
    - name: /etc/security/limits.d/99-amdgpu-memlock.conf
    - mode: '0644'
    - contents: |
        * soft memlock unlimited
        * hard memlock unlimited

halo495_amdgpu_gtt_modprobe:
  file.managed:
    - name: /etc/modprobe.d/amdgpu-gtt.conf
    - mode: '0644'
    - contents: |
        # Allocate up to 184 GB (188416 MiB) of 192 GB LPDDR5X to GPU GTT pool
        options amdgpu gttsize=188416 pages_limit=48234496

# ==============================================================================
# 5. Disable Sleep Targets & Lock Strix Halo Performance Clocks
# ==============================================================================
{% for target in ['sleep', 'suspend', 'hibernate', 'hybrid-sleep', 'suspend-then-hibernate'] %}
mask_halo495_{{ target }}_target:
  service.masked:
    - name: {{ target }}.target
{% endfor %}

halo495_tuned_service:
  service.running:
    - name: tuned
    - enable: True
    - require:
      - pkg: halo495_base_packages

halo495_tuned_profile:
  cmd.run:
    - name: tuned-adm profile throughput-performance
    - unless: tuned-adm active | grep -q "throughput-performance"
    - require:
      - service: halo495_tuned_service

halo495_amdgpu_high_dpm_udev:
  file.managed:
    - name: /etc/udev/rules.d/30-amdgpu-high-dpm.rules
    - mode: '0644'
    - contents: |
        KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ATTR{device/power_dpm_force_performance_level}="high"

halo495_apply_amdgpu_dpm_now:
  cmd.run:
    - name: bash -c 'echo high > /sys/class/drm/card*/device/power_dpm_force_performance_level'
    - unless: grep -q "^high$" /sys/class/drm/card*/device/power_dpm_force_performance_level
    - onlyif: ls /sys/class/drm/card*/device/power_dpm_force_performance_level

# ==============================================================================
# 6. Ensure Firewalld Is Running (mlops.backend Manages Port 8080 Access)
# ==============================================================================
halo495_firewalld_service:
  service.running:
    - name: firewalld
    - enable: True
    - require:
      - pkg: halo495_base_packages

halo495_firewall_port_8080:
  cmd.run:
    - name: firewall-cmd --permanent --remove-port=8080/tcp; firewall-cmd --remove-port=8080/tcp
    - onlyif: firewall-cmd --query-port=8080/tcp || firewall-cmd --permanent --query-port=8080/tcp
    - require:
      - service: halo495_firewalld_service

# ==============================================================================
# 7. Install Hugging Face CLI (with hf_xet) & Ensure PATH in .bashrc
# ==============================================================================
halo495_install_hf_cli:
  cmd.run:
    - name: pip3 install --user -U "huggingface_hub[cli,hf_xet]"
    - runas: {{ user }}
    - creates: {{ home }}/.local/bin/hf
    - require:
      - pkg: halo495_base_packages
      - user: halo495_user_account

halo495_user_bashrc_path:
  file.append:
    - name: {{ home }}/.bashrc
    - text: 'export PATH="$HOME/.local/bin:$PATH"'
    - unless: grep -q '\.local/bin' {{ home }}/.bashrc
    - require:
      - user: halo495_user_account

# ==============================================================================
# 8. Enable Linger, Create Vulkan RADV Toolbx & Update llama-server Binary
# ==============================================================================
halo495_enable_linger:
  cmd.run:
    - name: loginctl enable-linger {{ user }}
    - creates: /var/lib/systemd/linger/{{ user }}
    - require:
      - user: halo495_user_account

halo495_create_vulkan_toolbox:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        toolbox --assumeyes create llama-vulkan-radv \
          --image docker.io/kyuz0/amd-strix-halo-toolboxes:vulkan-radv
    - runas: {{ user }}
    - unless: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        podman container exists llama-vulkan-radv
    - require:
      - cmd: halo495_enable_linger
      - file: halo495_local_share_dir
      - file: halo495_memlock_limits
      - cmd: halo495_podman_migrate

halo495_build_upstream_llama_server:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        systemctl --user stop strix-llama-router.service || true
        podman start llama-vulkan-radv
        podman exec --user 0 llama-vulkan-radv bash -e -c '
          dnf install -y lld mold git cmake gcc gcc-c++ ninja-build \
            vulkan-headers vulkan-loader-devel glslc libcurl-devel
          if [ ! -e /usr/bin/ld ]; then
            ln -sf /usr/bin/ld.bfd /usr/bin/ld || ln -sf /usr/bin/ld.lld /usr/bin/ld
          fi
          rm -rf /opt/llama-master
          git clone --depth 1 https://github.com/ggml-org/llama.cpp.git /opt/llama-master
          cmake -B /opt/llama-master/build -S /opt/llama-master -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_SHARED_LIBS=OFF \
            -DGGML_VULKAN=ON \
            -DGGML_NATIVE=ON
          cmake --build /opt/llama-master/build --config Release -j $(nproc) \
            --target llama-server llama-cli
          cp -af /opt/llama-master/build/bin/llama-server /usr/local/bin/
          cp -af /opt/llama-master/build/bin/llama-server /usr/bin/
          touch /etc/llama-server-master-qwen38-gsq-mtp
        '
    - runas: {{ user }}
    - unless: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        podman start llama-vulkan-radv >/dev/null 2>&1
        podman exec llama-vulkan-radv test -f /etc/llama-server-master-qwen38-gsq-mtp && \
        podman exec llama-vulkan-radv test -x /usr/local/bin/llama-server
    - timeout: 1800
    - require:
      - cmd: halo495_create_vulkan_toolbox

# ==============================================================================
# 9. Download Qwen3.6-35B-A3B (+ DFlash) & Qwen3.8-27B-GSQ-RCO (IQ3_S-mtp + Vision)
# ==============================================================================
halo495_download_qwen36_35b_a3b:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download unsloth/Qwen3.6-35B-A3B-MTP-GGUF
        --include "*UD-Q4_K_XL*"
        --local-dir {{ qwen36_dir }}
    - runas: {{ user }}
    - creates: {{ qwen36_dir }}/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
    - timeout: 3600
    - require:
      - cmd: halo495_install_hf_cli

halo495_download_qwen36_35b_dflash_drafter:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download williamliao/Qwen3.6-35B-A3B-DFlash-GGUF
        Qwen3.6-35B-A3B-DFlash-Q4_K_M.gguf
        --local-dir {{ qwen36_dir }}
    - runas: {{ user }}
    - creates: {{ qwen36_dir }}/Qwen3.6-35B-A3B-DFlash-Q4_K_M.gguf
    - timeout: 1800
    - require:
      - cmd: halo495_install_hf_cli

halo495_download_qwen36_sharp_template:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download peculiar-ragdoll/Qwen-Sharp-Chat-Templates
        chat_template.jinja
        --local-dir {{ qwen36_dir }}
    - runas: {{ user }}
    - creates: {{ qwen36_dir }}/chat_template.jinja
    - require:
      - cmd: halo495_install_hf_cli

halo495_download_qwen38_gsq_rco_main:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF
        Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf
        --local-dir {{ qwen38_dir }}
    - runas: {{ user }}
    - creates: {{ qwen38_dir }}/Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf
    - timeout: 3600
    - require:
      - cmd: halo495_install_hf_cli

halo495_download_qwen38_gsq_rco_mmproj:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF
        mmproj-Qwen3.8-27B-BF16.gguf
        --local-dir {{ qwen38_dir }}
    - runas: {{ user }}
    - creates: {{ qwen38_dir }}/mmproj-Qwen3.8-27B-BF16.gguf
    - timeout: 1800
    - require:
      - cmd: halo495_install_hf_cli

halo495_download_qwen38_sharp_template:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download peculiar-ragdoll/Qwen-Sharp-Chat-Templates
        chat_template.jinja
        --local-dir {{ qwen38_dir }}
    - runas: {{ user }}
    - creates: {{ qwen38_dir }}/chat_template.jinja
    - require:
      - cmd: halo495_install_hf_cli

# ==============================================================================
# 10. Manage ~/models/models.ini (2 Consolidated Resident Slots = 0s Swap!)
#     Slot 1: Qwen3.6-35B-A3B-DFlash-512K (524,288 context window + 16-tok DFlash)
#     Slot 2: Qwen3.8-27B (GSQ-RCO-IQ3_S-mtp + 262,144 context + draft-mtp + Vision)
# ==============================================================================
halo495_models_preset_ini:
  file.managed:
    - name: {{ home }}/models/models.ini
    - user: {{ user }}
    - group: {{ user }}
    - mode: '0644'
    - makedirs: True
    - contents: |
        [Qwen3.6-35B-A3B-DFlash-512K]
        model = {{ qwen36_dir }}/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
        model-draft = {{ qwen36_dir }}/Qwen3.6-35B-A3B-DFlash-Q4_K_M.gguf
        fit = off
        n-gpu-layers = 999
        n-gpu-layers-draft = 999
        load-mode = none
        flash-attn = 1
        jinja = true
        chat-template-file = {{ qwen36_dir }}/chat_template.jinja
        no-reasoning-preserve = true
        parallel = 1
        spec-type = draft-dflash
        spec-draft-n-max = 16
        spec-draft-p-min = 0.75
        cache-type-k = q8_0
        cache-type-v = q8_0
        ctx-size = 524288
        rope-scaling = yarn
        rope-scale = 2.0
        yarn-orig-ctx = 262144
        ubatch-size = 2048
        batch-size = 4096
        threads = 16
        temp = 0.6
        top-p = 0.95
        top-k = 20

        [Qwen3.8-27B]
        model = {{ qwen38_dir }}/Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf
        mmproj = {{ qwen38_dir }}/mmproj-Qwen3.8-27B-BF16.gguf
        fit = off
        n-gpu-layers = 999
        load-mode = none
        flash-attn = 1
        jinja = true
        chat-template-file = {{ qwen38_dir }}/chat_template.jinja
        no-reasoning-preserve = true
        parallel = 1
        spec-type = draft-mtp
        cache-type-k = q8_0
        cache-type-v = q8_0
        ctx-size = 262144
        ubatch-size = 2048
        batch-size = 4096
        threads = 16
        temp = 0.7
        top-p = 0.8
        top-k = 20
    - require:
      - cmd: halo495_download_qwen36_35b_a3b
      - cmd: halo495_download_qwen36_35b_dflash_drafter
      - cmd: halo495_download_qwen36_sharp_template
      - cmd: halo495_download_qwen38_gsq_rco_main
      - cmd: halo495_download_qwen38_gsq_rco_mmproj
      - cmd: halo495_download_qwen38_sharp_template

# ==============================================================================
# 11. Systemd User Service: strix-llama-router.service (--models-max 2 Resident)
# ==============================================================================
halo495_systemd_user_dir:
  file.directory:
    - name: {{ home }}/.config/systemd/user
    - user: {{ user }}
    - group: {{ user }}
    - makedirs: True
    - dir_mode: '0755'
    - require:
      - user: halo495_user_account

halo495_router_systemd_unit:
  file.managed:
    - name: {{ home }}/.config/systemd/user/strix-llama-router.service
    - user: {{ user }}
    - group: {{ user }}
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Strix Halo 192GB llama-server Router (--models-max 2 Zero-Swap Resident Mode)
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        Environment="HOME={{ home }}"
        Environment="PATH={{ home }}/.local/bin:/usr/local/bin:/usr/bin:/bin"
        Environment="GGML_VK_MAX_MB_PER_SUBMIT=2048"
        Environment="LLAMA_ARG_MMAP=0"
        WorkingDirectory={{ home }}

        ExecStartPre=/usr/bin/podman start llama-vulkan-radv
        ExecStartPre=-/usr/bin/podman exec --user 0 llama-vulkan-radv pkill -9 -x llama-server

        ExecStart=/usr/bin/toolbox run --container llama-vulkan-radv \
          /usr/local/bin/llama-server \
          --models-preset {{ home }}/models/models.ini \
          --models-max 2 \
          --models-autoload \
          --jinja \
          --api-key-file {{ home }}/.config/llama/backend-key \
          --host 0.0.0.0 \
          --port 8080

        # Pre-warm both resident models into 192GB LPDDR5X on startup (stop on <think> so it finishes in <1s)
        ExecStartPost=-/usr/bin/bash -c 'sleep 3 && \
          for m in "Qwen3.6-35B-A3B-DFlash-512K" "Qwen3.8-27B"; do \
            curl -s http://127.0.0.1:8080/v1/chat/completions \
              -H "Content-Type: application/json" \
              --header @{{ home }}/.config/llama/auth-header \
              -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":1,\"stop\":[\"<think>\",\"\\n\"]}" >/dev/null 2>&1 \
          done &'

        ExecStop=/usr/bin/podman stop -t 10 llama-vulkan-radv
        Restart=on-failure
        RestartSec=10
        LimitMEMLOCK=infinity
        TimeoutStartSec=300

        [Install]
        WantedBy=default.target
    - require:
      - file: halo495_systemd_user_dir
      - file: halo495_models_preset_ini
      - cmd: inference-backend-header

halo495_enable_and_start_router_service:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        systemctl --user daemon-reload
        systemctl --user enable --now strix-llama-router.service
    - runas: {{ user }}
    - unless: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        systemctl --user is-active --quiet strix-llama-router.service
    - require:
      - cmd: halo495_enable_linger
      - cmd: halo495_create_vulkan_toolbox
      - cmd: halo495_build_upstream_llama_server
      - file: halo495_models_preset_ini
      - file: halo495_router_systemd_unit

halo495_restart_router_on_config_change:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        systemctl --user daemon-reload
        systemctl --user restart strix-llama-router.service
    - runas: {{ user }}
    - onchanges:
      - cmd: halo495_build_upstream_llama_server
      - file: halo495_router_systemd_unit
      - file: halo495_models_preset_ini
    - require:
      - cmd: halo495_enable_and_start_router_service