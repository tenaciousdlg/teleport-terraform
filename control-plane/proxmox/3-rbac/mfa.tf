##################################################################################
# PER-SESSION MFA — built 2026-09-28
##################################################################################
#
# WHAT WAS ALREADY DONE, verified live before writing any of this:
#
#   * `second_factors` on the cluster auth preference already contains `sso`
#     alongside `webauthn` and `otp`.
#   * The `okta` SAML connector already has an `mfa` block, `enabled: true`,
#     pointing at a SECOND, SEPARATE Okta app
#     (`integrator-…_teleportheronwrightmfa_1`, entity id `exk183e21ev6…`),
#     which is the part the docs insist on and the part that is easy to get
#     wrong by reusing the login app.
#   * `force_authn` is ABSENT from that block, and that is CORRECT. The doc
#     states the default is "yes", so re-authentication is always required. An
#     earlier note in CLAUDE.md implied it had to be set explicitly; the doc
#     settled it. Setting `force_authn: false` is what would let the IdP reuse
#     an existing session and satisfy the MFA check without prompting anyone.
#
# So the only thing missing was a role anyone actually holds. `prod-access-mfa`
# already carries the requirement but is request-only, so nothing in the
# standing set ever prompted.
#
# ── WHY A LABEL AND NOT A BLANKET SETTING ────────────────────────────────────
#
# `require_session_mfa` combines as a LOGICAL OR across a user's roles --
# "evaluates to yes if at least one role requires session MFA". That is
# explicitly different from `max_session_ttl` and `client_idle_timeout`, which
# take the most restrictive value. Confirmed in the roles reference, because the
# whole design depends on it.
#
# That OR is what makes this safe. A role matching ONLY labelled resources adds
# the requirement for those resources and changes nothing else. Setting
# `require_session_mfa` on the cluster auth preference instead would have made
# every session prompt, including the break-glass path and anything a machine
# identity reaches, which on an SSO-only cluster is how you lock yourself out of
# your own estate.
#
# NOTHING CARRIES THIS LABEL YET, DELIBERATELY. Applying this changes no access
# whatsoever. The demo switch is one command against one resource, and it is
# reversible the same way:
#
#   tctl update rn/<node> --set-labels teleport.dev/mfa=required   # arm
#   tctl update rn/<node> --set-labels teleport.dev/mfa=           # disarm
#
# ── NODE ONLY, ON PURPOSE ────────────────────────────────────────────────────
#
# `db_labels` is NOT here, and that restraint is deliberate rather than an
# oversight. The database RBAC reference does NOT state whether `db_users` and
# `db_names` combine ACROSS a user's roles or must both come from the one
# matching role. Under the stricter reading, a role that matches a database by
# label while granting no `db_users` could NARROW what that session is offered
# rather than just adding an MFA requirement. Adding a gate must not be able to
# remove access, so databases wait until that is tested against a real
# connection. Same for apps and Kubernetes.
resource "teleport_role" "mfa_required" {
  version = "v7"

  metadata = {
    name        = "mfa-required"
    description = "IAC: per-session MFA for resources labelled teleport.dev/mfa=required"
    labels = {
      "teleport.dev/origin" = "dynamic"
    }
  }

  spec = {
    allow = {
      # Self-sufficient for SSH rather than a bare label matcher: the login
      # template that ACTUALLY RESOLVES on this cluster. `external.username` is
      # the only identity trait the SSO users carry -- there is no `email`
      # trait at all, so `{{email.local(external.email)}}` renders empty here.
      logins = ["{{email.local(external.username)}}"]

      node_labels = {
        "teleport.dev/mfa" = ["required"]
      }
    }

    options = {
      # 1 = SESSION. READ THE SCHEMA, NOT THE DOC PROSE: this field is a
      # NUMBER in the provider (`RequireMFAType`), not the boolean the
      # documentation's YAML shows. 0 OFF, 1 SESSION, 2 SESSION_AND_HARDWARE_KEY,
      # 3 HARDWARE_KEY_TOUCH, 4 HARDWARE_KEY_PIN, 5 HARDWARE_KEY_TOUCH_AND_PIN.
      #
      # ONLY 1 IS CORRECT HERE, and the reason is the whole point of SSO MFA:
      # values 2 through 5 demand a PIV hardware key, which an Okta Verify push
      # cannot satisfy. Choosing any of them would read as a lockout rather
      # than a prompt -- the same failure mode as putting `require_session_mfa`
      # on an SSO user with no Teleport-registered device.
      require_session_mfa = 1

      # THE DEMO LEVER, and it is the difference between a demo that shows
      # something and one that shows it once.
      #
      # `tsh proxy kube` and `tsh proxy db --tunnel` take ONE MFA check and
      # then reuse it; bare `kubectl` prompts per command. This interval caps
      # how long a single check stays good for those proxy derivatives. It
      # DEFAULTS TO max_session_ttl, which is 8h on most roles here, so
      # without it an audience sees exactly one tap and nothing after.
      #
      # 2m is short enough to re-prompt inside a demo and long enough not to
      # interrupt a sentence. Note the separate 5-minute ceiling on how long an
      # MFA check remains valid generally -- this only tightens, never extends.
      mfa_verification_interval = "2m"

      # Deliberately short. A session that needed a fresh IdP challenge to
      # start should not outlive the reason for it by a working day.
      max_session_ttl = "1h0m0s"
    }
  }
}
