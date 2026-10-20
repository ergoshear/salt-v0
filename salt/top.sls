base:
  '*':
    - tailscale
    - system.pkgs

  'not L@mlops-node-4,mlops-node-6,mlops-node-7,mlops-node-9':
    - match: compound
    - system.tuned

  'salt-master-01':
    - salt.master
  'k3s-control-plane-01':
    - k3s.control-plane
  'mlops-node-0':
    - k3s.agent
  'mlops-node-1':
    - k3s.agent
  'mlops-node-4':
    - mlops.r9700
  'mlops-node-5':
    - mlops.storage
  'mlops-node-6':
    - mlops.rtx-4090
  'mlops-node-7':
    - mlops.halo-395
  'mlops-node-9':
    - mlops.halo-495