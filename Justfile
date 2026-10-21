pre-commit action:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{ quote(justfile_directory()) }}
    case {{ quote(action) }} in
        setup)
            uv tool install pre-commit
            uv tool run pre-commit install
            ;;
        *)
            echo 'Usage: just pre-commit setup' >&2
            exit 2
            ;;
    esac
