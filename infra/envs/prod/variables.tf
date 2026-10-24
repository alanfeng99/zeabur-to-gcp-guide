variable "project_id" {
  description = "GCP project ID (created by bootstrap.sh)."
  type        = string
}

variable "billing_account" {
  description = "Billing account ID, e.g. 0X0X0X-0X0X0X-0X0X0X."
  type        = string
}

variable "name" {
  description = "Short prefix for resource names: lowercase letters, digits, hyphens."
  type        = string
}

variable "region" {
  type    = string
  default = "asia-east1"
}

variable "zone" {
  type    = string
  default = "asia-east1-b"
}

variable "machine_type" {
  description = "e2-medium (2 shared vCPU, 4 GB) fits Postgres + Redis + a few Node services."
  type        = string
  default     = "e2-medium"
}

variable "data_disk_gb" {
  description = "Data disk mounted at /srv: database files, Redis AOF."
  type        = number
  default     = 30
}

variable "budget_amount" {
  description = "Monthly budget alert in budget_currency. 0 disables it."
  type        = number
  default     = 0
}

variable "budget_currency" {
  description = "Must equal the billing account's currency (e.g. USD, TWD)."
  type        = string
  default     = "USD"
}
