##################################################################################
# CONFIGURATION - Terraform
##################################################################################
terraform {
  # State in S3 in the SE AWS account (bucket made 2026-10-13: versioned,
  # SSE-S3, public access blocked). Credentials come from the shell's
  # AWS_PROFILE (the SSO profile); no profile is named here because its name
  # carries the account ID and this repo is public.
  backend "s3" {
    bucket       = "dlg-dlgdemo-teleport-terraform-state"
    key          = "control-plane/cloud/2-teleport/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
  required_providers {
    teleport = {
      source  = "terraform.releases.teleport.dev/gravitational/teleport"
      version = "~> 18.0" # Update major version here when upgrading (Terraform requires a static string)
    }
  }
}

##################################################################################
# PROVIDERS
##################################################################################
provider "teleport" {
  addr = "${var.proxy_address}:443"
}

##################################################################################
# SAML CONNECTOR
##################################################################################

resource "teleport_saml_connector" "okta" {
  version = "v2"

  metadata = {
    name = "okta"
  }

  spec = {
    attributes_to_roles = [
      # All authenticated users -> base-user. terraform-provider was added by
      # hand on the live tenant after Nov 2025 and is adopted here; dropping
      # it would remove the role SSO users run the Terraform provider with.
      {
        name  = "groups"
        value = "Everyone"
        roles = ["base-user", "terraform-provider"]
      },
      # Admins/security also get reviewer powers.
      {
        name  = "groups"
        value = "security-team"
        roles = ["base-user", "access-reviewer", "terraform-provider"]
      }
      # No direct mapping to dev/prod env roles here: those are granted only
      # through the Access Lists in 3-rbac.
    ]

    acs                     = "https://${var.proxy_address}/v1/webapi/saml/acs/okta"
    entity_descriptor_url   = var.okta_metadata_url
    service_provider_issuer = "https://${var.proxy_address}/v1/webapi/saml/acs/okta"
  }
}

##################################################################################
# AUTH PREFERENCE
##################################################################################

resource "teleport_auth_preference" "main" {
  depends_on = [teleport_saml_connector.okta]

  version = "v2"

  metadata = {
    description = "auth preference"
    labels = {
      name                  = "cluster-auth-preference"
      "teleport.dev/origin" = "dynamic"
    }
  }

  spec = {
    type          = "saml"
    second_factor = "on" # allow OTP and WebAuthn

    webauthn = {
      rp_id = var.proxy_address
    }

    connector_name     = teleport_saml_connector.okta.metadata.name
    allow_local_auth   = true
    allow_passwordless = true
  }
}

##################################################################################
# RBAC RESOURCES LIVE IN 3-rbac
##################################################################################
