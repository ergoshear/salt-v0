mlops-user-packages:
  pkg.installed:
    - names:
      - sudo
      - openssh-server

mlops-user-account:
  user.present:
    - name: mlops
    - home: /home/mlops
    - createhome: True
    - shell: /bin/bash
    - require:
      - pkg: mlops-user-packages

mlops-passwordless-sudo:
  file.managed:
    - name: /etc/sudoers.d/90-mlops
    - user: root
    - group: root
    - mode: '0440'
    - contents: 'mlops ALL=(ALL) NOPASSWD: ALL'
    - require:
      - user: mlops-user-account

mlops-ssh-authorized-key:
  ssh_auth.present:
    - name: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM/9+DZ691uuXblxWFazYlknbgJe6mQiNrSkTgqbuAhX mlops@server
    - user: mlops
    - require:
      - user: mlops-user-account

mlops-sshd-key-only-config:
  file.managed:
    - name: /etc/ssh/sshd_config.d/00-mlops-auth.conf
    - user: root
    - group: root
    - mode: '0600'
    - makedirs: True
    - contents: |
        PubkeyAuthentication yes
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        AuthenticationMethods publickey
    - require:
      - pkg: mlops-user-packages

mlops-sshd-config-valid:
  cmd.run:
    - name: /usr/sbin/sshd -t
    - onchanges:
      - file: mlops-sshd-key-only-config
    - require:
      - file: mlops-sshd-key-only-config

mlops-sshd-service:
  service.running:
    - name: sshd
    - enable: True
    - reload: True
    - require:
      - pkg: mlops-user-packages
      - cmd: mlops-sshd-config-valid
    - watch:
      - file: mlops-sshd-key-only-config
