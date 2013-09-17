include:
    - mysql
    - users.sudo
    - nginx
    - python

{% set gitlab  = pillar.get('gitlab', {}) -%}

gitlab-dependencies:
    pkg.installed:
        - names:
            - build-essential
            - zlib1g-dev
            - libyaml-dev
            - libssl-dev
            - libgdbm-dev
            - libreadline-dev
            - libncurses5-dev
            - libffi-dev
            - curl
            - git-core
            - openssh-server
            - redis-server
            - checkinstall
            - libxml2-dev
            - libxslt-dev
            - libcurl4-openssl-dev
            - libicu-dev
        - require:
            - pip: gitlab-dependencies
    pip.installed:
        - name: docutils
        - upgrade: True
        - require:
            - sls: python

gitlab-user:
    user.present:
        - name: git
        - fullname: Gitlab
        - shell: /bin/bash
        - home: /home/git
    file.append:
        - name: /etc/sudoers
        - text:
            - "git    ALL=(ALL)  NOPASSWD: ALL"
        - require:
          - file: sudoer-defaults
          - user: gitlab-user

gitlab-shell:
    git.latest:
        - name: https://github.com/gitlabhq/gitlab-shell.git
        - rev: v1.7.1
        - target: /home/git/gitlab-shell
        - runas: git
        - require:
            - user: gitlab-user
            - pkg: gitlab-dependencies
            - file: gitlab-ruby-installation
    file.managed:
        - name: /home/git/gitlab-shell/config.yml
        - source: salt://gitlab/files/gitlab-shell/config.yml.jinja
        - mode: 744
        - user: git
        - template: jinja
        - require:
            - git: gitlab-shell
    cmd.run:
        - name: /home/git/gitlab-shell/bin/install
        - user: git
        - watch:
            - file: gitlab-shell
        - require:
            - pkg: gitlab-dependencies

gitlab-database:
    mysql_user.present:
        - name: gitlab
        - host: localhost
        - password: {{ gitlab.get('mysql_password', '9564ec5952434e6c8dc7764652863edc') }}
    mysql_database:
        - present
        - name: gitlabhq_production
        - require:
            - sls: mysql
    mysql_grants.present:
        - grant: all privileges
        - database: gitlabhq_production.*
        - user: gitlab
        - require:
            - mysql_user: gitlab-database
            - mysql_database: gitlab-database

gitlab:
    git.latest:
        - name: https://github.com/gitlabhq/gitlabhq.git
        - rev: 6-0-stable
        - target: /home/git/gitlab
        - runas: git
        - require:
            - user: gitlab-user
            - pkg: gitlab-dependencies
    file.managed:
        - name: /home/git/gitlab/config/gitlab.yml
        - source: salt://gitlab/files/gitlab/gitlab.yml.jinja
        - mode: 744
        - user: git
        - template: jinja
        - require:
            - git: gitlab
    cmd.run:
        - names:
            - git config --global user.name "GitLab"
            - git config --global user.email "gitlab@localhost"
            - git config --global core.autocrlf input
        - unless: git config --global user.name | grep "GitLab"
        - user: git
        - require:
            - user: gitlab-user
            - pkg: gitlab-dependencies
    service.running:
        - enable: True
        - watch:
            - git: gitlab
        - require:
            - file: gitlab-init-script

gitlab-directories:
    file.directory:
        - names:
            - /home/git/gitlab-satellites/
            - /home/git/gitlab/tmp/pids/
            - /home/git/gitlab/tmp/sockets/
            - /home/git/gitlab/public/uploads/
        - user: git
        - mode: 755
        - makedirs: True
        - require:
            - git: gitlab

gitlab-unicorn-conf:
    file.managed:
        - name: /home/git/gitlab/config/unicorn.rb
        - source: salt://gitlab/files/gitlab/unicorn.rb.jinja
        - mode: 744
        - user: git
        - template: jinja
        - require:
            - git: gitlab

gitlab-database-conf:
    file.managed:
        - name: /home/git/gitlab/config/database.yml
        - source: salt://gitlab/files/gitlab/database.yml.mysql.jinja
        - mode: 744
        - user: git
        - template: jinja
        - require:
            - git: gitlab
            - mysql_grants: gitlab-database

gitlab-ruby-installation:
    rvm.installed:
        - name: ruby-1.9.3
        - default: True
        - runas: git
        - require:
            - file: gitlab-user
    gem.installed:
        - name: charlock_holmes
        - version: 0.6.9.4
        - runas: git
        - ruby: ruby-1.9.3
        - require:
            - rvm: gitlab-ruby-installation
    file.append:
        - name: /home/git/.bashrc
        - text: '[[ -s "/home/git/.rvm/scripts/rvm" ]] && source "/home/git/.rvm/scripts/rvm"'
        - require:
            - rvm: gitlab-ruby-installation

gitlab-shell-rvm:
    cmd.run:
        - name: env | grep -E "^(GEM_HOME|PATH|RUBY_VERSION|MY_RUBY_HOME|GEM_PATH)=" > /home/git/.ssh/environment
        - unless: cat /home/git/.ssh/environment | grep "RUBY_VERSION=$RUBY_VERSION"
        - user: git
        - require:
            - file: gitlab-ruby-installation
    file.append:
        - name: /etc/ssh/sshd_config
        - text: PermitUserEnvironment yes
        - require:
            - cmd: gitlab-shell-rvm
    service.running:
        - name: ssh
        - reload: True
        - watch:
            - file: /etc/ssh/sshd_config

gitlab-bundle-install:
    cmd.run:
        - names:
            - rvm 1.9.3 do bundle install --deployment --without development test postgres aws
        - cwd: /home/git/gitlab
        - user: git
        - require:
            - gem: gitlab-ruby-installation
            - sls: mysql

gitlab-database-install:
    cmd.run:
        - name: yes 'yes' | rvm 1.9.3 do bundle exec rake gitlab:setup RAILS_ENV=production
        - cwd: /home/git/gitlab
        - user: git
        - unless: 'mysql -ugitlab -p{{ gitlab.get('mysql_password', '9564ec5952434e6c8dc7764652863edc') }} gitlabhq_production -e "show tables" | grep -q users'
        - require:
            - cmd: gitlab-bundle-install

gitlab-init-script:
    file.managed:
        - name: /etc/init.d/gitlab
        - source: salt://gitlab/files/gitlab/init_script.jinja
        - mode: 755
        - user: git
        - template: jinja
        - require:
            - git: gitlab

gitlab-nginx-conf:
    file.managed:
        - name: /etc/nginx/sites-available/gitlab
        - source: salt://gitlab/files/gitlab/nginx.conf.jinja
        - mode: 755
        - user: git
        - template: jinja
        - require:
            - service: gitlab

gitlab-nginx-symlink:
    file.symlink:
        - name: /etc/nginx/sites-enabled/gitlab
        - target: /etc/nginx/sites-available/gitlab
        - require:
            - file: gitlab-nginx-conf
    service.running:
        - name: nginx
        - reload: True
        - watch:
            - file: gitlab-nginx-symlink
        - require:
            - sls: nginx





