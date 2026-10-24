{% set disabled_id = 'rx9070_kokoro' %}
{% set disabled_target = 'mlops-node-3' %}
{% set disabled_user_units = [] %}
{% set disabled_system_units = [
  {'service': 'kokoro-fastapi.service', 'path': '/etc/systemd/system/kokoro-fastapi.service'}
] %}
{% set disabled_routes = [
  {'path': '/', 'port': 443, 'endpoint': '127.0.0.1:8880'}
] %}
{% include 'mlops/disabled/runtime.jinja' %}
