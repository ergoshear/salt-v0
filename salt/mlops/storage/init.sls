{% set node = grains['id'] %}
{% set disk = '/dev/disk/by-id/ata-WDC_WD40EZAZ-19SF3B0_WD-WX42DA063C4T-part1' %}
{% if node != 'mlops-node-5' %}
mlops-storage-target-guard:
  test.fail_without_changes:
    - name: The storage state is restricted to mlops-node-5
{% else %}
mlops-storage-vgreduce:
  cmd.run:
    - name: vgreduce fedora {{ disk }}
    - onlyif: pvs --noheadings -o vg_name {{ disk }} | grep -qw fedora

mlops-storage-pv-absent:
  lvm.pv_absent:
    - name: {{ disk }}
    - require:
      - cmd: mlops-storage-vgreduce

mlops-storage-filesystem:
  blockdev.formatted:
    - name: {{ disk }}
    - fs_type: ext4
    - force: False
    - require:
      - lvm: mlops-storage-pv-absent

mlops-storage-mount:
  mount.mounted:
    - name: /srv/storage
    - device: {{ disk }}
    - fstype: ext4
    - mkmnt: True
    - opts: defaults
    - dump: 0
    - pass_num: 2
    - persist: True
    - mount: True
    - match_on: device
    - require:
      - blockdev: mlops-storage-filesystem
{% endif %}
