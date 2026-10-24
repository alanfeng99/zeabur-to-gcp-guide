# One VM that runs an app's docker-compose stack, plus everything around it that
# a managed platform used to provide: private networking with a fixed egress IP,
# IAP-only SSH, daily disk snapshots, buckets for database dumps and uploads, an
# image registry, secrets and a budget alert.
#
# Two ingress modes (var.public_https):
#   off (default)  no external IP, no firewall rule beyond IAP SSH; public traffic
#                  arrives through an outbound tunnel (cloudflared) in the compose
#                  stack, and outbound calls leave through Cloud NAT.
#   on             the reserved address is attached to the VM itself and 80/443
#                  are open to the internet; outbound calls use the same address.

locals {
  services = [
    "artifactregistry.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudbuild.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "oslogin.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ]
  labels = merge({ app = var.name, managed-by = "terraform" }, var.labels)
}

resource "google_project_service" "this" {
  for_each           = toset(local.services)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# --- Network -----------------------------------------------------------------

resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.this]
}

resource "google_compute_subnetwork" "main" {
  project                  = var.project_id
  name                     = "${var.name}-${var.region}"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

# IAP's TCP-forwarding range is the only ingress source allowed, and only for SSH.
resource "google_compute_firewall" "iap_ssh" {
  project       = var.project_id
  name          = "${var.name}-allow-iap-ssh"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["iap-ssh"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "public_https" {
  count         = var.public_https ? 1 : 0
  project       = var.project_id
  name          = "${var.name}-allow-https"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["public-https"]
  allow {
    protocol = "tcp"
    # 80 only to redirect to https.
    ports = ["80", "443"]
  }
}

# Cloud NAT exists only while the host has no address of its own; a VM with an
# external IP never uses it.
resource "google_compute_router" "main" {
  count   = var.public_https ? 0 : 1
  project = var.project_id
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

# The host's one public address, reserved so it never changes and a partner can
# allowlist it: Cloud NAT's address while the host is private, the VM's own
# address (inbound and outbound) once public_https is on.
resource "google_compute_address" "egress" {
  project      = var.project_id
  name         = "${var.name}-egress"
  region       = var.region
  address_type = "EXTERNAL"
  labels       = local.labels
  depends_on   = [google_project_service.this]
}

resource "google_compute_router_nat" "main" {
  count                              = var.public_https ? 0 : 1
  project                            = var.project_id
  name                               = "${var.name}-nat"
  region                             = var.region
  router                             = google_compute_router.main[0].name
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [google_compute_address.egress.self_link]
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.main.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- Identity ----------------------------------------------------------------

resource "google_service_account" "host" {
  project      = var.project_id
  account_id   = "${var.name}-host"
  display_name = "${var.name} compose host"
  depends_on   = [google_project_service.this]
}

resource "google_project_iam_member" "host" {
  for_each = toset(["roles/logging.logWriter", "roles/monitoring.metricWriter"])
  project  = var.project_id
  role     = each.value
  member   = google_service_account.host.member
}

# --- Images ------------------------------------------------------------------

resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = var.region
  repository_id = var.name
  format        = "DOCKER"
  labels        = local.labels

  # KEEP wins over DELETE: the newest 10 versions of each image always survive,
  # anything else older than 30 days goes.
  cleanup_policy_dry_run = false
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s"
    }
  }
  depends_on = [google_project_service.this]
}

resource "google_artifact_registry_repository_iam_member" "host_reader" {
  project    = var.project_id
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.host.member
}

# --- Image builds ------------------------------------------------------------

# Cloud Build runs as its own account: it can read the uploaded source and push
# images, and nothing else — in particular not the backups bucket or secrets.
resource "google_service_account" "build" {
  project      = var.project_id
  account_id   = "${var.name}-build"
  display_name = "${var.name} image builds"
  depends_on   = [google_project_service.this]
}

resource "google_project_iam_member" "build_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.build.member
}

resource "google_artifact_registry_repository_iam_member" "build_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.build.member
}

# Source tarballs uploaded by `gcloud builds submit`; only needed for the build.
resource "google_storage_bucket" "build" {
  project                     = var.project_id
  name                        = "${var.project_id}-build"
  location                    = upper(var.region)
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = local.labels
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }
  depends_on = [google_project_service.this]
}

resource "google_storage_bucket_iam_member" "build_source" {
  bucket = google_storage_bucket.build.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.build.member
}

# --- Secrets -----------------------------------------------------------------

resource "google_secret_manager_secret" "this" {
  for_each  = toset(var.secret_ids)
  project   = var.project_id
  secret_id = each.value
  labels    = local.labels
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  depends_on = [google_project_service.this]

  # Destroying a secret destroys every version. Without the encryption key, every
  # encrypted column and every backup becomes unreadable; keep an offline copy too.
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_iam_member" "host_accessor" {
  for_each  = google_secret_manager_secret.this
  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.host.member
}

# --- Buckets -----------------------------------------------------------------

# Database dumps. The host may only create objects — it cannot read, overwrite
# or delete earlier dumps, so a compromised VM cannot destroy its own backups.
resource "google_storage_bucket" "backups" {
  project                     = var.project_id
  name                        = "${var.project_id}-backups"
  location                    = upper(var.region)
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = local.labels
  lifecycle_rule {
    condition {
      age = var.backup_retention_days
    }
    action {
      type = "Delete"
    }
  }
  depends_on = [google_project_service.this]
}

resource "google_storage_bucket_iam_member" "host_backups" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectCreator"
  member = google_service_account.host.member
}

# Application uploads, if the app stores objects in GCS rather than on the VM.
resource "google_storage_bucket" "assets" {
  project                     = var.project_id
  name                        = "${var.project_id}-assets"
  location                    = upper(var.region)
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = local.labels
  depends_on                  = [google_project_service.this]
}

resource "google_storage_bucket_iam_member" "host_assets" {
  bucket = google_storage_bucket.assets.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.host.member
}

# The identity behind the app's S3-compatible (HMAC) key for the assets bucket.
# Its own account with access to that one bucket only, so a leaked HMAC key
# cannot reach the backups. The key is created outside Terraform
# (scripts/init-secrets.sh) so its secret never lands in state.
resource "google_service_account" "assets" {
  project      = var.project_id
  account_id   = "${var.name}-assets"
  display_name = "${var.name} app storage (HMAC)"
  depends_on   = [google_project_service.this]
}

resource "google_storage_bucket_iam_member" "assets_hmac" {
  bucket = google_storage_bucket.assets.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.assets.member
}

# --- Host --------------------------------------------------------------------

resource "google_compute_disk" "data" {
  project = var.project_id
  name    = "${var.name}-data"
  zone    = var.zone
  type    = var.data_disk_type
  size    = var.data_disk_gb
  labels  = local.labels

  # Holds the database. A separate resource, so the VM can be replaced without
  # touching it; prevent_destroy makes any plan that would delete it fail.
  lifecycle {
    prevent_destroy = true
  }
  depends_on = [google_project_service.this]
}

resource "google_compute_resource_policy" "daily_snapshots" {
  project = var.project_id
  name    = "${var.name}-daily-snapshots"
  region  = var.region
  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = var.snapshot_start_time_utc
      }
    }
    retention_policy {
      max_retention_days    = var.snapshot_retention_days
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
    snapshot_properties {
      # Default would be the multi-region "asia"; keep copies in-country.
      storage_locations = [var.region]
      labels            = local.labels
    }
  }
  depends_on = [google_project_service.this]
}

resource "google_compute_disk_resource_policy_attachment" "data" {
  project = var.project_id
  name    = google_compute_resource_policy.daily_snapshots.name
  disk    = google_compute_disk.data.name
  zone    = var.zone
}

resource "google_compute_instance" "host" {
  project                   = var.project_id
  name                      = "${var.name}-host"
  zone                      = var.zone
  machine_type              = var.machine_type
  tags                      = var.public_https ? ["iap-ssh", "public-https"] : ["iap-ssh"]
  labels                    = local.labels
  deletion_protection       = var.deletion_protection
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image  = "debian-cloud/debian-12"
      size   = var.boot_disk_gb
      type   = "pd-balanced"
      labels = local.labels
    }
  }

  attached_disk {
    source      = google_compute_disk.data.id
    device_name = "data"
  }

  # Without access_config there is no external IP and outbound goes through
  # Cloud NAT; with it, the reserved address belongs to the VM.
  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    dynamic "access_config" {
      for_each = var.public_https ? [1] : []
      content {
        nat_ip = google_compute_address.egress.address
      }
    }
  }

  service_account {
    email  = google_service_account.host.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # `startup-script` under metadata updates in place; the top-level
  # metadata_startup_script argument would replace the VM on every edit.
  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    startup-script = templatefile("${path.module}/startup.sh.tftpl", {
      ar_host = "${var.region}-docker.pkg.dev"
      swap_gb = var.swap_gb
    })
  }

  lifecycle {
    # The image family resolves to whatever Debian 12 build is current; a newer
    # build must not force a replacement of a running host.
    ignore_changes = [boot_disk[0].initialize_params[0].image]
  }

  depends_on = [
    google_compute_router_nat.main,
    google_project_iam_member.host,
  ]
}

# --- Budget ------------------------------------------------------------------

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_billing_budget" "monthly" {
  count           = var.budget_amount > 0 ? 1 : 0
  billing_account = var.billing_account
  display_name    = "${var.name} monthly"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }

  amount {
    specified_amount {
      currency_code = var.budget_currency
      units         = tostring(var.budget_amount)
    }
  }

  # Alerts go to the billing account's admins by email.
  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }
  depends_on = [google_project_service.this]
}
