{% set user = 'mlops' %}
{% set home = '/home/' ~ user %}
include:
  - mlops.backend
  - mlops.huggingface
{% set ornith_dir = home ~ '/models/Ornith-1.5-35B-A3B-GGUF' %}

# ==============================================================================
# 1. Base Packages & System Dependencies (Fedora 44)
# ==============================================================================
halo395_base_packages:
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
halo395_user_account:
  user.present:
    - name: {{ user }}
    - home: {{ home }}
    - groups:
      - video
      - render
      - wheel
    - remove_groups: False
    - require:
      - pkg: halo395_base_packages

halo395_subuid_mapping:
  file.append:
    - name: /etc/subuid
    - text: "{{ user }}:100000:65536"
    - unless: grep -q "^{{ user }}:" /etc/subuid
    - require:
      - user: halo395_user_account

halo395_subgid_mapping:
  file.append:
    - name: /etc/subgid
    - text: "{{ user }}:100000:65536"
    - unless: grep -q "^{{ user }}:" /etc/subgid
    - require:
      - user: halo395_user_account

# ==============================================================================
# 3. Home Directory Permissions & Podman Migration
# ==============================================================================
halo395_home_dir_permissions:
  file.directory:
    - name: {{ home }}
    - user: {{ user }}
    - group: {{ user }}
    - dir_mode: '0755'
    - require:
      - user: halo395_user_account

halo395_local_share_dir:
  file.directory:
    - name: {{ home }}/.local/share
    - user: {{ user }}
    - group: {{ user }}
    - makedirs: True
    - dir_mode: '0755'
    - require:
      - file: halo395_home_dir_permissions

halo395_podman_migrate:
  cmd.run:
    - name: podman system migrate
    - runas: {{ user }}
    - onchanges:
      - file: halo395_subuid_mapping
      - file: halo395_subgid_mapping
      - file: halo395_home_dir_permissions

# ==============================================================================
# 4. PAM Locked Memory & 124GB Unified GTT Pool (amdgpu)
# ==============================================================================
halo395_memlock_limits:
  file.managed:
    - name: /etc/security/limits.d/99-amdgpu-memlock.conf
    - mode: '0644'
    - contents: |
        * soft memlock unlimited
        * hard memlock unlimited

halo395_amdgpu_gtt_modprobe:
  file.managed:
    - name: /etc/modprobe.d/amdgpu-gtt.conf
    - mode: '0644'
    - contents: |
        # Allocate up to 124 GB (126976 MiB) of 128 GB LPDDR5X to GPU GTT pool
        options amdgpu gttsize=126976 pages_limit=32505856

# ==============================================================================
# 5. Disable Sleep Targets & Lock Strix Halo Performance Clocks
# ==============================================================================
{% for target in ['sleep', 'suspend', 'hibernate', 'hybrid-sleep', 'suspend-then-hibernate'] %}
mask_halo395_{{ target }}_target:
  service.masked:
    - name: {{ target }}.target
{% endfor %}

halo395_tuned_service:
  service.running:
    - name: tuned
    - enable: True
    - require:
      - pkg: halo395_base_packages

halo395_tuned_profile:
  cmd.run:
    - name: tuned-adm profile throughput-performance
    - unless: tuned-adm active | grep -q "throughput-performance"
    - require:
      - service: halo395_tuned_service

halo395_amdgpu_high_dpm_udev:
  file.managed:
    - name: /etc/udev/rules.d/30-amdgpu-high-dpm.rules
    - mode: '0644'
    - contents: |
        KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ATTR{device/power_dpm_force_performance_level}="high"

halo395_apply_amdgpu_dpm_now:
  cmd.run:
    - name: bash -c 'echo high > /sys/class/drm/card*/device/power_dpm_force_performance_level'
    - unless: grep -q "^high$" /sys/class/drm/card*/device/power_dpm_force_performance_level
    - onlyif: ls /sys/class/drm/card*/device/power_dpm_force_performance_level

# ==============================================================================
# 6. Ensure Firewalld Is Running (inference-firewall Manages Port 8080 Rules)
# ==============================================================================
halo395_firewalld_service:
  service.running:
    - name: firewalld
    - enable: True
    - require:
      - pkg: halo395_base_packages

halo395_firewall_port_8080:
  cmd.run:
    - name: firewall-cmd --permanent --remove-port=8080/tcp; firewall-cmd --remove-port=8080/tcp
    - onlyif: firewall-cmd --query-port=8080/tcp || firewall-cmd --permanent --query-port=8080/tcp
    - require:
      - service: halo395_firewalld_service

# ==============================================================================
# 7. Install Hugging Face CLI (with hf_xet) & Ensure PATH in .bashrc
# ==============================================================================
halo395_install_hf_cli:
  cmd.run:
    - name: pip3 install --user -U "huggingface_hub[cli,hf_xet]"
    - runas: {{ user }}
    - creates: {{ home }}/.local/bin/hf
    - require:
      - pkg: halo395_base_packages
      - user: halo395_user_account

halo395_user_bashrc_path:
  file.append:
    - name: {{ home }}/.bashrc
    - text: 'export PATH="$HOME/.local/bin:$PATH"'
    - unless: grep -q '\.local/bin' {{ home }}/.bashrc
    - require:
      - user: halo395_user_account

# ==============================================================================
# 8. Enable Linger, Create Vulkan RADV Toolbx & Update llama-server Binary
# ==============================================================================
halo395_enable_linger:
  cmd.run:
    - name: loginctl enable-linger {{ user }}
    - creates: /var/lib/systemd/linger/{{ user }}
    - require:
      - user: halo395_user_account

halo395_create_vulkan_toolbox:
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
      - cmd: halo395_enable_linger
      - file: halo395_local_share_dir
      - file: halo395_memlock_limits
      - cmd: halo395_podman_migrate

halo395_build_upstream_llama_server:
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
          touch /etc/llama-server-master-ornith15
        '
    - runas: {{ user }}
    - unless: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        podman start llama-vulkan-radv >/dev/null 2>&1
        podman exec llama-vulkan-radv test -f /etc/llama-server-master-ornith15 && \
        podman exec llama-vulkan-radv test -x /usr/local/bin/llama-server
    - timeout: 1800
    - require:
      - cmd: halo395_create_vulkan_toolbox

# ==============================================================================
# 9. Download Ornith-1.5-35B-A3B (Q3_K_XL + MTP), DFlash Drafter, & Vision mmproj
# ==============================================================================
halo395_download_ornith_main:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download bartowski/Ornith-1.5-35B-A3B-GGUF
        Ornith-1.5-35B-A3B-Q3_K_XL.gguf
        --local-dir {{ ornith_dir }}
    - runas: {{ user }}
    - creates: {{ ornith_dir }}/Ornith-1.5-35B-A3B-Q3_K_XL.gguf
    - timeout: 3600
    - require:
      - cmd: halo395_install_hf_cli

halo395_download_ornith_dflash:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download na0x2c6/Ornith-1.5-35B-A3B-DFlash-GGUF
        Ornith-1.5-35B-A3B-DFlash-Q8_0.gguf
        --local-dir {{ ornith_dir }}
    - runas: {{ user }}
    - creates: {{ ornith_dir }}/Ornith-1.5-35B-A3B-DFlash-Q8_0.gguf
    - timeout: 1800
    - require:
      - cmd: halo395_install_hf_cli

halo395_download_ornith_mmproj:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download bartowski/Ornith-1.5-35B-A3B-GGUF
        mmproj-Ornith-1.5-35B-A3B-bf16.gguf
        --local-dir {{ ornith_dir }}
    - runas: {{ user }}
    - creates: {{ ornith_dir }}/mmproj-Ornith-1.5-35B-A3B-bf16.gguf
    - timeout: 1800
    - require:
      - cmd: halo395_install_hf_cli

# ==============================================================================
# 10. Manage ~/models/models.ini (Single Resident 256K + DFlash + Vision Preset)
# ==============================================================================
halo395_models_preset_ini:
  file.managed:
    - name: {{ home }}/models/models.ini
    - user: {{ user }}
    - group: {{ user }}
    - mode: '0644'
    - makedirs: True
    - contents: |
        [Ornith-1.5-35B-A3B-DFlash]
        model = {{ ornith_dir }}/Ornith-1.5-35B-A3B-Q3_K_XL.gguf
        model-draft = {{ ornith_dir }}/Ornith-1.5-35B-A3B-DFlash-Q8_0.gguf
        mmproj = {{ ornith_dir }}/mmproj-Ornith-1.5-35B-A3B-bf16.gguf
        fit = off
        n-gpu-layers = 999
        n-gpu-layers-draft = 999
        flash-attn = 1
        jinja = true
        no-reasoning-preserve = true
        parallel = 1
        spec-type = draft-dflash
        spec-draft-n-max = 16
        spec-draft-p-min = 0.75
        cache-type-k = q8_0
        cache-type-v = q8_0
        ctx-size = 262144
        ubatch-size = 2048
        batch-size = 4096
        threads = 16
        temp = 0.6
        top-p = 0.95
        top-k = 20
    - require:
      - cmd: halo395_download_ornith_main
      - cmd: halo395_download_ornith_dflash
      - cmd: halo395_download_ornith_mmproj

# ==============================================================================
# 11. Systemd User Service: strix-llama-router.service (Single Resident Model)
# ==============================================================================
halo395_systemd_user_dir:
  file.directory:
    - name: {{ home }}/.config/systemd/user
    - user: {{ user }}
    - group: {{ user }}
    - makedirs: True
    - dir_mode: '0755'
    - require:
      - user: halo395_user_account

halo395_router_systemd_unit:
  file.managed:
    - name: {{ home }}/.config/systemd/user/strix-llama-router.service
    - user: {{ user }}
    - group: {{ user }}
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Strix Halo 128GB Vulkan RADV llama-server Router (Ornith-1.5-35B-A3B-DFlash 256K)
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
          --models-max 1 \
          --models-autoload \
          --jinja \
          --host 0.0.0.0 \
          --port 8080 \
          --api-key-file {{ home }}/.config/llama/backend-key

        ExecStop=/usr/bin/podman stop -t 10 llama-vulkan-radv
        Restart=on-failure
        RestartSec=10
        LimitMEMLOCK=infinity
        TimeoutStartSec=300

        [Install]
        WantedBy=default.target
    - require:
      - file: halo395_systemd_user_dir
      - file: halo395_models_preset_ini
      - cmd: inference-backend-header

halo395_enable_and_start_router_service:
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
      - cmd: halo395_enable_linger
      - cmd: halo395_create_vulkan_toolbox
      - cmd: halo395_build_upstream_llama_server
      - file: halo395_models_preset_ini
      - file: halo395_router_systemd_unit

halo395_restart_router_on_config_change:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        systemctl --user daemon-reload
        systemctl --user restart strix-llama-router.service
    - runas: {{ user }}
    - onchanges:
      - cmd: halo395_build_upstream_llama_server
      - file: halo395_models_preset_ini
      - file: halo395_router_systemd_unit
    - require:
      - cmd: halo395_enable_and_start_router_service