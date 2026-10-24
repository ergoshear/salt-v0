{% set disabled_id = 'rx9070_studioflow' %}
{% set disabled_target = 'mlops-node-3' %}
{% set disabled_user_units = [] %}
{% set disabled_system_units = [
  {'service': 'studioflow-fish-speech.service', 'path': '/etc/systemd/system/studioflow-fish-speech.service'},
  {'service': 'studioflow-zonos.service', 'path': '/etc/systemd/system/studioflow-zonos.service'},
  {'service': 'studioflow-whisper.service', 'path': '/etc/systemd/system/studioflow-whisper.service'}
] %}
{% set disabled_routes = [
  {'path': '/fish', 'endpoint': '127.0.0.1:8001'},
  {'path': '/zonos', 'endpoint': '127.0.0.1:8002'},
  {'path': '/whisper', 'endpoint': '127.0.0.1:8003'}
] %}
{% include 'mlops/disabled/runtime.jinja' %}
