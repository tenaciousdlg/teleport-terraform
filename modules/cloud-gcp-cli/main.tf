# Google Cloud CLI access via Teleport App Access.
#
# Deploys the documented pattern (docs: enroll-resources/application-access/
# cloud-apis/google-cloud/): an app agent on a GCE VM holding a controlling
# service account that impersonates a target (viewer) account users assume
# with `tsh apps login google-cloud-cli --gcp-service-account teleport-vm-viewer`.
#
# The agent joins with the native `gcp` join method — identity attested by
# GCE, NO join secret, NO token TTL. This deliberately avoids the 8h-token +
# ignore_changes pattern that left replacement instances unable to join
# (bit us 2026-08-27).

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    teleport = {
      source  = "terraform.releases.teleport.dev/gravitational/teleport"
      version = "~> 18.0"
    }
  }
}

resource "google_service_account" "agent" {
  project      = var.project_id
  account_id   = "teleport-google-cloud-cli"
  display_name = "Teleport app agent (controlling account)"
}

resource "google_service_account" "viewer" {
  project      = var.project_id
  account_id   = "teleport-vm-viewer"
  display_name = "Teleport demo target (project viewer)"
}

resource "google_project_iam_member" "viewer" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.viewer.email}"
}

resource "google_service_account_iam_member" "impersonate" {
  service_account_id = google_service_account.viewer.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.agent.email}"
}

# Allow-rule token: joining is authorized by GCE-attested identity (project +
# service account), not a shared secret. Static — nothing to expire or leak.
resource "teleport_provision_token" "gcp_join" {
  version = "v2"
  metadata = {
    name        = "gcp-cli-join"
    description = "gcp join method for the google-cloud-cli app agent"
  }
  spec = {
    roles       = ["App"]
    join_method = "gcp"
    gcp = {
      allow = [{
        project_ids      = [var.project_id]
        service_accounts = [google_service_account.agent.email]
      }]
    }
  }
}

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

resource "google_compute_instance" "agent" {
  project      = var.project_id
  name         = "teleport-gcp-cli"
  zone         = var.zone
  machine_type = var.machine_type
  labels       = { owner = "dlg", purpose = "teleport-demo" }

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
    }
  }

  network_interface {
    network = "default"
    access_config {} # ephemeral external IP — default VPC has no Cloud NAT
  }

  service_account {
    email  = google_service_account.agent.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    startup-script = templatefile("${path.module}/userdata.tpl", {
      proxy_address = var.proxy_address
      token_name    = teleport_provision_token.gcp_join.metadata.name
      env           = var.env
      team          = var.team
    })
  }

  depends_on = [google_service_account_iam_member.impersonate]
}
