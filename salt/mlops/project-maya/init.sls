{# Detect gfx1151 + RAM tier via synced custom grain OR core grains['mem_total'] #}
{% set mem_mb = grains.get('mem_total', 0) %}
{% set is_gfx1151 = 'gfx1151' in grains.get('amd_gfx_targets', []) or 'Strix Halo' in (grains.get('gpus', []) | string) %}

{% if is_gfx1151 and mem_mb >= 170000 %}
  {% set halo_profile = 'gfx1151_192gib' %}
  {% set gttsize = '184320' %}
  {% set pages_limit = '47185920' %}
{% elif is_gfx1151 and mem_mb >= 110000 %}
  {% set halo_profile = 'gfx1151_128gib' %}
  {% set gttsize = '120832' %}
  {% set pages_limit = '30932992' %}
{% else %}
  {% set halo_profile = grains.get('strix_halo_profile', 'none') %}
{% endif %}

# 1. Install all ROCm 7.1, HIP, rocWMMA, and build dependencies on Fedora 44
maya_rocm_packages:
  pkg.installed:
    - pkgs:
      - inxi
      - git
      - curl
      - cmake
      - gcc-c++
      - clang
      - libaio-devel
      - rocm-devel
      - rocm-hip-devel
      - rocm-runtime-devel
      - rocm-device-libs
      - rocm-comgr
      - rocm-comgr-devel
      - rocm-clang
      - rocm-cmake
      - rocm-smi
      - rocm-smi-devel
      - rocminfo
      - hipblas
      - hipblas-devel
      - rocblas
      - rocblas-devel
      - hipblaslt-devel
      - hiprand-devel
      - hipsparse-devel
      - hipcub-devel
      - hipfft-devel
      - rocwmma-devel
      - rocprim-devel
      - rocthrust-devel

# 2. If gfx1151 + 192 GiB or gfx1151 + 128 GiB: set Salt grain & kernel args
{% if halo_profile in ['gfx1151_192gib', 'gfx1151_128gib'] %}
{% set kargs = 'amdgpu.gttsize=' ~ gttsize ~ ' ttm.pages_limit=' ~ pages_limit ~ ' ttm.page_pool_size=' ~ pages_limit ~ ' amd_iommu=off' %}

set_strix_halo_grain:
  grains.present:
    - name: strix_halo_profile
    - value: {{ halo_profile }}
    - force: True

set_strix_halo_kargs_grain:
  grains.present:
    - name: strix_halo_kargs
    - value: "{{ kargs }}"
    - force: True

configure_strix_halo_kernel_args:
  cmd.run:
    - name: grubby --update-kernel=ALL --args="{{ kargs }}"
    - unless: grubby --info=DEFAULT | grep -q "amdgpu.gttsize={{ gttsize }}"

mlops_memlock_limits:
  file.managed:
    - name: /etc/security/limits.d/99-mlops-memlock.conf
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        mlops soft memlock unlimited
        mlops hard memlock unlimited
{% endif %}

# 3. Ensure the mlops user belongs to the GPU render and video groups
mlops_gpu_groups:
  user.present:
    - name: mlops
    - optional_groups:
      - render
      - video
    - remove_groups: False

# 4. Symlink /opt/rocm -> /usr
rocm_opt_symlink:
  file.symlink:
    - name: /opt/rocm
    - target: /usr
    - force: True
    - require:
      - pkg: maya_rocm_packages

# 5. Persist ROCm and Hugging Face Mirror environment variables system-wide
maya_env_profile:
  file.managed:
    - name: /etc/profile.d/maya-rocm.sh
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        export ROCM_PATH=/usr
        export HIP_PATH="$(hipconfig -R 2>/dev/null || echo /usr)"
        export HIP_CLANG_PATH="/usr/lib64/rocm/llvm/bin"
        export HF_ENDPOINT="https://hf.ergoshear.dev"
    - require:
      - pkg: maya_rocm_packages

# 6. Create /opt/maya, /srv/models/maya, and /opt/Maya-data owned by mlops:mlops
{% for dir_path in ['/opt/maya', '/srv/models/maya', '/opt/Maya-data'] %}
maya_dir_{{ loop.index }}:
  file.directory:
    - name: {{ dir_path }}
    - user: mlops
    - group: mlops
    - mode: '0755'
    - makedirs: True
{% endfor %}

# 7. Clone https://github.com/mw00/project-maya.git into /opt/maya as mlops
project_maya_repo:
  git.latest:
    - name: https://github.com/mw00/project-maya.git
    - target: /opt/maya
    - user: mlops
    - force_clone: True
    - require:
      - pkg: maya_rocm_packages
      - file: maya_dir_1