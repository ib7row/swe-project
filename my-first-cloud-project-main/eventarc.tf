# ============================================================================
# eventarc.tf
# Provisions the full GCS → Eventarc → Cloud Run (Worker) pipeline.
#
# Architecture:
#   User uploads PNG → GCS raw-bucket
#     → Eventarc trigger (google.cloud.storage.object.v1.finalized)
#       → HTTP POST to Worker (Subscriber) Cloud Run service
#         → Worker converts PNG → JPG / PDF → GCS output-bucket
#
# 15-Factor compliance:
#   Factor 3  – All runtime config injected as env vars into Cloud Run services
#   Factor 6  – Services are stateless; all state lives in GCS
#   Factor 9  – Cloud Run handles SIGTERM; gunicorn --graceful-timeout drains jobs
#   Factor 11 – Cloud Run automatically ships stdout/stderr to Cloud Logging
# ============================================================================

# ── 1. Enable required APIs ──────────────────────────────────────────────────

resource "google_project_service" "eventarc_api" {
  service            = "eventarc.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "run_api" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "storage_api" {
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

# ── 2. GCS Buckets ───────────────────────────────────────────────────────────

resource "google_storage_bucket" "raw_uploads" {
  name                        = "${var.project_id}-raw-uploads"
  location                    = var.region
  force_destroy               = true   # allows `terraform destroy` to clean up
  uniform_bucket_level_access = true

  lifecycle_rule {
    condition { age = 7 }             # auto-delete raw files after 7 days
    action    { type = "Delete" }
  }
}

resource "google_storage_bucket" "converted_output" {
  name                        = "${var.project_id}-converted-output"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
}

# ── 3. Dedicated Service Account for Cloud Run services ──────────────────────
# Principle of least privilege — never use the default compute SA.

resource "google_service_account" "cloudrun_sa" {
  account_id   = "cloudrun-file-converter"
  display_name = "Cloud Run File Converter SA"
}

# Publisher (Ingestion): needs to write to raw bucket
resource "google_storage_bucket_iam_member" "publisher_write_raw" {
  bucket = google_storage_bucket.raw_uploads.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.cloudrun_sa.email}"
}

# Worker (Subscriber): needs to read raw bucket + write to output bucket
resource "google_storage_bucket_iam_member" "worker_read_raw" {
  bucket = google_storage_bucket.raw_uploads.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.cloudrun_sa.email}"
}

resource "google_storage_bucket_iam_member" "worker_write_output" {
  bucket = google_storage_bucket.converted_output.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.cloudrun_sa.email}"
}

# ── 4. Cloud Run — Ingestion Service (Publisher) ─────────────────────────────

resource "google_cloud_run_v2_service" "ingestion" {
  name     = "ingestion-service"
  location = var.region

  template {
    service_account = google_service_account.cloudrun_sa.email

    scaling {
      min_instance_count = 0   # scale to zero when idle (Factor 9: disposability)
      max_instance_count = 5
    }

    containers {
      # Image built and pushed by the CI/CD pipeline (Deploy.yml)
      image = "${var.region}-docker.pkg.dev/${var.project_id}/file-converter-repo/ingestion-service:latest"

      ports {
        container_port = 8080
      }

      # ── Factor 3: ALL config via environment variables ──────────────────
      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "GCS_RAW_BUCKET"
        value = google_storage_bucket.raw_uploads.name
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      # Cloud Run sends SIGTERM 10 s before SIGKILL.
      # Gunicorn's graceful timeout must be < this value.
      startup_probe {
        http_get { path = "/healthz" }
        initial_delay_seconds = 5
        period_seconds        = 5
        failure_threshold     = 3
      }

      liveness_probe {
        http_get { path = "/healthz" }
        period_seconds = 10
      }
    }
  }

  depends_on = [
    google_project_service.run_api,
    google_artifact_registry_repository.app_repo,
  ]
}

# Allow unauthenticated access to the ingestion UI
resource "google_cloud_run_v2_service_iam_member" "ingestion_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.ingestion.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ── 5. Cloud Run — Worker Service (Subscriber) ───────────────────────────────

resource "google_cloud_run_v2_service" "worker" {
  name     = "worker-service"
  location = var.region

  template {
    service_account = google_service_account.cloudrun_sa.email

    scaling {
      min_instance_count = 0
      max_instance_count = 10   # scale out for parallel conversions
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/file-converter-repo/worker-service:latest"

      ports {
        container_port = 8080
      }

      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "GCS_RAW_BUCKET"
        value = google_storage_bucket.raw_uploads.name
      }
      env {
        name  = "GCS_OUTPUT_BUCKET"
        value = google_storage_bucket.converted_output.name
      }

      resources {
        limits = {
          cpu    = "2"       # conversion is CPU-intensive
          memory = "1Gi"
        }
      }

      startup_probe {
        http_get { path = "/healthz" }
        initial_delay_seconds = 5
        period_seconds        = 5
        failure_threshold     = 3
      }

      liveness_probe {
        http_get { path = "/healthz" }
        period_seconds = 10
      }
    }
  }

  depends_on = [
    google_project_service.run_api,
    google_artifact_registry_repository.app_repo,
  ]
}

# ── 6. Eventarc Service Account ──────────────────────────────────────────────
# Eventarc needs a SA with permission to invoke the worker Cloud Run service.

resource "google_service_account" "eventarc_sa" {
  account_id   = "eventarc-gcs-trigger"
  display_name = "Eventarc GCS Trigger SA"
}

resource "google_cloud_run_v2_service_iam_member" "eventarc_invoke_worker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.worker.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.eventarc_sa.email}"
}

# GCS needs to publish to Eventarc. Grant the GCS service agent the
# eventarc.eventReceiver role so it can deliver events.
data "google_storage_project_service_account" "gcs_sa" {}

resource "google_project_iam_member" "gcs_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs_sa.email_address}"
}

# ── 7. Eventarc Trigger ──────────────────────────────────────────────────────
# Fires on every new object finalized in the raw-uploads bucket.

resource "google_eventarc_trigger" "gcs_to_worker" {
  name     = "gcs-png-upload-trigger"
  location = var.region

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }

  matching_criteria {
    attribute = "bucket"
    value     = google_storage_bucket.raw_uploads.name
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.worker.name
      region  = var.region
    }
  }

  service_account = google_service_account.eventarc_sa.email

  depends_on = [
    google_project_service.eventarc_api,
    google_project_iam_member.gcs_pubsub_publisher,
    google_cloud_run_v2_service_iam_member.eventarc_invoke_worker,
  ]
}

# ── 8. Outputs ───────────────────────────────────────────────────────────────

output "ingestion_service_url" {
  description = "Public URL of the Ingestion Service (upload UI)"
  value       = google_cloud_run_v2_service.ingestion.uri
}

output "worker_service_url" {
  description = "Internal URL of the Worker Service"
  value       = google_cloud_run_v2_service.worker.uri
}

output "raw_bucket_name" {
  description = "GCS bucket for raw PNG uploads"
  value       = google_storage_bucket.raw_uploads.name
}

output "output_bucket_name" {
  description = "GCS bucket for converted JPG/PDF files"
  value       = google_storage_bucket.converted_output.name
}

output "eventarc_trigger_name" {
  description = "Eventarc trigger resource name"
  value       = google_eventarc_trigger.gcs_to_worker.name
}
