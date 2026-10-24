{% set disabled_id = 'rtx4090_muse_glimmer_qwen38' %}
{% set disabled_target = 'mlops-node-6' %}
{% set disabled_user_units = ['rtx4090-llama-router.service'] %}
{% set disabled_system_units = [] %}
{% set disabled_routes = [] %}
{% include 'mlops/disabled/runtime.jinja' %}
