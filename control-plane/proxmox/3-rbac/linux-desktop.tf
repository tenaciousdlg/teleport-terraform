##################################################################################
# LINUX DESKTOP ACCESS
##################################################################################
#
# The desktop itself lives in data-plane/desktop-access-linux-proxmox
# (dev-linux-desktop, CT113). Added 2026-09-29.
#
# A PROVIDER RESOURCE, not an operator CR, per the estate default for new
# Teleport-native resources. Verified against `terraform providers schema
# -json` at 18.11.1: linux_desktop_labels is map(list(string)) and
# linux_desktop_logins is list(string).
#
# PER-PERSON. `{{email.local(external.username)}}` is each SSO user's own
# login (`sam@example.com` -> `sam`), the same template every SSH role here
# uses, and it renders because these users carry a `username` trait.
# A shared literal list would hand everyone everyone's desktop and destroy
# attribution at the OS layer, exactly as it did on homelab-ssh.
#
# THE LOGIN MUST ALREADY EXIST ON THE HOST, and nothing in this role creates
# it. The Linux Desktop Service calls hostuser.Lookup(login) at session start
# and fails if it is missing (18.11.0, lib/srv/desktop/x11/xsession.go). So
# each person SSHes to dev-linux-desktop once, which creates their user under
# create_host_user_mode = keep from the SSH roles that already match env=dev,
# and then opens the desktop.
#
# Scoped like platform-dev-access (env=dev, any team) and granted only through
# the `homelab` access list, so it reaches the estate's own people and no one
# else. Access-list grants are baked in at LOGIN: `tsh logout && tsh login`
# (or sign out of the Web UI) before the desktop appears.
resource "teleport_role" "linux_desktop_access" {
  version = "v7"
  metadata = {
    name        = "linux-desktop-access"
    description = "IAC: per-person Linux desktop access to env=dev desktops"
  }
  spec = {
    allow = {
      linux_desktop_labels = {
        env  = ["dev"]
        team = ["*"]
      }
      linux_desktop_logins = ["{{email.local(external.username)}}"]
    }
  }
}
