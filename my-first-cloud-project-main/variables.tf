variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The GCP region"
  type        = string
  default     = "me-central1"
}

variable "zone" {
  type    = string
  default = "me-central1-a"
}