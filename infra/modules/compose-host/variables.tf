variable "project_id" {
  description = "GCP project that hosts everything below."
  type        = string
}

variable "name" {
  description = "Short prefix for resource names (lowercase, digits, hyphens). Buckets are prefixed with project_id instead."
  type        = string

  validation {
    # Service account IDs ("<name>-assets") are capped at 30 characters
    condition     = can(regex("^[a-z]([a-z0-9-]{0,21}[a-z0-9])?$", var.name))
    error_message = "name: 1-23 characters, lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "region" {
  description = "Region for the VM, disks, snapshots, buckets, secrets and images. Keep personal data in-country."
  type        = string
  default     = "asia-east1"
}

variable "zone" {
  description = "Zone for the VM and its data disk. Must lie inside region, where the subnet is."
  type        = string
  default     = "asia-east1-b"
}

variable "labels" {
  description = "Labels applied to every resource that supports them."
  type        = map(string)
  default     = {}
}

variable "subnet_cidr" {
  description = "Primary range of the host's subnet."
  type        = string
  default     = "10.10.0.0/24"
}

variable "public_https" {
  description = "Attach the reserved address to the VM and open 80/443 to the internet (the compose stack then terminates TLS itself). Off: no external IP; ingress only through a tunnel, egress through Cloud NAT. To switch it on for a running host, first apply only the NAT removal (-target=<module>.google_compute_router_nat.main and .google_compute_router.main) so the address is free, then apply the rest."
  type        = bool
  default     = false
}

variable "machine_type" {
  description = "VM size. e2-medium (2 shared vCPU / 4 GB) fits Postgres + Redis + a few Node services; image builds must not run here."
  type        = string
  default     = "e2-medium"
}

variable "boot_disk_gb" {
  description = "Boot disk size. Holds the OS and Docker images only — data lives on the separate data disk."
  type        = number
  default     = 20
}

variable "data_disk_gb" {
  description = "Persistent data disk mounted at /srv (database files, Redis AOF, uploaded objects if stored locally)."
  type        = number
  default     = 30
}

variable "data_disk_type" {
  description = "Data disk type."
  type        = string
  default     = "pd-balanced"
}

variable "swap_gb" {
  description = "Swap file size on the boot disk, as headroom against memory spikes."
  type        = number
  default     = 2
}

variable "deletion_protection" {
  description = "Refuse to delete the VM through the API (Terraform included) until this is switched off."
  type        = bool
  default     = true
}

variable "snapshot_start_time_utc" {
  description = "Daily snapshot start time of the data disk, UTC HH:00. 18:00 UTC = 02:00 Taiwan."
  type        = string
  default     = "18:00"
}

variable "snapshot_retention_days" {
  description = "How many days of daily data-disk snapshots to keep."
  type        = number
  default     = 14
}

variable "backup_retention_days" {
  description = "Age after which objects in the backups bucket (database dumps) are deleted."
  type        = number
  default     = 90
}

variable "secret_ids" {
  description = "Secret Manager secrets to create (containers only — values are added out of band so they never land in Terraform state). The host's service account can read each one."
  type        = list(string)
  default     = []
}

variable "billing_account" {
  description = "Billing account ID the budget is attached to."
  type        = string
}

variable "budget_amount" {
  description = "Monthly budget in budget_currency units. 0 disables the budget."
  type        = number
  default     = 0
}

variable "budget_currency" {
  description = "Must equal the billing account's currency (e.g. TWD, USD)."
  type        = string
  default     = "USD"
}
