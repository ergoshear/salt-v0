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

        if [[ ! -e "$file" ]]; then
          printf '{"changed": false, "comment": "No regular K3s passwd file to recover"}\n'
          exit 0
        fi
        if [[ ! -f "$file" || -L "$file" ]]; then
          echo "Refusing recovery: expected a regular passwd file at $file" >&2
          exit 1
        fi

        service_state=$(systemctl show --property=ActiveState --value k3s)
        if [[ "$service_state" == active ]]; then
          printf '{"changed": false, "comment": "K3s is active; skipping passwd recovery"}\n'
          exit 0
        fi

        if ! journalctl -u k3s -b --no-pager -g 'cred/passwd newer than datastore' |
          grep -F "$file newer than datastore" >/dev/null; then
          echo "Refusing recovery: K3s is $service_state but its journal does not show the passwd/datastore mismatch" >&2
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

        systemctl reset-failed k3s
        systemctl start k3s
        if ! systemctl is-active --quiet k3s; then
          service_state=$(systemctl show --property=ActiveState --value k3s)
          echo "K3s did not reach active state (state: $service_state)" >&2
          exit 1
        fi
        printf '{"changed": true, "comment": "Backed up passwd to %s and recovered K3s"}\n' "$backup"
    - stateful: True
    - shell: /bin/bash
{% endif %}
