{# Route MLOps GPU nodes to throughput-performance, everything else to aws #}
{% if grains['id'].startswith('mlops-node-') %}
  {% set target_profile = 'throughput-performance' %}
{% else %}
  {% set target_profile = 'aws' %}
{% endif %}

tuned-package:
  pkg.installed:
    - name: tuned

aws-tuned-profile:
  file.managed:
    - name: /etc/tuned/aws/tuned.conf
    - source: salt://system/files/aws-tuned.conf  # (Keep your existing source/contents block here)
    - makedirs: True
    - require:
      - pkg: tuned-package

tuned-service:
  service.running:
    - name: tuned
    - enable: True
    - require:
      - pkg: tuned-package
      - file: aws-tuned-profile

tuned-profile-active:
  cmd.run:
    - name: tuned-adm profile {{ target_profile }}
    - unless: 'tuned-adm active | grep -q "Current active profile: {{ target_profile }}$"'
    - require:
      - service: tuned-service