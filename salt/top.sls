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
  'L@mlops-node-0,mlops-node-1,mlops-node-5':
    - match: compound
    - k3s.agent
#  'L@mlops-node-3,mlops-node-4,mlops-node-6,mlops-node-7,mlops-node-9':
#    - match: compound
#    - httpd
#  'mlops-node-3':
#    - mlops.rx9070.disabled.studioflow-tts
#    - mlops.rx9070.disabled.kokoro-fastapi-gpu
#  'mlops-node-4':
#    - mlops.r9700.disabled.StrataQwen38-Flash-Next
  'mlops-node-5':
    - mlops.storage
#  'mlops-node-6':
#    - mlops.rtx-4090.disabled.StrataQwen38-Flash-Next
#    - mlops.rtx-4090.disabled.Qwen38-27B-GSQ-RCO-IQ3_S
#    - mlops.rtx-4090.disabled.Qwen38-Flash-Next
#  'mlops-node-7':
#    - mlops.halo-395.disabled.Ornith-1-5-35B
#  'mlops-node-9':
#    - mlops.halo-495.disabled.Qwen3-8-27B-GSQ-RCO-IQ3_S
  'mlops-node-*':
    - match: glob
    - mlops.user
    - mlops.storage.client
