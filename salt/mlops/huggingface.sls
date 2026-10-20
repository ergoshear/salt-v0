{% set token = salt['pillar.get']('HUGGING_FACE_ACCESS_KEY', '') %}
{% if token %}
mlops-huggingface-token-directory:
  file.directory:
    - name: /home/mlops/.cache/huggingface
    - user: mlops
    - group: mlops
    - mode: '0700'
    - makedirs: True

mlops-huggingface-token:
  file.managed:
    - name: /home/mlops/.cache/huggingface/token
    - user: mlops
    - group: mlops
    - mode: '0600'
    - show_changes: False
    - contents: {{ token | tojson }}
    - require:
      - file: mlops-huggingface-token-directory
{% else %}
mlops-huggingface-token:
  file.exists:
    - name: /home/mlops/.cache/huggingface/token
{% endif %}
