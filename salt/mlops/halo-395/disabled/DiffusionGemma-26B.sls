{% set disabled_id = 'halo395_diffusiongemma' %}
{% set disabled_target = 'mlops-node-7' %}
{% set disabled_user_units = ['strix-llama-router.service'] %}
{% set disabled_system_units = [] %}
{% set disabled_routes = [] %}
{% include 'mlops/disabled/runtime.jinja' %}
