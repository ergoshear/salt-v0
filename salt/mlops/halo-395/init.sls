{% set user = 'mlops' %}
{% set home = '/home/' ~ user %}
{% set coder_dir = home ~ '/models/Qwen3-Coder-30B-A3B-GGUF' %}
{% set flash_dir = home ~ '/models/Qwen3.8-Flash-Next-GGUF' %}
{% set kargs = 'amd_iommu=off amdgpu.gttsize=118784 ttm.pages_limit=30408704 ttm.page_pool_size=30408704 amdgpu.cwsr_enable=0 numa_balancing=disable' %}

# ==============================================================================
# 1. Base Packages & System Dependencies (Uses wget2-wget for Fedora 44 RPM match)
# ==============================================================================
strix_x2_base_packages:
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
      - grubby

# ==============================================================================
# 2. User Account, Groups, and Rootless Podman SubUID/SubGID Mappings
# ==============================================================================
strix_x2_user_account:
  user.present:
    - name: {{ user }}
    - home: {{ home }}
    - groups:
      - video
      - render
      - wheel
    - remove_groups: False
    - require:
      - pkg: strix_x2_base_packages

strix_x2_subuid_mapping:
  file.append:
    - name: /etc/subuid
    - text: "{{ user }}:100000:65536"
    - unless: grep -q "^{{ user }}:" /etc/subuid
    - require:
      - user: strix_x2_user_account

strix_x2_subgid_mapping:
  file.append:
    - name: /etc/subgid
    - text: "{{ user }}:100000:65536"
    - unless: grep -q "^{{ user }}:" /etc/subgid
    - require:
      - user: strix_x2_user_account

# ==============================================================================
# 3. Fix Home Directory Traverse Permissions (Prevents crun: readlink "" Bug)
# ==============================================================================
strix_x2_home_dir_permissions:
  file.directory:
    - name: {{ home }}
    - user: {{ user }}
    - group: {{ user }}
    - dir_mode: '0755'
    - require:
      - user: strix_x2_user_account

strix_x2_local_share_dir:
  file.directory:
    - name: {{ home }}/.local/share
    - user: {{ user }}
    - group: {{ user }}
    - makedirs: True
    - dir_mode: '0755'
    - require:
      - file: strix_x2_home_dir_permissions

strix_x2_podman_migrate:
  cmd.run:
    - name: podman system migrate
    - runas: {{ user }}
    - onchanges:
      - file: strix_x2_subuid_mapping
      - file: strix_x2_subgid_mapping
      - file: strix_x2_home_dir_permissions

# ==============================================================================
# 4. PAM Locked Memory Limits & Kernel 116 GB GTT/TTM Pool (For 128 GB EVO-X2)
# ==============================================================================
strix_x2_memlock_limits:
  file.managed:
    - name: /etc/security/limits.d/99-rocm-memlock.conf
    - mode: '0644'
    - contents: |
        * soft memlock unlimited
        * hard memlock unlimited

strix_x2_kernel_gtt_args:
  cmd.run:
    - name: grubby --update-kernel=ALL --args="{{ kargs }}"
    - unless: grubby --info=DEFAULT | grep -q "amdgpu.gttsize=118784"
    - require:
      - pkg: strix_x2_base_packages

# ==============================================================================
# 5. Disable Sleep Targets & Lock CPU/GPU Performance Clocks
# ==============================================================================
{% for target in ['sleep', 'suspend', 'hibernate', 'hybrid-sleep', 'suspend-then-hibernate'] %}
mask_x2_{{ target }}_target:
  service.masked:
    - name: {{ target }}.target
{% endfor %}

strix_x2_tuned_service:
  service.running:
    - name: tuned
    - enable: True
    - require:
      - pkg: strix_x2_base_packages

strix_x2_tuned_profile:
  cmd.run:
    - name: tuned-adm profile throughput-performance
    - unless: tuned-adm active | grep -q "throughput-performance"
    - require:
      - service: strix_x2_tuned_service

strix_x2_amdgpu_high_dpm_udev:
  file.managed:
    - name: /etc/udev/rules.d/30-amdgpu-high-dpm.rules
    - mode: '0644'
    - contents: |
        KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ATTR{device/power_dpm_force_performance_level}="high"

strix_x2_apply_amdgpu_dpm_now:
  cmd.run:
    - name: bash -c 'echo high > /sys/class/drm/card*/device/power_dpm_force_performance_level'
    - unless: grep -q "^high$" /sys/class/drm/card*/device/power_dpm_force_performance_level
    - onlyif: ls /sys/class/drm/card*/device/power_dpm_force_performance_level

# ==============================================================================
# 6. Open Port 8080/tcp in Firewalld for LAN & VS Code Copilot Access
# ==============================================================================
strix_x2_firewalld_service:
  service.running:
    - name: firewalld
    - enable: True
    - require:
      - pkg: strix_x2_base_packages

strix_x2_firewall_port_8080:
  cmd.run:
    - name: firewall-cmd --permanent --add-port=8080/tcp && firewall-cmd --reload
    - unless: firewall-cmd --list-ports | grep -q "8080/tcp"
    - require:
      - service: strix_x2_firewalld_service

# ==============================================================================
# 7. Install Hugging Face CLI (with hf_xet) & Ensure PATH in .bashrc
# ==============================================================================
strix_x2_install_hf_cli:
  cmd.run:
    - name: pip3 install --user -U "huggingface_hub[cli,hf_xet]"
    - runas: {{ user }}
    - creates: {{ home }}/.local/bin/hf
    - require:
      - pkg: strix_x2_base_packages
      - user: strix_x2_user_account

strix_x2_user_bashrc_path:
  file.append:
    - name: {{ home }}/.bashrc
    - text: 'export PATH="$HOME/.local/bin:$PATH"'
    - unless: grep -q '\.local/bin' {{ home }}/.bashrc
    - require:
      - user: strix_x2_user_account

# ==============================================================================
# 8. Download Qwen3-Coder-30B-A3B & Qwen3.8-Flash-Next + MTP + Sharp Template
# ==============================================================================
strix_x2_download_qwen3_coder_30b:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF
        --include "*UD-Q4_K_XL*"
        --local-dir {{ coder_dir }}
    - runas: {{ user }}
    - creates: {{ coder_dir }}/Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf
    - timeout: 3600
    - require:
      - cmd: strix_x2_install_hf_cli

strix_x2_download_flash_next:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download unsloth/Qwen3.8-Flash-Next-GGUF
        --include "*UD-IQ4_XS*"
        --local-dir {{ flash_dir }}
    - runas: {{ user }}
    - creates: {{ flash_dir }}/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00003-of-00003.gguf
    - timeout: 7200
    - require:
      - cmd: strix_x2_install_hf_cli

strix_x2_download_flash_mtp:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download EasiiX/Qwen3.8-Flash-Next-MTP-Strix-Halo-GGUF
        mtp-Qwen3.8-Flash-Next-hc-Q8_0.gguf
        --local-dir {{ flash_dir }}
    - runas: {{ user }}
    - creates: {{ flash_dir }}/mtp-Qwen3.8-Flash-Next-hc-Q8_0.gguf
    - timeout: 1800
    - require:
      - cmd: strix_x2_install_hf_cli

strix_x2_download_sharp_template:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download peculiar-ragdoll/Qwen-Sharp-Chat-Templates
        chat_template.jinja
        --local-dir {{ flash_dir }}
    - runas: {{ user }}
    - creates: {{ flash_dir }}/chat_template.jinja
    - require:
      - cmd: strix_x2_install_hf_cli

# ==============================================================================
# 9. Enable Linger & Create the Strix Halo Vulkan RADV Toolbx Container
# ==============================================================================
strix_x2_enable_linger:
  cmd.run:
    - name: loginctl enable-linger {{ user }}
    - creates: /var/lib/systemd/linger/{{ user }}
    - require:
      - user: strix_x2_user_account

strix_x2_create_vulkan_toolbox:
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
      - cmd: strix_x2_enable_linger
      - file: strix_x2_local_share_dir
      - file: strix_x2_memlock_limits
      - cmd: strix_x2_podman_migrate

# ==============================================================================
# 10. Manage ~/models/models.ini for llama-server Router Mode (With fit = off)
# ==============================================================================
strix_x2_models_preset_ini:
  file.managed:
    - name: {{ home }}/models/models.ini
    - user: {{ user }}
    - group: {{ user }}
    - mode: '0644'
    - makedirs: True
    - contents: |
        [Qwen3-Coder-30B-A3B]
        model = {{ coder_dir }}/Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf
        fit = off
        n-gpu-layers = 999
        load-mode = none
        flash-attn = 1
        jinja = true
        parallel = 1
        cache-type-k = q8_0
        cache-type-v = q8_0
        ctx-size = 131072
        ubatch-size = 1024
        batch-size = 4096
        threads = 16
        temp = 0.7
        top-p = 0.80
        top-k = 20
        repeat-penalty = 1.05

        [Qwen3.8-Flash-Next-Low]
        model = {{ flash_dir }}/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf
        model-draft = {{ flash_dir }}/mtp-Qwen3.8-Flash-Next-hc-Q8_0.gguf
        fit = off
        n-gpu-layers = 999
        n-gpu-layers-draft = 999
        load-mode = none
        flash-attn = 1
        jinja = true
        chat-template-file = {{ flash_dir }}/chat_template.jinja
        chat-template-kwargs = {"reasoning_effort":"low"}
        no-reasoning-preserve = true
        parallel = 1
        spec-type = draft-mtp
        spec-draft-n-max = 4
        spec-draft-p-min = 0.75
        cache-type-k = q8_0
        cache-type-v = q8_0
        ctx-size = 131072
        ubatch-size = 1024
        batch-size = 4096
        threads = 16
        temp = 1.0
        top-p = 0.95
        top-k = 20

        [Qwen3.8-Flash-Next-Medium]
        model = {{ flash_dir }}/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf
        model-draft = {{ flash_dir }}/mtp-Qwen3.8-Flash-Next-hc-Q8_0.gguf
        fit = off
        n-gpu-layers = 999
        n-gpu-layers-draft = 999
        load-mode = none
        flash-attn = 1
        jinja = true
        chat-template-file = {{ flash_dir }}/chat_template.jinja
        chat-template-kwargs = {"reasoning_effort":"medium"}
        no-reasoning-preserve = true
        parallel = 1
        spec-type = draft-mtp
        spec-draft-n-max = 4
        spec-draft-p-min = 0.75
        cache-type-k = q8_0
        cache-type-v = q8_0
        ctx-size = 131072
        ubatch-size = 1024
        batch-size = 4096
        threads = 16
        temp = 1.0
        top-p = 0.95
        top-k = 20

        [Qwen3.8-Flash-Next-NoThink]
        model = {{ flash_dir }}/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf
        model-draft = {{ flash_dir }}/mtp-Qwen3.8-Flash-Next-hc-Q8_0.gguf
        fit = off
        n-gpu-layers = 999
        n-gpu-layers-draft = 999
        load-mode = none
        flash-attn = 1
        jinja = true
        chat-template-file = {{ flash_dir }}/chat_template.jinja
        chat-template-kwargs = {"enable_thinking":false}
        no-reasoning-preserve = true
        parallel = 1
        spec-type = draft-mtp
        spec-draft-n-max = 4
        spec-draft-p-min = 0.75
        cache-type-k = q8_0
        cache-type-v = q8_0
        ctx-size = 131072
        ubatch-size = 1024
        batch-size = 4096
        threads = 16
        temp = 0.7
        top-p = 0.80
        top-k = 20
    - require:
      - cmd: strix_x2_download_qwen3_coder_30b
      - cmd: strix_x2_download_flash_next
      - cmd: strix_x2_download_flash_mtp
      - cmd: strix_x2_download_sharp_template

# ==============================================================================
# 11. Systemd User Directory & strix-llama-router.service
# ==============================================================================
strix_x2_systemd_user_dir:
  file.directory:
    - name: {{ home }}/.config/systemd/user
    - user: {{ user }}
    - group: {{ user }}
    - makedirs: True
    - dir_mode: '0755'
    - require:
      - user: strix_x2_user_account

strix_x2_router_systemd_unit:
  file.managed:
    - name: {{ home }}/.config/systemd/user/strix-llama-router.service
    - user: {{ user }}
    - group: {{ user }}
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Strix Halo EVO-X2 Multi-Model llama-server Router (Qwen3-Coder-30B & Qwen3.8-Flash-Next)
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
          --host 0.0.0.0 \
          --port 8080

        ExecStop=/usr/bin/podman stop -t 10 llama-vulkan-radv
        Restart=on-failure
        RestartSec=10
        LimitMEMLOCK=infinity
        TimeoutStartSec=300

        [Install]
        WantedBy=default.target
    - require:
      - file: strix_x2_systemd_user_dir

strix_x2_enable_and_start_router_service:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        systemctl --user daemon-reload
        systemctl --user enable strix-llama-router.service
        systemctl --user restart strix-llama-router.service
    - runas: {{ user }}
    - unless: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        systemctl --user is-active --quiet strix-llama-router.service
    - onchanges:
      - file: strix_x2_router_systemd_unit
      - file: strix_x2_models_preset_ini
    - require:
      - cmd: strix_x2_enable_linger
      - cmd: strix_x2_create_vulkan_toolbox
      - file: strix_x2_models_preset_ini
      - file: strix_x2_router_systemd_unit