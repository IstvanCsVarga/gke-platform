output "cluster_name" {
  value = google_container_cluster.this.name
}

output "pg_buckets" {
  value = { for team, b in google_storage_bucket.pg_backups : team => b.name }
}

# GitOps Bridge: Terraform hands its outputs to Argo CD as annotations on the
# cluster secret, and the teams ApplicationSet reads them back as template
# parameters. `make apply` re-publishes it whenever Argo CD is running.
output "argocd_cluster_secret" {
  value = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "in-cluster"
      namespace = "argocd"
      labels = {
        "argocd.argoproj.io/secret-type" = "cluster"
        "gke-platform/managed"           = "true"
      }
      annotations = merge(
        { "gke-platform/project-id" = var.project_id },
        { for team, b in google_storage_bucket.pg_backups : "gke-platform/pg-bucket-${team}" => b.name },
      )
    }
    stringData = {
      name   = "in-cluster"
      server = "https://kubernetes.default.svc"
      config = jsonencode({ tlsClientConfig = { insecure = false } })
    }
  })
}
