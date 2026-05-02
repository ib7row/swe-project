// Output the names of the created resources for easy reference
output "publisher_vm_name" {
  value = google_compute_instance.publisher_vm.name
}

output "receiver_vm_name" {
  value = google_compute_instance.receiver_vm.name
}

output "topic_name" {
  value = google_pubsub_topic.topic.name
}

output "subscription_name" {
  value = google_pubsub_subscription.subscription.name
}

output "workload_identity_provider_name" {
  description = "The exact string needed for GitHub Actions YAML"
  value       = google_iam_workload_identity_pool_provider.github_provider.name
}