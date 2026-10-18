tuned-package:
  pkg.installed:
    - name: tuned

aws-tuned-profile:
  file.managed:
    - name: /etc/tuned/aws/tuned.conf
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - contents: |
        [main]
        include=virtual-guest
    - require:
      - pkg: tuned-package

tuned-service:
  service.running:
    - name: tuned
    - enable: True
    - require:
      - pkg: tuned-package
    - watch:
      - file: aws-tuned-profile

aws-tuned-profile-active:
  cmd.run:
    - name: tuned-adm profile aws
    - unless: "tuned-adm active | grep -Fxq 'Current active profile: aws'"
    - require:
      - service: tuned-service
      - file: aws-tuned-profile
