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
    - opts: defaults,noatime
    - dump: 0
    - pass_num: 2
    - persist: True
    - mount: True
    - match_on: device
    - require:
      - blockdev: mlops-storage-filesystem

mlops-storage-directory-permissions:
  file.directory:
    - name: /srv/storage
    - user: mlops
    - group: mlops
    - dir_mode: '0770'
    - require:
      - mount: mlops-storage-mount

mlops-storage-selinux-tools:
  pkg.installed:
    - name: policycoreutils-python-utils

mlops-storage-selinux-context:
  selinux.fcontext_policy_present:
    - name: '/srv/storage(/.*)?'
    - sel_type: public_content_rw_t
    - filetype: a
    - require:
      - pkg: mlops-storage-selinux-tools
      - mount: mlops-storage-mount

mlops-storage-selinux-relabel:
  cmd.run:
    - name: restorecon -RF /srv/storage
    - onchanges:
      - selinux: mlops-storage-selinux-context
    - require:
      - mount: mlops-storage-mount

mlops-storage-nfs-package:
  pkg.installed:
    - name: nfs-utils

mlops-storage-firewall-package:
  pkg.installed:
    - name: firewalld

mlops-storage-firewall-service:
  service.running:
    - name: firewalld
    - enable: True
    - require:
      - pkg: mlops-storage-firewall-package

mlops-storage-nfs-firewall:
  firewalld.present:
    - name: public
    - rich_rules:
      - 'rule family="ipv4" source address="192.168.202.0/24" port port="2049" protocol="tcp" accept'
    - prune_rich_rules: False
    - require:
      - service: mlops-storage-firewall-service

mlops-storage-nfs-exports:
  file.managed:
    - name: /etc/exports.d/mlops-storage.exports
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        /srv/storage mlops-node-*.lan(rw,sync,root_squash,no_subtree_check,fsid=0)
    - require:
      - file: mlops-storage-directory-permissions
      - cmd: mlops-storage-selinux-relabel

mlops-storage-nfs-server:
  service.running:
    - name: nfs-server
    - enable: True
    - require:
      - pkg: mlops-storage-nfs-package
      - file: mlops-storage-nfs-exports
      - firewalld: mlops-storage-nfs-firewall

mlops-storage-nfs-exportfs:
  cmd.run:
    - name: exportfs -ra
    - onchanges:
      - file: mlops-storage-nfs-exports
    - require:
      - service: mlops-storage-nfs-server
{% endif %}
