#!/usr/bin/env bash
# Export this layer's Slack plugin credentials from the local demo Vault.
# SOURCE it, don't run it:
#
#   . ./vault-env.sh && terraform apply -var-file=heronwright.tfvars
#
# WHY THIS EXISTS. slack_bot_token and slack_channel_id are required with no
# defaults, so without them the layer stops with "No value for required
# variable" and the obvious way out is to paste a bot token onto a command
# line, where it lands in shell history. This is the other channel, and it is
# the same shape as the loaders in ~/github/okta, ~/github/homelab/unifi and
# ~/github/homelab/proxmox.
#
# The channel id is not secret; it is read from the same entry purely so that
# one command sets up the whole layer and neither value has to be remembered.
#
# SOURCE, DO NOT PIPE. A pipeline runs the left side in a subshell, so the
# exports are lost while the success message still prints, and the failure then
# reads as a credential problem. Each Bash tool call is also a fresh shell, so
# the source and the terraform command must be in the SAME invocation.
#
# NO `set -u` HERE. A sourced script's shell options persist in the caller's
# interactive shell; `set -u` in a sibling loader leaked into an interactive
# zsh on 2026-09-27 and broke a terraform wrapper and a p10k prompt.
#
# NOTE ON PRECEDENCE: `-var-file` BEATS `TF_VAR_` env. Neither value is pinned
# in heronwright.tfvars, deliberately. If either is ever added there, these
# exports stop having any effect and the apply reports success using the stale
# value.

: "${VAULT_ADDR:=http://127.0.0.1:8200}"
export VAULT_ADDR

_sl_die() { printf 'slack-env: %s\n' "$1" >&2; return 1; }

if ! command -v vault >/dev/null 2>&1; then
  _sl_die "vault not on PATH"
elif ! vault status >/dev/null 2>&1; then
  _sl_die "vault at $VAULT_ADDR is unreachable or sealed — unseal it (key in 1Password, the WORK account, not the personal one)"
else
  _sl_token=$(vault kv get -field=token secret/demo/slack-bot 2>/dev/null)
  _sl_chan=$(vault kv get -field=channel_id secret/demo/slack-bot 2>/dev/null)

  if [ -z "${_sl_token:-}" ]; then
    _sl_die "no token at secret/demo/slack-bot — seed it with: vault kv put secret/demo/slack-bot token=xoxb-... channel_id=C..."
  else
    export TF_VAR_slack_bot_token="$_sl_token"
    export TF_VAR_slack_channel_id="${_sl_chan:-}"
    # Length only for the token. Echoing it would put it in shell history and
    # in any scrollback that gets shared, which is what this file prevents.
    printf 'slack-env: TF_VAR_slack_bot_token set from secret/demo/slack-bot (%s chars), channel %s\n' \
      "${#_sl_token}" "${_sl_chan:-<unset>}"
  fi
  unset _sl_token _sl_chan
fi

unset -f _sl_die 2>/dev/null || true
