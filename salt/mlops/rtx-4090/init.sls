{% set user = 'mlops' %}
{% set home = '/home/' ~ user %}
{% set python_version = grains['pythonversion'][:2] | join('.') %}
include:
  - mlops.backend
  - mlops.huggingface
{% set glimmer_dir = home ~ '/models/Muse-Glimmer-30B-GGUF' %}

# ==============================================================================
# 1. Base Packages & Kernel Build Dependencies (Required for akmod-nvidia)
# ==============================================================================
rtx4090_base_packages:
  pkg.installed:
    - names:
      - podman
      - python3-pip
      - git
      - wget2-wget
      - jq
      - tuned
      - firewalld
      - grubby
      - pciutils
      - kernel-devel
      - kernel-headers
      - fedora-workstation-repositories

# Glances requires the pynvml module for NVIDIA GPU telemetry. Install the
# maintained nvidia-ml-py distribution in an isolated target directory, then
# expose that directory to the system Python used by /usr/bin/glances.
rtx4090_glances_nvidia_ml_python:
  pip.installed:
    - name: nvidia-ml-py
    - bin_env: /usr/bin/python3
    - target: /opt/glances-nvidia-ml
    - require:
      - pkg: rtx4090_base_packages

rtx4090_glances_nvidia_ml_path:
  file.managed:
    - name: /usr/lib/python{{ python_version }}/site-packages/glances-nvidia-ml.pth
    - user: root
    - group: root
    - mode: '0644'
    - contents: /opt/glances-nvidia-ml
    - require:
      - pip: rtx4090_glances_nvidia_ml_python

# ==============================================================================
# 2. Enable RPM Fusion (Via download1.rpmfusion.org to Bypass Dead Mirror Redirect)
# ==============================================================================
rtx4090_rpmfusion_repos:
  cmd.run:
    - name: |
        dnf config-manager setopt rpmfusion-nonfree-nvidia-driver.enabled=1 || true
        dnf install -y \
          "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
          "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
        sed -i 's|^metalink=|#metalink=|g; s|^#baseurl=http://download1.rpmfusion.org|baseurl=https://download1.rpmfusion.org|g' /etc/yum.repos.d/rpmfusion-*.repo
        dnf config-manager setopt rpmfusion-free.enabled=1 rpmfusion-free-updates.enabled=1 rpmfusion-nonfree.enabled=1 rpmfusion-nonfree-updates.enabled=1
    - unless: dnf repolist --enabled | grep -qE "^rpmfusion-nonfree"
    - require:
      - pkg: rtx4090_base_packages

rtx4090_nvidia_container_toolkit_repo:
  cmd.run:
    - name: |
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
          tee /etc/yum.repos.d/nvidia-container-toolkit.repo
    - creates: /etc/yum.repos.d/nvidia-container-toolkit.repo
    - require:
      - pkg: rtx4090_base_packages

# ==============================================================================
# 3. Install NVIDIA Proprietary Driver, CUDA Runtime & Container Toolkit
# ==============================================================================
rtx4090_nvidia_packages:
  pkg.installed:
    - names:
      - akmod-nvidia
      - xorg-x11-drv-nvidia-cuda
      - xorg-x11-drv-nvidia-power
      - nvidia-container-toolkit
    - require:
      - cmd: rtx4090_rpmfusion_repos
      - cmd: rtx4090_nvidia_container_toolkit_repo

# Blacklist both nouveau and Fedora 44's nova_core in GRUB & Enable DRM Modeset
rtx4090_kernel_nvidia_args:
  cmd.run:
    - name: >
        grubby --update-kernel=ALL
        --args="rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core nvidia-drm.modeset=1"
    - unless: grubby --info=DEFAULT | grep -q "rd.driver.blacklist=nouveau,nova_core"
    - require:
      - pkg: rtx4090_nvidia_packages

# Build & Load the NVIDIA Kernel Module Immediately (Since Secure Boot is Disabled)
rtx4090_build_and_load_kmod:
  cmd.run:
    - name: |
        akmods --force
        dracut --force
        rmmod nova_core nouveau 2>/dev/null || true
        modprobe nvidia
        modprobe nvidia-uvm
        modprobe nvidia-modeset
        modprobe nvidia-drm
    - unless: lsmod | grep -q "^nvidia "
    - require:
      - pkg: rtx4090_nvidia_packages

# Enable nvidia-persistenced so the RTX 4090 Stays Initialized & Fast on Idle
rtx4090_nvidia_persistenced:
  service.running:
    - name: nvidia-persistenced
    - enable: True
    - require:
      - cmd: rtx4090_build_and_load_kmod

# Generate CDI Spec (/etc/cdi/nvidia.yaml) for Rootless Podman GPU Passthrough
rtx4090_generate_nvidia_cdi:
  cmd.run:
    - name: |
        mkdir -p /etc/cdi
        nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
    - unless: test -s /etc/cdi/nvidia.yaml
    - require:
      - service: rtx4090_nvidia_persistenced

# ==============================================================================
# 4. User Account, Groups, and Rootless Podman SubUID/SubGID Mappings
# ==============================================================================
rtx4090_user_account:
  user.present:
    - name: {{ user }}
    - home: {{ home }}
    - groups:
      - video
      - render
      - wheel
    - remove_groups: False
    - require:
      - pkg: rtx4090_base_packages

rtx4090_subuid_mapping:
  file.append:
    - name: /etc/subuid
    - text: "{{ user }}:100000:65536"
    - unless: grep -q "^{{ user }}:" /etc/subuid
    - require:
      - user: rtx4090_user_account

rtx4090_subgid_mapping:
  file.append:
    - name: /etc/subgid
    - text: "{{ user }}:100000:65536"
    - unless: grep -q "^{{ user }}:" /etc/subgid
    - require:
      - user: rtx4090_user_account

rtx4090_home_dir_permissions:
  file.directory:
    - name: {{ home }}
    - user: {{ user }}
    - group: {{ user }}
    - dir_mode: '0755'
    - require:
      - user: rtx4090_user_account

rtx4090_local_share_dir:
  file.directory:
    - name: {{ home }}/.local/share
    - user: {{ user }}
    - group: {{ user }}
    - makedirs: True
    - dir_mode: '0755'
    - require:
      - file: rtx4090_home_dir_permissions

rtx4090_podman_migrate:
  cmd.run:
    - name: podman system migrate
    - runas: {{ user }}
    - onchanges:
      - file: rtx4090_subuid_mapping
      - file: rtx4090_subgid_mapping
      - file: rtx4090_home_dir_permissions

rtx4090_memlock_limits:
  file.managed:
    - name: /etc/security/limits.d/99-nvidia-memlock.conf
    - mode: '0644'
    - contents: |
        * soft memlock unlimited
        * hard memlock unlimited

# ==============================================================================
# 5. Disable Sleep Targets & Set Throughput-Performance Profile
# ==============================================================================
{% for target in ['sleep', 'suspend', 'hibernate', 'hybrid-sleep', 'suspend-then-hibernate'] %}
mask_4090_{{ target }}_target:
  service.masked:
    - name: {{ target }}.target
{% endfor %}

rtx4090_tuned_service:
  service.running:
    - name: tuned
    - enable: True
    - require:
      - pkg: rtx4090_base_packages

rtx4090_tuned_profile:
  cmd.run:
    - name: tuned-adm profile throughput-performance
    - unless: tuned-adm active | grep -q "throughput-performance"
    - require:
      - service: rtx4090_tuned_service

# ==============================================================================
# 6. Remove the legacy blanket inference port; mlops.backend owns access.
# ==============================================================================
rtx4090_firewalld_service:
  service.running:
    - name: firewalld
    - enable: True
    - require:
      - pkg: rtx4090_base_packages

rtx4090_firewall_port_8080:
  cmd.run:
    - name: firewall-cmd --permanent --remove-port=8080/tcp; firewall-cmd --remove-port=8080/tcp
    - onlyif: firewall-cmd --query-port=8080/tcp || firewall-cmd --permanent --query-port=8080/tcp
    - require:
      - service: rtx4090_firewalld_service

# ==============================================================================
# 7. Install Hugging Face CLI (with hf_xet)
# ==============================================================================
rtx4090_install_hf_cli:
  cmd.run:
    - name: pip3 install --user -U "huggingface_hub[cli,hf_xet]"
    - runas: {{ user }}
    - creates: {{ home }}/.local/bin/hf
    - require:
      - pkg: rtx4090_base_packages
      - user: rtx4090_user_account

rtx4090_user_bashrc_path:
  file.append:
    - name: {{ home }}/.bashrc
    - text: 'export PATH="$HOME/.local/bin:$PATH"'
    - unless: grep -q '\.local/bin' {{ home }}/.bashrc
    - require:
      - user: rtx4090_user_account

# ==============================================================================
# 8. Download Muse-Glimmer-30B (17GB KQuant), DFlash Drafter, & Vision Projector
# ==============================================================================
rtx4090_download_muse_glimmer_main:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download meta-models/Muse-Glimmer-30B-GGUF
        Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf
        --local-dir {{ glimmer_dir }}
    - runas: {{ user }}
    - creates: {{ glimmer_dir }}/Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf
    - timeout: 3600
    - require:
      - cmd: rtx4090_install_hf_cli

rtx4090_download_muse_glimmer_dflash:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download meta-models/Muse-Glimmer-30B-GGUF
        dflash-Muse-Glimmer-30B-Q4_K_M.gguf
        --local-dir {{ glimmer_dir }}
    - runas: {{ user }}
    - creates: {{ glimmer_dir }}/dflash-Muse-Glimmer-30B-Q4_K_M.gguf
    - timeout: 1800
    - require:
      - cmd: rtx4090_install_hf_cli

rtx4090_download_muse_glimmer_mmproj:
  cmd.run:
    - name: >
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download meta-models/Muse-Glimmer-30B-GGUF
        mmproj-Muse-Glimmer-30B-Q4_K_M.gguf
        --local-dir {{ glimmer_dir }}
    - runas: {{ user }}
    - creates: {{ glimmer_dir }}/mmproj-Muse-Glimmer-30B-Q4_K_M.gguf
    - timeout: 1800
    - require:
      - cmd: rtx4090_install_hf_cli

# ==============================================================================
# 9. Enable Lingering & Pull Official llama.cpp CUDA Server Container
# ==============================================================================
rtx4090_enable_linger:
  cmd.run:
    - name: loginctl enable-linger {{ user }}
    - creates: /var/lib/systemd/linger/{{ user }}
    - require:
      - user: rtx4090_user_account

rtx4090_pull_llama_cuda_image:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        podman pull -q ghcr.io/ggml-org/llama.cpp:server-cuda
    - runas: {{ user }}
    - unless: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        podman image exists ghcr.io/ggml-org/llama.cpp:server-cuda
    - require:
      - cmd: rtx4090_enable_linger
      - file: rtx4090_local_share_dir
      - cmd: rtx4090_podman_migrate

# ==============================================================================
# 10. Manage ~/models/models.ini for Muse-Glimmer-30B (128K, 256K, 512K & Vision)
# ==============================================================================
rtx4090_models_preset_ini:
  file.managed:
    - name: {{ home }}/models/models.ini
    - user: {{ user }}
    - group: {{ user }}
    - mode: '0644'
    - makedirs: True
    - contents: |
        [Muse-Glimmer-30B-128K]
        model = {{ glimmer_dir }}/Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf
        model-draft = {{ glimmer_dir }}/dflash-Muse-Glimmer-30B-Q4_K_M.gguf
        fit = off
        n-gpu-layers = 999
        n-gpu-layers-draft = 999
        flash-attn = 1
        jinja = true
        no-reasoning-preserve = true
        parallel = 1
        spec-type = draft-dflash
        spec-draft-n-max = 15
        spec-draft-p-min = 0.75
        cache-type-k = q8_0
        cache-type-v = q8_0
        ctx-size = 131072
        ubatch-size = 1024
        batch-size = 4096
        threads = 8
        temp = 1.0
        top-p = 0.95
        top-k = 64

        [Muse-Glimmer-30B-256K-VRAM]
        model = {{ glimmer_dir }}/Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf
        model-draft = {{ glimmer_dir }}/dflash-Muse-Glimmer-30B-Q4_K_M.gguf
        fit = off
        n-gpu-layers = 999
        n-gpu-layers-draft = 999
        flash-attn = 1
        jinja = true
        no-reasoning-preserve = true
        parallel = 1
        spec-type = draft-dflash
        spec-draft-n-max = 15
        spec-draft-p-min = 0.75
        cache-type-k = q4_0
        cache-type-v = q4_0
        ctx-size = 262144
        rope-scaling = yarn
        rope-scale = 2.0
        yarn-orig-ctx = 131072
        ubatch-size = 1024
        batch-size = 4096
        threads = 8
        temp = 1.0
        top-p = 0.95
        top-k = 64

        [Muse-Glimmer-30B-512K-Hybrid]
        model = {{ glimmer_dir }}/Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf
        fit = off
        n-gpu-layers = 40
        flash-attn = 1
        jinja = true
        no-reasoning-preserve = true
        parallel = 1
        cache-type-k = q4_0
        cache-type-v = q4_0
        ctx-size = 524288
        rope-scaling = yarn
        rope-scale = 4.0
        yarn-orig-ctx = 131072
        ubatch-size = 1024
        batch-size = 4096
        threads = 16
        temp = 1.0
        top-p = 0.95
        top-k = 64

        [Muse-Glimmer-30B-Vision]
        model = {{ glimmer_dir }}/Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf
        model-draft = {{ glimmer_dir }}/dflash-Muse-Glimmer-30B-Q4_K_M.gguf
        mmproj = {{ glimmer_dir }}/mmproj-Muse-Glimmer-30B-Q4_K_M.gguf
        fit = off
        n-gpu-layers = 999
        n-gpu-layers-draft = 999
        flash-attn = 1
        jinja = true
        no-reasoning-preserve = true
        parallel = 1
        spec-type = draft-dflash
        spec-draft-n-max = 15
        spec-draft-p-min = 0.75
        cache-type-k = q8_0
        cache-type-v = q8_0
        ctx-size = 98304
        ubatch-size = 1024
        batch-size = 4096
        threads = 8
        temp = 1.0
        top-p = 0.95
        top-k = 64
    - require:
      - cmd: rtx4090_download_muse_glimmer_main
      - cmd: rtx4090_download_muse_glimmer_dflash
      - cmd: rtx4090_download_muse_glimmer_mmproj

# ==============================================================================
# 11. Systemd User Service: rtx4090-llama-router.service (Split Start & Restart)
# ==============================================================================
rtx4090_systemd_user_dir:
  file.directory:
    - name: {{ home }}/.config/systemd/user
    - user: {{ user }}
    - group: {{ user }}
    - makedirs: True
    - dir_mode: '0755'
    - require:
      - user: rtx4090_user_account

rtx4090_router_systemd_unit:
  file.managed:
    - name: {{ home }}/.config/systemd/user/rtx4090-llama-router.service
    - user: {{ user }}
    - group: {{ user }}
    - mode: '0644'
    - contents: |
        [Unit]
        Description=RTX 4090 CUDA llama-server Router (Muse-Glimmer-30B + DFlash)
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        Environment="HOME={{ home }}"
        Environment="PATH={{ home }}/.local/bin:/usr/local/bin:/usr/bin:/bin"
        WorkingDirectory={{ home }}

        ExecStartPre=-/usr/bin/podman rm -f llama-cuda-router

        ExecStart=/usr/bin/podman run --rm --name llama-cuda-router \
          --device nvidia.com/gpu=all \
          --security-opt label=disable \
          --ipc=host \
          --network=host \
          --ulimit memlock=-1:-1 \
          -v {{ home }}:{{ home }}:rslave \
          ghcr.io/ggml-org/llama.cpp:server-cuda \
          --models-preset {{ home }}/models/models.ini \
          --models-max 1 \
          --models-autoload \
          --jinja \
          --host 0.0.0.0 \
          --port 8080 \
          --api-key-file {{ home }}/.config/llama/backend-key

        ExecStop=/usr/bin/podman stop -t 10 llama-cuda-router
        Restart=on-failure
        RestartSec=10
        LimitMEMLOCK=infinity
        TimeoutStartSec=300

        [Install]
        WantedBy=default.target
    - require:
      - file: rtx4090_systemd_user_dir
      - cmd: inference-backend-header
      - cmd: inference-firewall-apply

rtx4090_enable_and_start_router_service:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        systemctl --user daemon-reload
        systemctl --user enable --now rtx4090-llama-router.service
    - runas: {{ user }}
    - unless: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        systemctl --user is-active --quiet rtx4090-llama-router.service
    - require:
      - cmd: rtx4090_enable_linger
      - cmd: rtx4090_generate_nvidia_cdi
      - cmd: rtx4090_pull_llama_cuda_image
      - file: rtx4090_models_preset_ini
      - file: rtx4090_router_systemd_unit

rtx4090_restart_router_on_config_change:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        systemctl --user daemon-reload
        systemctl --user restart rtx4090-llama-router.service
    - runas: {{ user }}
    - onchanges:
      - file: rtx4090_router_systemd_unit
      - file: rtx4090_models_preset_ini
    - require:
      - cmd: rtx4090_enable_and_start_router_service
