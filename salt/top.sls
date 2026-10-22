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
  'L@mlops-node-4,mlops-node-6,mlops-node-7,mlops-node-9':
    - match: compound
    - httpd
  'mlops-node-4':
#    - mlops.r9700.Qwen3.6-35B-A3B-DFlash
    - mlops.r9700.StrataQwen38-Flash-Next
  'mlops-node-5':
    - mlops.storage
  'mlops-node-6':
    - mlops.rtx-4090.StrataQwen38-Flash-Next
# Alternative llama.cpp states for the same host (do not run alongside Strata):
#   - mlops.rtx-4090.Qwen38-27B-GSQ-RCO-IQ3_S
# Alternative 125B MoE for the same RTX 4090 host (requires ~96 GB system RAM):
#   - mlops.rtx-4090.Qwen38-Flash-Next
#  'mlops-node-7':
#    - mlops.halo-395.Ornith-1-5-35B
#  'mlops-node-9':
#    - mlops.halo-495.Qwen3-8-27B-GSQ-RCO-IQ3_S
  'mlops-node-*':
    - match: glob
    - mlops.user
    - mlops.storage.client
