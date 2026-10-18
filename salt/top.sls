base:
  '*':
    - system.pkgs
    - system.tuned
  'salt-master-01':
    - salt.master
  'k3s-control-plane-01':
    - k3s.control-plane