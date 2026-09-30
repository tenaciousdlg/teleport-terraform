#!/usr/bin/env bash
# Export this layer's two SAML metadata variables from the okta layer's
# outputs, picked by the current terraform WORKSPACE. SOURCE it, don't run it:
#
#   . ./idp-env.sh && terraform plan -var-file=heronwright.tfvars
#
# WHY THIS EXISTS, and it is not convenience. Until 2026-09-27 the tfvars told
# you to export these two by hand, and it named the second one
# `TF_VAR_saml_mfa_entity_descriptor_url`. **That variable does not exist.**
# The declared name is `saml_mfa_entity_descriptor` and it takes the metadata
# XML, not a URL, because `mfa.entity_descriptor_url` points at an Okta ADMIN
# API path that needs an SSWS token and fails with
# `failed to fetch or parse entity descriptor`, an auth failure that reads like
# bad XML. So following the instructions exactly exported a variable terraform
# ignores, left the real one at its "" default, and the next plan proposed to
# strip the `mfa` block off the LIVE SAML connector. That is how you silently
# turn off SSO MFA while reading a plan that looks like a rename.
#
# Nothing here is secret. Both values are public IdP metadata, which is why
# this reads from terraform outputs rather than from Vault like its siblings
# (okta/vault-env.sh, homelab/unifi/vault-env.sh, homelab/proxmox/vault-env.sh).
# They are kept out of the tfvars because they are GENERATED: 2.3 KB of XML
# that changes whenever the Okta app is touched, and pasting them in would
# drift silently.
#
# SOURCE, DO NOT PIPE. A pipeline runs the left side in a subshell, so the
# exports are lost while the success message still prints, and the failure then
# reads as a credential problem. Each Bash tool call is also a fresh shell, so
# the source and the terraform command must be in the SAME invocation.
#
# NO `set -u` HERE. A sourced script's shell options persist in the caller's
# interactive shell; `set -u` in the sibling loaders leaked into Chris's zsh on
# 2026-09-27 and broke his terraform wrapper and his p10k prompt.
#
# NOTE ON PRECEDENCE: `-var-file` BEATS `TF_VAR_` env. These two are
# deliberately absent from every .tfvars in this layer. If either is ever
# pinned in a var file, these exports stop having any effect and the apply
# reports success using the stale value.

# RETURN NON-ZERO ON FAILURE, or the `&&` in the usage line above protects
# nothing. Until 2026-09-29 `_idp_die` returned 1 but the script's last command
# was `unset`, so sourcing it always exited 0 and `. ./idp-env.sh && terraform
# plan` planned with the descriptors unset. The status is carried in _idp_rc
# and returned at the very end.
_idp_rc=0
_idp_die() { printf 'idp-env: %s\n' "$1" >&2; _idp_rc=1; }

_idp_ws=$(terraform workspace show 2>/dev/null)
_idp_okta="${OKTA_DIR:-$HOME/github/okta}"

# Workspace -> the okta layer's output PREFIX. The okta repo names its outputs
# per cluster (`heronwright_teleport_saml_metadata`, `chrisdlg_teleport_*`),
# so this is the one place the mapping lives.
case "${_idp_ws:-}" in
  heronwright) _idp_prefix="heronwright_teleport" ;;
  default)     _idp_prefix="chrisdlg_teleport" ;;
  *)           _idp_prefix="" ;;
esac

if [ -z "${_idp_ws:-}" ]; then
  _idp_die "not in a terraform layer, or terraform not initialised here"
elif [ -z "${_idp_prefix:-}" ]; then
  _idp_die "no okta output mapping for workspace '$_idp_ws' — add one to the case in this file"
elif [ ! -d "$_idp_okta" ]; then
  _idp_die "okta layer not found at $_idp_okta (override with OKTA_DIR)"
else
  # KEEP terraform's stderr and show it. Until 2026-09-29 both reads sent it to
  # /dev/null, so ANY failure became an empty string and the message below
  # blamed an unapplied okta layer. The actual failure that day was the
  # `.terraform` sweep: okta's provider plugin was gone, `terraform output`
  # said "Required plugins are not installed", and this layer then planned to
  # DESTROY the live SAML connector until prevent_destroy stopped it.
  _idp_saml_err=$(mktemp)
  _idp_mfa_err=$(mktemp)
  _idp_saml=$(terraform -chdir="$_idp_okta" output -no-color -raw "${_idp_prefix}_saml_metadata" 2>"$_idp_saml_err")
  _idp_mfa=$(terraform -chdir="$_idp_okta" output -no-color -raw "${_idp_prefix}_mfa_metadata" 2>"$_idp_mfa_err")

  if [ -z "${_idp_saml:-}" ]; then
    _idp_die "okta output ${_idp_prefix}_saml_metadata is empty. terraform said:
$(sed 's/^/    /' "$_idp_saml_err" | head -8)
  If that reads 'Required plugins are not installed', the layer IS applied and
  only needs: terraform -chdir=$_idp_okta init -input=false"
  else
    export TF_VAR_saml_entity_descriptor="$_idp_saml"
    printf 'idp-env: [%s] TF_VAR_saml_entity_descriptor from %s_saml_metadata (%s bytes)\n' \
      "$_idp_ws" "$_idp_prefix" "${#_idp_saml}"

    # The MFA app is a SECOND, SEPARATE Okta app sharing the login app's ACS
    # and audience. Not every cluster has one, so an empty value here is a
    # legitimate state (it omits the connector's `mfa` block). It is called
    # out loudly anyway, because an ACCIDENTAL empty is what removes SSO MFA.
    if [ -n "${_idp_mfa:-}" ]; then
      export TF_VAR_saml_mfa_entity_descriptor="$_idp_mfa"
      printf 'idp-env: [%s] TF_VAR_saml_mfa_entity_descriptor from %s_mfa_metadata (%s bytes)\n' \
        "$_idp_ws" "$_idp_prefix" "${#_idp_mfa}"
    else
      printf 'idp-env: [%s] NO %s_mfa_metadata output — the connector will be planned WITHOUT an mfa block.\n' \
        "$_idp_ws" "$_idp_prefix" >&2
      if [ -s "$_idp_mfa_err" ]; then
        printf 'idp-env: terraform said:\n' >&2
        sed 's/^/    /' "$_idp_mfa_err" | head -8 >&2
      fi
      printf 'idp-env: if this cluster is supposed to have SSO MFA, STOP and check the okta layer before applying.\n' >&2
    fi
  fi
fi

[ -n "${_idp_saml_err:-}" ] && rm -f "$_idp_saml_err"
[ -n "${_idp_mfa_err:-}" ] && rm -f "$_idp_mfa_err"
unset -f _idp_die
unset _idp_ws _idp_okta _idp_prefix _idp_saml _idp_mfa _idp_saml_err _idp_mfa_err
# eval expands $_idp_rc before the unset runs, so the status survives the
# cleanup. `return` from a sourced file works in both bash and zsh.
eval "unset _idp_rc; return $_idp_rc"
