
k3s-pkgs-install:
  pkg.installed:
    - names:
      - kubectl
      - helm
      - kustomize

k3s-install:
  cmd.run:
    - name: curl -sfL https://get.k3s.io | sh -
    - unless: test -x /usr/local/bin/k3s
