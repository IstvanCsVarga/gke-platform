terraform {
  required_version = ">= 1.10"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.8"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # bucket is passed at init: terraform init -backend-config=bucket=<project>-tfstate
  backend "gcs" {
    prefix = "gke-platform"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    managed-by = "terraform"
    repo       = "gke-platform"
  }
}
