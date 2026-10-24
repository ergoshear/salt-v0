{% set node = grains['id'] %}
{% if node != 'k3s-control-plane-01' %}
k3s-passwd-recovery-prerequisites:
  test.fail_without_changes:
    - name: K3s passwd recovery is restricted to k3s-control-plane-01
{% else %}
k3s-passwd-recovery:
  cmd.run:
    - name: |
        set -euo pipefail
        file=/var/lib/rancher/k3s/server/cred/passwd

        if [[ ! -f "$file" || -L "$file" ]]; then
          echo "Refusing recovery: expected a regular passwd file at $file" >&2
          exit 1
        fi

        systemctl stop k3s
        service_state=$(systemctl show --property=ActiveState --value k3s)
        case "$service_state" in
          inactive|failed) ;;
          *)
            echo "Refusing recovery while k3s.service is $service_state" >&2
            exit 1
            ;;
        esac

        backup="${file}.backup-$(date -u +%Y%m%dT%H%M%SZ)-$$"
        if [[ -e "$backup" ]]; then
          echo "Refusing to overwrite existing backup $backup" >&2
          exit 1
        fi
        cp -a -- "$file" "$backup"
        cmp -s -- "$file" "$backup"
        rm -- "$file"
        printf "Backed up passwd file to %s and removed the original.\n" "$backup"

        systemctl reset-failed k3s
        systemctl start k3s
        service_state=$(systemctl show --property=ActiveState --value k3s)
        if [[ "$service_state" != "active" ]]; then
          echo "K3s did not reach active state (state: $service_state)" >&2
          exit 1
        fi
    - shell: /bin/bash
{% endif %}
