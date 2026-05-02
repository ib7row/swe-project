terraform {
  backend "gcs" {
    # Replace this with your new unique name
    bucket = "ibrahim-r-swe455-tfstate-2026"
    prefix = "terraform/state"
  }
}