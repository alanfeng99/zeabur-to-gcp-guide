terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
  # Created by ../../bootstrap.sh before the first `init`. A backend block cannot
  # read variables: replace <project-id> by hand.
  backend "gcs" {
    bucket = "<project-id>-tfstate"
    prefix = "prod"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
  # Bill API quota (budgets, IAM) to this project rather than to whatever
  # project the caller's credentials happen to default to.
  user_project_override = true
  billing_project       = var.project_id
}

module "host" {
  source = "../../modules/compose-host"

  project_id      = var.project_id
  name            = var.name
  region          = var.region
  zone            = var.zone
  labels          = { env = "prod" }
  machine_type    = var.machine_type
  data_disk_gb    = var.data_disk_gb
  billing_account = var.billing_account
  budget_amount   = var.budget_amount
  budget_currency = var.budget_currency

  # Public sites served straight from the VM (Traefik terminates TLS). Cloudflare's
  # free plan can route some ISPs through far-away edges, so only the admin goes
  # through a Cloudflare tunnel + Access. Set false for tunnel-only ingress.
  public_https = true

  secret_ids = [
    # The app's environment (everything except the key below), incl. POSTGRES_PASSWORD
    # and the GCS S3-compatible credentials.
    "app-env",
    # Kept apart from app-env: losing or changing it makes every encrypted column
    # and every database backup unreadable.
    "encryption-key",
    # Token of the cloudflared tunnel that carries admin traffic (behind Access).
    "cloudflared-tunnel-token",
  ]
}
