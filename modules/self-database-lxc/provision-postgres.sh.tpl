#!/bin/bash
# Provision a self-hosted Postgres behind a Teleport database agent, in an LXC.
#
# Differs from userdata-postgres.tpl (Amazon Linux) in three ways that matter:
#   - apt, not dnf, and Ubuntu's postgresql package (16 on 24.04)
#   - config lives in /etc/postgresql/<ver>/main, not the data directory, so the
#     ssl_* paths must be ABSOLUTE; relative paths resolve against the data dir
#     and silently fail to load
#   - listen_addresses stays 'localhost'. The agent is in this container, so the
#     engine never needs to be reachable on the LAN.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

hostnamectl set-hostname "${name}" || true

apt-get update -qq
# `sudo` IS LOAD-BEARING and is listed explicitly rather than arriving as
# somebody else's dependency. Teleport's host user management requires
# `visudo`, and without it the agent logs, at DEBUG only:
#   Skipping host user management  missing required binaries: visudo
#   Not creating host user: node has disabled host user creation
# and every SSH session dies with "Failed to launch: user: unknown user X"
# -- regardless of create_host_user_mode being keep on every matching role.
# That cost a long diagnosis on CT104 (siem), which was hand-built on a Debian
# template with no sudo. It looks exactly like an RBAC problem and is not one.
apt-get install -y -qq postgresql postgresql-contrib curl ca-certificates jq sudo

PGVER="$(ls /etc/postgresql | sort -V | tail -1)"
PGCONF="/etc/postgresql/$PGVER/main"
CERTS="/etc/postgresql/$PGVER/certs"

install -d -o postgres -g postgres -m 700 "$CERTS"

# server.cas holds BOTH CAs: our own (chain for the server cert) and Teleport's
# db-client CA (so certs the agent presents validate). One file, because
# Postgres takes a single ssl_ca_file.
cat > "$CERTS/server.cas" <<'CA_EOF'
${ca}
${tele_ca}
CA_EOF

cat > "$CERTS/server.crt" <<'CRT_EOF'
${cert}
CRT_EOF

cat > "$CERTS/server.key" <<'KEY_EOF'
${key}
KEY_EOF

chown -R postgres:postgres "$CERTS"
chmod 600 "$CERTS"/*

cat >> "$PGCONF/postgresql.conf" <<EOF

# --- Teleport database access ---
listen_addresses = 'localhost'
ssl = on
ssl_cert_file = '$CERTS/server.crt'
ssl_key_file  = '$CERTS/server.key'
ssl_ca_file   = '$CERTS/server.cas'
EOF

# cert rules FIRST: pg_hba is first-match-wins, so a permissive local rule above
# them would take precedence and client-cert auth would never be exercised.
cat > "$PGCONF/pg_hba.conf" <<'EOF'
hostssl all             all             ::1/128                 cert
hostssl all             all             127.0.0.1/32            cert
local   all             all                                     peer
EOF

systemctl enable postgresql
systemctl restart postgresql

# Wait for the socket rather than assuming restart is synchronous.
for i in $(seq 1 30); do
  sudo -u postgres pg_isready -q && break
  sleep 2
done

sudo -u postgres psql <<'SQL'
-- Roles map to Teleport db_users. LOGIN only; no passwords exist, because
-- authentication is the client certificate Teleport presents.
SELECT 'CREATE ROLE writer LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='writer')\gexec
SELECT 'CREATE ROLE reader LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='reader')\gexec
GRANT ALL PRIVILEGES ON DATABASE postgres TO writer;
GRANT CONNECT ON DATABASE postgres TO reader;
-- PostgreSQL 15+ revoked CREATE on schema public from PUBLIC, so the
-- database-level grants above are not enough: without these, writer connects
-- but any CREATE TABLE fails with "permission denied for schema public".
GRANT ALL ON SCHEMA public TO writer;
GRANT USAGE ON SCHEMA public TO reader;
ALTER DEFAULT PRIVILEGES FOR ROLE writer IN SCHEMA public GRANT SELECT ON TABLES TO reader;
SQL

# ---- Teleport agent ---------------------------------------------------------
# ALLOW A PROXY CHANGE. `teleport-update` refuses to install over an existing
# agent that is bound to a DIFFERENT proxy:
#   refusing to install with conflicting proxy addresses, pass
#   --allow-proxy-conflict to override
# That guard is right for an accidental re-point and wrong for a deliberate
# cluster migration, which is exactly what re-running this script with a new
# ${proxy_address} is. Harmless on a fresh container (no existing install to
# conflict with) and required on a cutover.
#
# Passed via the env var rather than an argv flag because the install script
# is piped to bash and forwards TELEPORT_* to teleport-update.
export TELEPORT_ALLOW_PROXY_CONFLICT=1
curl -fsSL "https://${proxy_address}/scripts/install.sh" | bash || \
  teleport-update enable --proxy "${proxy_address}:443" --allow-proxy-conflict

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
  # Dynamic registration: the database resource is declared in terraform by
  # modules/dynamic-registration, and this agent picks it up by label. Adding a
  # database later needs no change on this host.
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

# ---- ship logs to the SIEM ------------------------------------------------
# These two containers were the estate's blind spot: measured 2026-09-27, the
# syslog stream carried lgm, teleport-k3s, cloudflared, immich and udr7 and
# NEITHER database. rsyslog was running and healthy in both; nothing had ever
# told it where to send anything.
#
# Matches CT103's 90-siem.conf exactly, including the reason for the shape:
# RainerScript rather than the legacy $ActionQueue directives, which need a
# $WorkDirectory to build the disk-assisted queue and SILENTLY DELIVER NOTHING
# when it is missing. RFC5424 so hostname and severity survive as real fields
# rather than being parsed out of the message body.
mkdir -p /var/spool/rsyslog
cat > /etc/rsyslog.d/90-siem.conf <<'RSYSLOG_EOF'
# Managed by terraform (modules/self-database-lxc). Hand edits are reverted.
#
# Target is a NAME, not an address, so it follows the host. Resolvable because
# this container's first resolver is the router (var.dns_servers).
global(workDirectory="/var/spool/rsyslog")
*.* action(type="omfwd"
           target="${siem_host}" port="${siem_port}" protocol="tcp"
           template="RSYSLOG_SyslogProtocol23Format"
           queue.type="linkedlist"
           queue.filename="siemfwd"
           queue.maxdiskspace="64m"
           queue.saveonshutdown="on"
           action.resumeRetryCount="-1")
RSYSLOG_EOF
systemctl restart rsyslog

systemctl enable teleport
systemctl restart teleport
