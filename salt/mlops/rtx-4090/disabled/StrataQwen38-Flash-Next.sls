{% set disabled_id = 'rtx4090_strata' %}
{% set disabled_target = 'mlops-node-6' %}
{% set disabled_user_units = [] %}
{% set disabled_system_units = [
  {'service': 'strata-qwen38-flash-next.service', 'path': '/etc/systemd/system/strata-qwen38-flash-next.service'}
] %}
{% set disabled_routes = [] %}
{% include 'mlops/disabled/runtime.jinja' %}
