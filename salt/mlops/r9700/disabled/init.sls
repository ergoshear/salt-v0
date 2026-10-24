{% set disabled_id = 'r9700_qwen36_compat' %}
{% set disabled_target = 'mlops-node-4' %}
{% set disabled_user_units = ['r9700-llama-router.service'] %}
{% set disabled_system_units = [] %}
{% set disabled_routes = [] %}
{% include 'mlops/disabled/runtime.jinja' %}
