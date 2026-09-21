#!/bin/bash
# Provision a self-hosted MariaDB behind a Teleport database agent, in an LXC.
#
# Differs from userdata-mysql.tpl (Amazon Linux) where it matters:
#   - apt + mariadb-server, not dnf + mariadb105-server
#   - drop-in config lives in /etc/mysql/mariadb.conf.d/, not /etc/my.cnf.d/
#   - bind-address stays loopback: the agent shares this container, so the
#     engine is never exposed on the LAN
#   - users are created for BOTH 'localhost' and '%'. A TCP connection to
#     127.0.0.1 is matched against the 'localhost' grant once name resolution
#     is on, and against '%' when it is not; creating only one of them yields
#     an access-denied that looks like a certificate problem.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

hostnamectl set-hostname "${name}" || true

apt-get update -qq
apt-get install -y -qq mariadb-server curl ca-certificates

systemctl enable mariadb
systemctl start mariadb

install -d -o mysql -g mysql -m 700 /etc/mysql/ssl

# Both CAs in one file: ours signs the server cert, Teleport's db-client CA
# validates the certificate the agent presents.
cat > /etc/mysql/ssl/server.cas <<'CA_EOF'
${ca}
${tele_ca}
CA_EOF

cat > /etc/mysql/ssl/server.crt <<'CRT_EOF'
${cert}
CRT_EOF

cat > /etc/mysql/ssl/server.key <<'KEY_EOF'
${key}
KEY_EOF

chown -R mysql:mysql /etc/mysql/ssl
chmod 600 /etc/mysql/ssl/*

cat > /etc/mysql/mariadb.conf.d/99-teleport-ssl.cnf <<'EOF'
[mariadb]
bind-address            = 127.0.0.1
require_secure_transport = ON
ssl-ca                  = /etc/mysql/ssl/server.cas
ssl-cert                = /etc/mysql/ssl/server.crt
ssl-key                 = /etc/mysql/ssl/server.key
EOF

systemctl restart mariadb
for i in $(seq 1 30); do mysqladmin ping --silent && break; sleep 2; done

# Tidy the default install. Socket connections are exempt from
# require_secure_transport, so these still work as root.
mysql -e "DELETE FROM mysql.user WHERE User='';" || true
mysql -e "DROP DATABASE IF EXISTS test;" || true
mysql -e "FLUSH PRIVILEGES;"

# Cert-authenticated users. No passwords exist: the subject CN in the
# certificate Teleport presents IS the authentication.
for h in localhost '%'; do
  mysql -e "CREATE USER IF NOT EXISTS 'writer'@'$h' REQUIRE SUBJECT '/CN=writer';"
  mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'writer'@'$h';"
  mysql -e "CREATE USER IF NOT EXISTS 'reader'@'$h' REQUIRE SUBJECT '/CN=reader';"
  mysql -e "GRANT SELECT, SHOW VIEW ON *.* TO 'reader'@'$h';"
done
mysql -e "FLUSH PRIVILEGES;"

# Demo dataset, same shape as the Postgres one so a demo can switch engines
# without switching stories. Generic names only.
mysql -e "CREATE DATABASE IF NOT EXISTS demo;"
mysql demo <<'SQL'
CREATE TABLE IF NOT EXISTS customers (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(64) NOT NULL,
  region VARCHAR(16) NOT NULL,
  tier VARCHAR(16) NOT NULL
);
CREATE TABLE IF NOT EXISTS orders (
  id INT AUTO_INCREMENT PRIMARY KEY,
  customer_id INT,
  amount_cents BIGINT NOT NULL,
  status VARCHAR(16) NOT NULL,
  placed_at DATETIME NOT NULL
);
SQL

if [ "$(mysql -N -B demo -e 'SELECT count(*) FROM customers')" -eq 0 ]; then
  mysql demo <<'SQL'
INSERT INTO customers (name, region, tier)
WITH RECURSIVE g(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM g WHERE n < 240)
SELECT CONCAT('acme-', LPAD(n,3,'0')),
       ELT(1 + (n MOD 3), 'emea','amer','apac'),
       ELT(1 + ((n DIV 3) MOD 3), 'free','pro','enterprise')
FROM g;
INSERT INTO orders (customer_id, amount_cents, status, placed_at)
WITH RECURSIVE g(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM g WHERE n < 1500)
SELECT 1 + (n MOD 240),
       ((n * 977) MOD 90000) + 500,
       ELT(1 + (n MOD 6), 'paid','paid','paid','pending','refunded','failed'),
       NOW() - INTERVAL (n MOD 720) HOUR
FROM g;
SQL
fi

# ---- Teleport agent ---------------------------------------------------------
curl -fsSL "https://${proxy_address}/scripts/install.sh" | bash

install -d -m 700 /etc/teleport
cat > /etc/teleport/bound-keypair-secret <<'SECRET_EOF'
${registration_key}
SECRET_EOF
chmod 600 /etc/teleport/bound-keypair-secret

cat > /etc/teleport.yaml <<EOF
version: v3
teleport:
  data_dir: "/var/lib/teleport"
  proxy_server: "${proxy_address}:443"
  join_params:
    method: bound_keypair
    token_name: "${token}"
    bound_keypair:
      registration_secret_path: /etc/teleport/bound-keypair-secret
  log:
    output: stderr
    severity: INFO
db_service:
  enabled: true
  resources:
    - labels:
        "env": "${env}"
        "team": "${team}"
        # ENGINE IS LOAD-BEARING. Without it every db agent matching env+team
        # claims every database with those labels -- so the mysql host also
        # advertised postgres-dev and tried to reach localhost:5432, where
        # nothing listens. Half the routes were dead and it looked like a
        # flaky database rather than a matcher that was too broad.
        "engine": "${engine}"
ssh_service:
  enabled: "yes"
  labels:
    "env": "${env}"
    "team": "${team}"
    "role": "database"
auth_service:
  enabled: "no"
proxy_service:
  enabled: "no"
app_service:
  enabled: "no"
EOF

systemctl enable teleport
systemctl restart teleport
