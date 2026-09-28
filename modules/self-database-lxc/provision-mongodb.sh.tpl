#!/usr/bin/env bash
# MongoDB + Teleport agent in one unprivileged LXC. Added 2026-09-28.
#
# PORTED FROM modules/self-database/userdata-mongodb.tpl, which does the same
# job on Amazon Linux via dnf. Three things had to change and each is a real
# difference rather than a translation:
#
#   1. Debian/apt repo instead of the Amazon-2023 yum repo, with the key in
#      /usr/share/keyrings rather than an rpm gpgkey line.
#   2. PATH must be exported — `pct exec` omits /usr/local/bin, which is a trap
#      already recorded in ~/github/CLAUDE.md.
#   3. `sudo` is installed explicitly. Teleport's host user creation
#      hard-requires `visudo` and logs its absence at DEBUG severity ONLY, then
#      every session dies with "unknown user X" no matter how correct the roles
#      are. That cost a long diagnosis on CT104.
#
# MONGODB'S TLS IS NOT LIKE POSTGRES'S, and this is the part worth reading.
# Postgres takes separate ssl_cert_file and ssl_key_file. MongoDB takes ONE
# file containing the certificate AND the private key concatenated
# (certificateKeyFile), so they are combined below. Pointing it at a bare
# certificate produces a startup failure that reads like a permissions problem.
set -euo pipefail
export PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

CERTS=/etc/certs
install -d -m 0755 "$CERTS"

apt-get update -qq
apt-get install -y -qq curl ca-certificates sudo

# ---- MongoDB from the vendor repo -------------------------------------------
# The distro does not ship mongodb-org, so the vendor repo is required rather
# than preferred.
# NO gpg IN THIS PATH, deliberately. `gpg --dearmor` needs a TTY and
# `pct exec` gives it none, so it dies with
#     gpg: cannot open '/dev/tty': No such device or address
# which stops the whole script AFTER mongod would otherwise install. apt accepts
# an ASCII-armored key directly when the signed-by path ends in .asc, so the
# dearmor step is not needed at all.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
  -o /etc/apt/keyrings/mongodb-server-7.0.asc
chmod 0644 /etc/apt/keyrings/mongodb-server-7.0.asc
echo "deb [signed-by=/etc/apt/keyrings/mongodb-server-7.0.asc] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main" \
  > /etc/apt/sources.list.d/mongodb-org-7.0.list
apt-get update -qq
apt-get install -y -qq mongodb-org

# ---- Certificates ------------------------------------------------------------
cat > "$CERTS/server.crt" <<'PEM_CERT'
${cert}
PEM_CERT
cat > "$CERTS/server.key" <<'PEM_KEY'
${key}
PEM_KEY

# ONE file, cert THEN key. This is the certificateKeyFile MongoDB wants; it
# will not accept the two separately.
cat "$CERTS/server.crt" "$CERTS/server.key" > "$CERTS/server.pem"

# The CA the ENGINE trusts for CLIENT certs is Teleport's db-client CA, not our
# own server CA. Client auth runs the opposite direction from server auth, and
# conflating the two is why a correct-looking config rejects the agent.
cat > "$CERTS/teleport-db-client.cas" <<'PEM_TELE_CA'
${tele_ca}
PEM_TELE_CA

chown -R mongodb:mongodb "$CERTS"
chmod 0600 "$CERTS/server.key" "$CERTS/server.pem"

# ---- Phase 1: no TLS, so a user can be created -------------------------------
# Deliberately two-phase, mirroring the AWS module. With TLS and
# authentication already on there is no way in to create the first user, so the
# engine comes up plain on loopback, users are created, then it is reconfigured.
# Loopback-only throughout, so the plain phase is never reachable off-box.
cat > /etc/mongod.conf <<'CONF1'
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true
net:
  port: 27017
  bindIp: 127.0.0.1
CONF1

systemctl enable mongod
systemctl restart mongod

for i in $(seq 1 30); do
  mongosh --quiet --eval 'db.runCommand({ping:1})' >/dev/null 2>&1 && break
  sleep 2
done

# X.509 subjects, not passwords. Teleport presents a client certificate whose
# CN is the db user, so the user is created in $external and there is no
# password anywhere — same model as the postgres and mysql scripts.
mongosh --quiet <<'JSINIT'
const ext = db.getSiblingDB("$external");
function ensure(cn, roles) {
  try { ext.runCommand({ createUser: cn, roles: roles }); }
  catch (e) { if (e.codeName !== "DuplicateKey" && e.code !== 51003) throw e; }
}
ensure("reader", [{ role: "read", db: "demo" }]);
ensure("writer", [{ role: "readWrite", db: "demo" }]);
JSINIT

# Seed something to read, so the demo shows data rather than an empty cursor.
mongosh --quiet demo --eval 'db.services.insertMany([{name:"analytics",tier:"gold"},{name:"billing",tier:"silver"}])' >/dev/null 2>&1 || true

# ---- Phase 2: TLS + x509 auth ------------------------------------------------
systemctl stop mongod

cat > /etc/mongod.conf <<CONF2
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true
net:
  port: 27017
  # Loopback ONLY. The Teleport agent shares this container and reaches the
  # engine here, so the engine is never exposed to the LAN at all.
  bindIp: 127.0.0.1
  tls:
    mode: requireTLS
    certificateKeyFile: $CERTS/server.pem
    CAFile: $CERTS/teleport-db-client.cas
    # The agent connects to 127.0.0.1, which will not match the cert's SAN.
    # Hostname checking is therefore off here and the trust decision rests on
    # the client certificate chain instead.
    allowConnectionsWithoutCertificates: false
security:
  authorization: enabled
  clusterAuthMode: x509
setParameter:
  authenticationMechanisms: MONGODB-X509
CONF2

systemctl restart mongod
sleep 5
systemctl is-active mongod

# ---- Teleport agent ----------------------------------------------------------
#
# THIS SECTION WAS MISSING from the first version of this script and the
# omission is worth recording: mongod came up correctly with requireTLS, the
# terraform apply reported success, the plan was clean, and the database was
# unreachable because no agent existed on the host at all. `systemctl is-active
# teleport` returned `inactive` with no unit, no config and no logs. Porting the
# ENGINE half of a provisioning script is half the job.
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


echo "mongodb provisioned (x509, loopback, TLS required) and agent started"
