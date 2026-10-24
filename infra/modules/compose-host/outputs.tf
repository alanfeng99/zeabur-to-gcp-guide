output "host_name" {
  value = google_compute_instance.host.name
}

output "host_zone" {
  value = google_compute_instance.host.zone
}

output "host_internal_ip" {
  value = google_compute_instance.host.network_interface[0].network_ip
}

output "host_service_account" {
  value = google_service_account.host.email
}

output "egress_ip" {
  description = "Every outbound request from the host comes from this address — give it to partners that allowlist IPs. With public_https it is also the address DNS points at."
  value       = google_compute_address.egress.address
}

output "image_repository" {
  description = "Docker image prefix, e.g. <this>/api:<tag>."
  value       = "${google_artifact_registry_repository.images.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "backups_bucket" {
  value = google_storage_bucket.backups.name
}

output "assets_bucket" {
  value = google_storage_bucket.assets.name
}

output "build_service_account" {
  value = google_service_account.build.email
}

output "build_bucket" {
  description = "Staging bucket for `gcloud builds submit` source uploads."
  value       = google_storage_bucket.build.name
}

output "secret_ids" {
  value = [for s in google_secret_manager_secret.this : s.secret_id]
}

output "ssh_command" {
  value = "gcloud compute ssh ${google_compute_instance.host.name} --project ${var.project_id} --zone ${var.zone} --tunnel-through-iap"
}

output "assets_service_account" {
  description = "Owner of the app's HMAC key for the assets bucket (scripts/init-secrets.sh creates the key)."
  value       = google_service_account.assets.email
}
