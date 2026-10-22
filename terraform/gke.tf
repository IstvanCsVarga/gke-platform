# Nodes get a dedicated service account with only what GKE needs, not the
# Compute Engine default account (which has project Editor).
resource "google_service_account" "nodes" {
  account_id   = "gke-nodes"
  display_name = "GKE nodes"

  depends_on = [google_project_service.this]
}

resource "google_project_iam_member" "nodes" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = google_service_account.nodes.member
}

resource "google_container_cluster" "this" {
  name       = "platform"
  location   = var.zone
  network    = google_compute_network.this.id
  subnetwork = google_compute_subnetwork.nodes.id

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false # demo: `make destroy` has to work

  # Only for the throwaway default pool GKE creates and the provider then
  # deletes: without this, it briefly runs as the Compute Engine default account.
  node_config {
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  lifecycle {
    ignore_changes = [node_config]
  }

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Private nodes, and no IP-based control plane endpoint at all: kubectl goes
  # through the DNS endpoint, so access is decided by IAM, not IP allowlists.
  private_cluster_config {
    enable_private_nodes = true
  }

  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
    ip_endpoints_config {
      enabled = false
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  datapath_provider = "ADVANCED_DATAPATH" # Dataplane V2: eBPF, enforces NetworkPolicy

  # Cost allocation by namespace (i.e. by team), visible in the detailed
  # billing export to BigQuery.
  cost_management_config {
    enabled = true
  }

  depends_on = [google_project_iam_member.nodes]
}

resource "google_container_node_pool" "default" {
  name     = "default"
  cluster  = google_container_cluster.this.id
  location = var.zone

  initial_node_count = 1

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  node_config {
    machine_type    = "e2-standard-4"
    spot            = true
    disk_size_gb    = 50
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    tags            = ["gke-platform-node"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot = true
    }
  }

  depends_on = [google_project_iam_member.nodes]
}

# Scale-to-zero L4 pool for GPU workloads; costs nothing at rest. The taint is
# explicit: GKE only adds it if a non-GPU pool already exists, and the two
# pools are created in no guaranteed order.
resource "google_container_node_pool" "gpu" {
  count = var.gpu_pool ? 1 : 0

  name     = "l4"
  cluster  = google_container_cluster.this.id
  location = var.zone

  autoscaling {
    min_node_count = 0
    max_node_count = 1
  }

  node_config {
    machine_type    = "g2-standard-4"
    spot            = true
    disk_size_gb    = 100
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    tags            = ["gke-platform-node"]

    guest_accelerator {
      type  = "nvidia-l4"
      count = 1
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot = true
    }
  }

  depends_on = [google_project_iam_member.nodes]
}
