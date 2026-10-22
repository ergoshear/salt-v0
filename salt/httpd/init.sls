{#
  HTTPS reverse proxy in front of a local service (default 127.0.0.1:8080).

  Pillar overrides:
    HTTPD_SERVER_NAME      TLS name (default: <minion-id>.tailb11f97.ts.net)
    HTTPD_PROXY_HOST       upstream address (default: 127.0.0.1)
    HTTPD_PROXY_PORT       upstream port (default: 8080)
    HTTPD_SSL_CERT         existing certificate path (requires HTTPD_SSL_KEY)
    HTTPD_SSL_KEY          existing private key path (requires HTTPD_SSL_CERT)
    HTTPD_HTTP_REDIRECT    redirect HTTP to HTTPS (default: true)
    HTTPD_FIREWALL_ZONE    firewalld zone to open (default: public)
#}
{% set node = grains['id'] %}
{% set default_server_name = node ~ '.tailb11f97.ts.net' %}
{% set server_name = salt['pillar.get']('HTTPD_SERVER_NAME', default_server_name) %}
{% set proxy_host = salt['pillar.get']('HTTPD_PROXY_HOST', '127.0.0.1') %}
{% set proxy_port = salt['pillar.get']('HTTPD_PROXY_PORT', 8080) %}
{% set redirect_http = salt['pillar.get']('HTTPD_HTTP_REDIRECT', True) %}
{% set firewall_zone = salt['pillar.get']('HTTPD_FIREWALL_ZONE', 'public') %}
{% set cert_pillar = salt['pillar.get']('HTTPD_SSL_CERT', '') %}
{% set key_pillar = salt['pillar.get']('HTTPD_SSL_KEY', '') %}

{% if (cert_pillar and not key_pillar) or (key_pillar and not cert_pillar) %}
httpd-proxy-cert-pair-required:
  test.fail_without_changes:
    - name: Set both HTTPD_SSL_CERT and HTTPD_SSL_KEY, or leave both unset to use a Tailscale certificate
{% elif not cert_pillar and server_name != default_server_name %}
httpd-proxy-tailscale-name-required:
  test.fail_without_changes:
    - name: Tailscale issues certificates only for {{ default_server_name }}; set HTTPD_SSL_CERT and HTTPD_SSL_KEY to use {{ server_name }}
{% else %}
{% if cert_pillar %}
  {% set cert = cert_pillar %}
  {% set key = key_pillar %}
  {% set obtain_cert = False %}
{% else %}
  {% set cert = '/etc/pki/tls/certs/httpd-proxy-' ~ node ~ '.crt' %}
  {% set key = '/etc/pki/tls/private/httpd-proxy-' ~ node ~ '.key' %}
  {% set obtain_cert = True %}
{% endif %}

httpd-proxy-packages:
  pkg.installed:
    - names:
      - httpd
      - mod_ssl
{% if obtain_cert %}
      - openssl
{% endif %}

httpd-proxy-modules:
  file.managed:
    - name: /etc/httpd/conf.modules.d/10-httpd-proxy.conf
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        <IfModule !proxy_module>
          LoadModule proxy_module modules/mod_proxy.so
        </IfModule>
        <IfModule !proxy_http_module>
          LoadModule proxy_http_module modules/mod_proxy_http.so
        </IfModule>
        <IfModule !headers_module>
          LoadModule headers_module modules/mod_headers.so
        </IfModule>
        <IfModule !ssl_module>
          LoadModule ssl_module modules/mod_ssl.so
        </IfModule>
    - require:
      - pkg: httpd-proxy-packages

{% if obtain_cert %}
httpd-proxy-cert-directory:
  file.directory:
    - name: /etc/pki/tls/certs
    - makedirs: True
    - dir_mode: '0755'

httpd-proxy-private-key-directory:
  file.directory:
    - name: /etc/pki/tls/private
    - makedirs: True
    - dir_mode: '0700'

httpd-proxy-tls-cert:
  cmd.run:
    - name: |
        umask 077
        tailscale cert \
          --cert-file {{ cert }} \
          --key-file {{ key }} \
          {{ server_name }}
        chmod 0644 {{ cert }}
        chmod 0600 {{ key }}
    - unless: |
        test -s {{ cert }} && test -s {{ key }} && \
        openssl x509 -checkend 2592000 -noout -in {{ cert }} >/dev/null 2>&1 && \
        openssl x509 -in {{ cert }} -noout -checkhost {{ server_name }} >/dev/null 2>&1 && \
        openssl x509 -in {{ cert }} -noout -issuer 2>/dev/null | grep -q "Let's Encrypt"
    - timeout: 180
    - require:
      - pkg: httpd-proxy-packages
      - file: httpd-proxy-cert-directory
      - file: httpd-proxy-private-key-directory
{% endif %}

httpd-proxy-config:
  file.managed:
    - name: /etc/httpd/conf.d/ssl.conf
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by Salt (httpd state): TLS terminates here and proxies to
        # http://{{ proxy_host }}:{{ proxy_port }}/.
        ServerName {{ server_name }}
        Listen 443 https

        <VirtualHost _default_:443>
            ServerName {{ server_name }}
            ServerAlias *
            SSLEngine on
            SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
            SSLCipherSuite HIGH:!aNULL:!MD5:!RC4
            SSLHonorCipherOrder off
            SSLCertificateFile {{ cert }}
            SSLCertificateKeyFile {{ key }}

            ProxyRequests Off
            ProxyPreserveHost On
            ProxyTimeout 300
            RequestHeader set X-Forwarded-Proto "https"
            RequestHeader set X-Forwarded-Port "443"
            ProxyPass / http://{{ proxy_host }}:{{ proxy_port }}/ retry=0
            ProxyPassReverse / http://{{ proxy_host }}:{{ proxy_port }}/
        </VirtualHost>

        {% if redirect_http %}
        <VirtualHost *:80>
            ServerName {{ server_name }}
            Redirect permanent / https://{{ server_name }}/
        </VirtualHost>
        {% endif %}
    - require:
      - pkg: httpd-proxy-packages
      - file: httpd-proxy-modules

httpd-proxy-selinux:
  cmd.run:
    - name: setsebool -P httpd_can_network_connect on
    - unless: |
        ! command -v setsebool >/dev/null 2>&1 || \
        [ "$(getenforce 2>/dev/null)" = "Disabled" ] || \
        [ "$(getsebool httpd_can_network_connect 2>/dev/null | awk '{print $NF}')" = "on" ]
    - require:
      - pkg: httpd-proxy-packages

httpd-proxy-firewalld-package:
  pkg.installed:
    - name: firewalld

httpd-proxy-firewalld:
  service.running:
    - name: firewalld
    - enable: True
    - require:
      - pkg: httpd-proxy-firewalld-package

httpd-proxy-firewall:
  firewalld.present:
    - name: {{ firewall_zone }}
    - services:
      - http
      - https
    - prune_services: False
    - require:
      - service: httpd-proxy-firewalld

httpd-proxy-config-check:
  cmd.run:
    - name: /usr/sbin/httpd -t
    - onchanges:
      - file: httpd-proxy-modules
      - file: httpd-proxy-config
    - require:
      - pkg: httpd-proxy-packages

httpd-proxy-service:
  service.running:
    - name: httpd
    - enable: True
    - require:
      - cmd: httpd-proxy-config-check
      - cmd: httpd-proxy-selinux
    - watch:
      - file: httpd-proxy-config
      - file: httpd-proxy-modules
{% if obtain_cert %}
      - cmd: httpd-proxy-tls-cert
{% endif %}
{% endif %}
