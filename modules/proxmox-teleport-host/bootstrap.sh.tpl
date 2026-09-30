#!/usr/bin/env bash
# Runs INSIDE the container, once, to get Teleport onto it.
# Delivered with `pct push` and then executed — never piped to `pct exec`
# stdin, which is the same trap as `tctl -f /dev/stdin` against a distroless pod.
set -euo pipefail

# PATH IS THE FIRST THING, and it is not decoration. `pct exec` runs with a
# minimal PATH that does NOT include /usr/local/bin, which is exactly where the
# Teleport package puts its symlinks. Without this line `tbot keypair create`
# below dies with "command not found" AFTER a successful install, so the
# install looks fine and the join silently never gets a key. That trap is
# recorded in ~/github/CLAUDE.md and this script hit it anyway on first run.
export PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# `sudo` is NOT optional and its absence is near-undebuggable. Teleport's host
# user creation hard-requires `visudo`, and without it the agent logs
# "Skipping host user management ... missing required binaries: visudo" at DEBUG
# severity ONLY, then every session dies with "unknown user X" no matter how
# correct the roles are. That cost a long diagnosis on CT104.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates sudo locales

# en_US.UTF-8, because that is what an SSH client on a Mac sends in LANG, and
# the Debian template ships only C, C.utf8 and POSIX. Without it every login
# prints a screen of `setlocale: LC_CTYPE: cannot change locale` warnings.
# Found 2026-09-29 on all five hosts built from this module. Written to
# /etc/locale.gen and the on-disk archive, so it survives a reboot; the grep
# makes a re-run a no-op.
if ! locale -a 2>/dev/null | grep -qx 'en_US.utf8'; then
  sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
  grep -qx 'en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
  locale-gen
fi

if ! command -v teleport >/dev/null 2>&1; then
  curl -fsSL https://cdn.teleport.dev/install.sh | bash -s "${teleport_version}" enterprise
fi

# The bound keypair. The PRIVATE half is generated HERE and never leaves, which
# is why the token can carry only the public half and terraform state holds no
# secret. Run without --overwrite so re-running is safe and reprints the
# existing key rather than minting a new one that the token does not know.
install -d -m 0700 "$(dirname ${static_key_path})"

# `tbot keypair create --static` writes ONLY the private key and PRINTS the
# public half to stdout. There is no .pub file, and assuming one is why the
# first version of this script failed after generating the key perfectly well.
#
# It is idempotent WITHOUT --overwrite: on a second run it logs "An existing
# static key was found at the given path and will be printed" and reprints the
# same key. So this always runs and always parses, rather than branching on
# whether the file exists.
#
# It also PINGS THE PROXY to determine the signature algorithm suite, so
# ${proxy_address} must resolve and be reachable from here or this never gets
# as far as writing a key.
KEY_OUT=$(tbot keypair create \
  --proxy-server ${proxy_address}:443 \
  --static \
  --static-key-path "${static_key_path}" 2>&1)

PUBKEY=$(printf '%s\n' "$KEY_OUT" | grep -oE 'ssh-[a-z0-9]+ [A-Za-z0-9+/=]+' | head -1)
if [ -z "$PUBKEY" ]; then
  echo "FAILED to obtain a public key. Full output follows:" >&2
  printf '%s\n' "$KEY_OUT" >&2
  exit 1
fi

echo "--- PUBLIC KEY (put this in the layer's initial_public_key) ---"
echo "$PUBKEY"
echo "---------------------------------------------------------------"
