{% set user = 'mlops' %}
{% set home = '/home/' ~ user %}
include:
  - mlops.backend
  - mlops.huggingface
{% set gemma4_dir = home ~ '/models/Gemma-4-31B-it-qat-GGUF' %}
{% set qwen36_dir = home ~ '/models/Qwen3.6-35B-A3B-MTP-GGUF' %}

# ==============================================================================
# 1. Base Packages & System Dependencies (Uses wget2-wget for Fedora 44 RPM match)
# ==============================================================================
r9700_base_packages:
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
r9700_user_account:
  user.present:
    - name: {{ user }}
    - home: {{ home }}
    - groups:
      - video
      - render
      - wheel
    - remove_groups: False
    - require:
      - pkg: r9700_base_packages

r9700_subuid_mapping:
  file.append:
    - name: /etc/subuid
    - text: "{{ user }}:100000:65536"
    - unless: grep -q "^{{ user }}:" /etc/subuid
    - require:
      - user: r9700_user_account

r9700_subgid_mapping:
  file.append:
    - name: /etc/subgid
    - text: "{{ user }}:100000:65536"
    - unless: grep -q "^{{ user }}:" /etc/subgid
    - require:
      - user: r9700_user_account

# ==============================================================================
# 3. Fix Home Directory Traverse Permissions (Prevents crun: readlink "" Bug)
# ==============================================================================
r9700_home_dir_permissions:
  file.directory:
    - name: {{ home }}
    - user: {{ user }}
    - group: {{ user }}
    - dir_mode: '0755'
    - require:
      - user: r9700_user_account

r9700_local_share_dir:
  file.directory:
    - name: {{ home }}/.local/share
    - user: {{ user }}
    - group: {{ user }}
    - makedirs: True
    - dir_mode: '0755'
    - require:
      - file: r9700_home_dir_permissions

r9700_podman_migrate:
  cmd.run:
    - name: podman system migrate
    - runas: {{ user }}
    - onchanges:
      - file: r9700_subuid_mapping
      - file: r9700_subgid_mapping
      - file: r9700_home_dir_permissions

# ==============================================================================
# 4. PAM Locked Memory Limits (Required for 32GB GDDR6 Vulkan Allocations)
# ==============================================================================
r9700_memlock_limits:
  file.managed:
    - name: /etc/security/limits.d/99-amdgpu-memlock.conf
    - mode: '0644'
    - contents: |
        * soft memlock unlimited
        * hard memlock unlimited

# ==============================================================================
# 5. Disable Sleep Targets & Lock R9700 (Navi 48) Performance Clocks
# ==============================================================================
{% for target in ['sleep', 'suspend', 'hibernate', 'hybrid-sleep', 'suspend-then-hibernate'] %}
mask_r9700_{{ target }}_target:
  service.masked:
    - name: {{ target }}.target
{% endfor %}

r9700_tuned_service:
  service.running:
    - name: tuned
    - enable: True
    - require:
      - pkg: r9700_base_packages

r9700_tuned_profile:
  cmd.run:
    - name: tuned-adm profile throughput-performance
    - unless: tuned-adm active | grep -q "throughput-performance"
    - require:
      - service: r9700_tuned_service

r9700_amdgpu_high_dpm_udev:
  file.managed:
    - name: /etc/udev/rules.d/30-amdgpu-high-dpm.rules
    - mode: '0644'
    - contents: |
        KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ATTR{device/power_dpm_force_performance_level}="high"

r9700_apply_amdgpu_dpm_now:
  cmd.run:
    - name: bash -c 'echo high > /sys/class/drm/card*/device/power_dpm_force_performance_level'
    - unless: grep -q "^high$" /sys/class/drm/card*/device/power_dpm_force_performance_level
    - onlyif: ls /sys/class/drm/card*/device/power_dpm_force_performance_level

# ==============================================================================
# 6. Remove the legacy blanket inference port; mlops.backend owns access.
# ==============================================================================
r9700_firewalld_service:
  service.running:
    - name: firewalld
    - enable: True
    - require:
      - pkg: r9700_base_packages

r9700_firewall_port_8080:
  cmd.run:
    - name: firewall-cmd --permanent --remove-port=8080/tcp; firewall-cmd --remove-port=8080/tcp
    - onlyif: firewall-cmd --query-port=8080/tcp || firewall-cmd --permanent --query-port=8080/tcp
    - require:
      - service: r9700_firewalld_service

# ==============================================================================
# 7. Install Hugging Face CLI (with hf_xet) & Ensure PATH in .bashrc
# ==============================================================================
r9700_install_hf_cli:
  cmd.run:
    - name: pip3 install --user -U "huggingface_hub[cli,hf_xet]"
    - runas: {{ user }}
    - creates: {{ home }}/.local/bin/hf
    - require:
      - pkg: r9700_base_packages
      - user: r9700_user_account

r9700_user_bashrc_path:
  file.append:
    - name: {{ home }}/.bashrc
    - text: 'export PATH="$HOME/.local/bin:$PATH"'
    - unless: grep -q '\.local/bin' {{ home }}/.bashrc
    - require:
      - user: r9700_user_account

# ==============================================================================
# 8. Download Gemma-4-31B-QAT (+ mmproj + DFlash) & Qwen3.6-35B-A3B (+ DFlash)
# ==============================================================================
r9700_download_gemma4_31b_qat:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download unsloth/gemma-4-31B-it-qat-GGUF
        --include "*UD-Q4_K_XL*"
        --local-dir {{ gemma4_dir }}
    - runas: {{ user }}
    - creates: {{ gemma4_dir }}/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf
    - timeout: 3600
    - require:
      - cmd: r9700_install_hf_cli

r9700_download_gemma4_31b_mmproj:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download unsloth/gemma-4-31B-it-qat-GGUF
        mmproj-BF16.gguf
        --local-dir {{ gemma4_dir }}
    - runas: {{ user }}
    - creates: {{ gemma4_dir }}/mmproj-BF16.gguf
    - timeout: 1800
    - require:
      - cmd: r9700_install_hf_cli

r9700_download_gemma4_31b_dflash_drafter:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download williamliao/gemma-4-31B-it-DFlash-GGUF
        gemma-4-31B-it-DFlash-Q4_K_M.gguf
        --local-dir {{ gemma4_dir }}
    - runas: {{ user }}
    - creates: {{ gemma4_dir }}/gemma-4-31B-it-DFlash-Q4_K_M.gguf
    - timeout: 1800
    - require:
      - cmd: r9700_install_hf_cli

r9700_download_qwen36_35b_a3b:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download unsloth/Qwen3.6-35B-A3B-MTP-GGUF
        --include "*UD-Q4_K_XL*"
        --local-dir {{ qwen36_dir }}
    - runas: {{ user }}
    - creates: {{ qwen36_dir }}/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
    - timeout: 3600
    - require:
      - cmd: r9700_install_hf_cli

# Automatically replace the older abhinand DFlash GGUF if it lacks 'dflash.target_layers' metadata
r9700_download_qwen36_35b_dflash_drafter:
  cmd.run:
    - name: >
        rm -f {{ qwen36_dir }}/Qwen3.6-35B-A3B-DFlash-Q4_K_M.gguf &&
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download williamliao/Qwen3.6-35B-A3B-DFlash-GGUF
        Qwen3.6-35B-A3B-DFlash-Q4_K_M.gguf
        --local-dir {{ qwen36_dir }} &&
        touch {{ qwen36_dir }}/.williamliao_dflash_verified
    - runas: {{ user }}
    - creates: {{ qwen36_dir }}/.williamliao_dflash_verified
    - timeout: 1800
    - require:
      - cmd: r9700_install_hf_cli

r9700_download_sharp_template:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download peculiar-ragdoll/Qwen-Sharp-Chat-Templates
        chat_template.jinja
        --local-dir {{ qwen36_dir }}
    - runas: {{ user }}
    - creates: {{ qwen36_dir }}/chat_template.jinja
    - require:
      - cmd: r9700_install_hf_cli

# ==============================================================================
# 9. Enable Linger, Create RDNA 4 Vulkan RADV Toolbx & Compile for Host CPU
# ==============================================================================
r9700_enable_linger:
  cmd.run:
    - name: loginctl enable-linger {{ user }}
    - creates: /var/lib/systemd/linger/{{ user }}
    - require:
      - user: r9700_user_account

r9700_create_vulkan_toolbox:
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
      - cmd: r9700_enable_linger
      - file: r9700_local_share_dir
      - file: r9700_memlock_limits
      - cmd: r9700_podman_migrate

r9700_rebuild_llama_for_host_cpu:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        systemctl --user stop r9700-llama-router.service || true
        podman start llama-vulkan-radv
        podman exec --user 0 llama-vulkan-radv bash -e -c '
          dnf reinstall -y binutils
          dnf install -y lld mold git cmake gcc gcc-c++ ninja-build vulkan-headers vulkan-loader-devel glslc libcurl-devel
          if [ ! -e /usr/bin/ld ]; then
            ln -sf /usr/bin/ld.bfd /usr/bin/ld || ln -sf /usr/bin/ld.lld /usr/bin/ld
          fi
          rm -rf /tmp/llama.cpp
          git clone --depth 1 https://github.com/ggml-org/llama.cpp.git /tmp/llama.cpp
          cmake -B /tmp/llama.cpp/build -S /tmp/llama.cpp -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DGGML_VULKAN=ON \
            -DGGML_NATIVE=ON
          cmake --build /tmp/llama.cpp/build --config Release -j $(nproc) --target llama-server llama-cli
          cp -af /tmp/llama.cpp/build/bin/llama-* /usr/local/bin/
          cp -af /tmp/llama.cpp/build/bin/llama-* /usr/bin/ 2>/dev/null || true
          cp -af /tmp/llama.cpp/build/bin/*.so* /usr/local/lib64/ 2>/dev/null || true
          cp -af /tmp/llama.cpp/build/bin/*.so* /usr/lib64/ 2>/dev/null || true
          ldconfig
          touch /etc/llama-built-native-host-cpu
          rm -rf /tmp/llama.cpp
        '
    - runas: {{ user }}
    - unless: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        podman start llama-vulkan-radv >/dev/null 2>&1
        podman exec llama-vulkan-radv test -f /etc/llama-built-native-host-cpu
    - timeout: 1200
    - require:
      - cmd: r9700_create_vulkan_toolbox

# ==============================================================================
# 10. Manage ~/models/models.ini for llama-server Router Mode (256K + DFlash)
# ==============================================================================
r9700_models_preset_ini:
  file.managed:
    - name: {{ home }}/models/models.ini
    - user: {{ user }}
    - group: {{ user }}
    - mode: '0644'
    - makedirs: True
    - contents: |
        [Gemma-4-31B-QAT-Vision]
        model = {{ gemma4_dir }}/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf
        model-draft = {{ gemma4_dir }}/gemma-4-31B-it-DFlash-Q4_K_M.gguf
        mmproj = {{ gemma4_dir }}/mmproj-BF16.gguf
        fit = off
        n-gpu-layers = 999
        n-gpu-layers-draft = 999
        load-mode = none
        flash-attn = 1
        jinja = true
        reasoning = on
        no-reasoning-preserve = true
        parallel = 1
        spec-type = draft-dflash
        spec-draft-n-max = 4
        spec-draft-p-min = 0.75
        cache-type-k = q8_0
        cache-type-v = q8_0
        ctx-size = 262144
        ubatch-size = 1024
        batch-size = 4096
        threads = 8
        temp = 1.0
        top-p = 0.95
        top-k = 64

        [Gemma-4-31B-QAT-NoThink]
        model = {{ gemma4_dir }}/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf
        model-draft = {{ gemma4_dir }}/gemma-4-31B-it-DFlash-Q4_K_M.gguf
        mmproj = {{ gemma4_dir }}/mmproj-BF16.gguf
        fit = off
        n-gpu-layers = 999
        n-gpu-layers-draft = 999
        load-mode = none
        flash-attn = 1
        jinja = true
        reasoning = off
        no-reasoning-preserve = true
        parallel = 1
        spec-type = draft-dflash
        spec-draft-n-max = 4
        spec-draft-p-min = 0.75
        cache-type-k = q8_0
        cache-type-v = q8_0
        ctx-size = 262144
        ubatch-size = 1024
        batch-size = 4096
        threads = 8
        temp = 0.7
        top-p = 0.90
        top-k = 64

        [Qwen3.6-35B-A3B-DFlash-Low]
        model = {{ qwen36_dir }}/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
        model-draft = {{ qwen36_dir }}/Qwen3.6-35B-A3B-DFlash-Q4_K_M.gguf
        fit = off
        n-gpu-layers = 999
        n-gpu-layers-draft = 999
        load-mode = none
        flash-attn = 1
        jinja = true
        chat-template-file = {{ qwen36_dir }}/chat_template.jinja
        chat-template-kwargs = {"reasoning_effort":"low"}
        no-reasoning-preserve = true
        parallel = 1
        spec-type = draft-dflash
        spec-draft-n-max = 7
        spec-draft-p-min = 0.75
        cache-type-k = q8_0
        cache-type-v = q8_0
        ctx-size = 262144
        ubatch-size = 1024
        batch-size = 4096
        threads = 8
        temp = 0.6
        top-p = 0.95
        top-k = 20

        [Qwen3.6-35B-A3B-DFlash-NoThink]
        model = {{ qwen36_dir }}/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
        model-draft = {{ qwen36_dir }}/Qwen3.6-35B-A3B-DFlash-Q4_K_M.gguf
        fit = off
        n-gpu-layers = 999
        n-gpu-layers-draft = 999
        load-mode = none
        flash-attn = 1
        jinja = true
        chat-template-file = {{ qwen36_dir }}/chat_template.jinja
        reasoning = off
        no-reasoning-preserve = true
        parallel = 1
        spec-type = draft-dflash
        spec-draft-n-max = 7
        spec-draft-p-min = 0.75
        cache-type-k = q8_0
        cache-type-v = q8_0
        ctx-size = 262144
        ubatch-size = 1024
        batch-size = 4096
        threads = 8
        temp = 0.6
        top-p = 0.80
        top-k = 20
    - require:
      - cmd: r9700_download_gemma4_31b_qat
      - cmd: r9700_download_gemma4_31b_mmproj
      - cmd: r9700_download_gemma4_31b_dflash_drafter
      - cmd: r9700_download_qwen36_35b_a3b
      - cmd: r9700_download_qwen36_35b_dflash_drafter
      - cmd: r9700_download_sharp_template

# ==============================================================================
# 11. Systemd User Service: r9700-llama-router.service (Split Start & Restart)
# ==============================================================================
r9700_systemd_user_dir:
  file.directory:
    - name: {{ home }}/.config/systemd/user
    - user: {{ user }}
    - group: {{ user }}
    - makedirs: True
    - dir_mode: '0755'
    - require:
      - user: r9700_user_account

r9700_router_systemd_unit:
  file.managed:
    - name: {{ home }}/.config/systemd/user/r9700-llama-router.service
    - user: {{ user }}
    - group: {{ user }}
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Radeon AI PRO R9700 32GB llama-server Router (Gemma-4-31B-QAT & Qwen3.6-35B-A3B-DFlash)
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        Environment="HOME={{ home }}"
        Environment="PATH={{ home }}/.local/bin:/usr/local/bin:/usr/bin:/bin"
        WorkingDirectory={{ home }}

        ExecStartPre=/usr/bin/podman start llama-vulkan-radv

        ExecStart=/usr/bin/toolbox run --container llama-vulkan-radv \
          llama-server \
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
      - file: r9700_systemd_user_dir
      - cmd: inference-backend-header
      - cmd: inference-firewall-apply

r9700_enable_and_start_router_service:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        systemctl --user daemon-reload
        systemctl --user enable --now r9700-llama-router.service
    - runas: {{ user }}
    - unless: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        systemctl --user is-active --quiet r9700-llama-router.service
    - require:
      - cmd: r9700_enable_linger
      - cmd: r9700_create_vulkan_toolbox
      - cmd: r9700_rebuild_llama_for_host_cpu
      - file: r9700_models_preset_ini
      - file: r9700_router_systemd_unit

r9700_restart_router_on_config_change:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        systemctl --user daemon-reload
        systemctl --user restart r9700-llama-router.service
    - runas: {{ user }}
    - onchanges:
      - cmd: r9700_rebuild_llama_for_host_cpu
      - file: r9700_router_systemd_unit
      - file: r9700_models_preset_ini
    - require:
      - cmd: r9700_enable_and_start_router_service
