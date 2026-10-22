variable "project_id" {
  description = "GCP project to deploy into."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a GCP project ID (6-30 chars, lowercase letters, digits, hyphens)."
  }
}

variable "region" {
  description = "Region for the network, NAT and backup buckets."
  type        = string
  default     = "europe-west4"
}

variable "zone" {
  description = "Zone for the cluster. Zonal, because the GKE free tier covers one zonal cluster's management fee."
  type        = string
  default     = "europe-west4-a"

  validation {
    condition     = startswith(var.zone, "${var.region}-")
    error_message = "zone must be in region."
  }
}

variable "gpu_pool" {
  description = "Add a scale-to-zero NVIDIA L4 spot node pool. Needs GPUS_ALL_REGIONS quota, which new projects don't have."
  type        = bool
  default     = false
}
