output "host_name" {
  value = module.host.host_name
}

output "host_zone" {
  value = module.host.host_zone
}

output "host_internal_ip" {
  value = module.host.host_internal_ip
}

output "host_service_account" {
  value = module.host.host_service_account
}

output "egress_ip" {
  description = "The VM's fixed address: DNS A records point here, and partners with IP allowlists need it."
  value       = module.host.egress_ip
}

output "image_repository" {
  value = module.host.image_repository
}

output "backups_bucket" {
  value = module.host.backups_bucket
}

output "assets_bucket" {
  value = module.host.assets_bucket
}

output "build_service_account" {
  value = module.host.build_service_account
}

output "build_bucket" {
  value = module.host.build_bucket
}

output "secret_ids" {
  value = module.host.secret_ids
}

output "ssh_command" {
  value = module.host.ssh_command
}

output "assets_service_account" {
  value = module.host.assets_service_account
}
