# The cloud half of team onboarding. Argo CD reads the same files for the cluster half.
locals {
  teams    = { for f in fileset("${path.module}/../teams", "*.yaml") : trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/../teams/${f}")) }
  pg_teams = { for name, t in local.teams : name => t if try(t.postgres.enabled, false) }
  owners   = toset(flatten([for t in values(local.teams) : try(t.owners, [])]))

  # Workload Identity Federation for GKE: IAM granted straight to Kubernetes
  # identities, with no Google service accounts or keys in between. Reading the
  # pool from the cluster also orders these grants after it: the pool only
  # exists once a Workload Identity cluster does.
  wi_pool = google_container_cluster.this.workload_identity_config[0].workload_pool
}

data "google_project" "this" {
  project_id = var.project_id
}

# The contract Argo CD relies on, checked at plan time: the file name is the team
# name is the namespace, it can't be a platform namespace, and it fits in a
# bucket name.
resource "terraform_data" "team_contract" {
  for_each = local.teams

  lifecycle {
    precondition {
      condition     = try(each.value.team, null) == each.key
      error_message = "teams/${each.key}.yaml: `team` must equal the file name."
    }
    precondition {
      condition = alltrue([
        can(regex("^[a-z][a-z0-9-]{1,19}[a-z0-9]$", each.key)),
        !can(regex("^(kube|gke|gmp)-", each.key)),
        !contains(["default", "argocd", "cert-manager", "cnpg-system"], each.key),
        !strcontains(each.key, "google"),
      ])
      error_message = "teams/${each.key}.yaml: team must be 3-21 chars of [a-z0-9-] and not a platform namespace."
    }
    precondition {
      condition     = can(tolist(try(each.value.owners, []))) && alltrue([for o in try(each.value.owners, []) : can(regex("^[^@\\s]+@[^@\\s]+\\.[a-z]{2,}$", o))])
      error_message = "teams/${each.key}.yaml: owners must be a list of email addresses."
    }
  }
}

# Random suffix: bucket names are global, so a guessable name could be
# registered by someone else first.
resource "random_id" "pg_bucket" {
  for_each = local.pg_teams

  byte_length = 3
}

# Retention is barman's job (ObjectStore retentionPolicy), so no lifecycle rule
# that could delete a base backup barman still needs. Soft delete is the net for
# deletes that shouldn't have happened.
resource "google_storage_bucket" "pg_backups" {
  for_each = local.pg_teams

  name                        = "${var.project_id}-${each.key}-pg-${random_id.pg_bucket[each.key].hex}"
  location                    = var.region
  uniform_bucket_level_access = true # required for principal:// grants
  public_access_prevention    = "enforced"
  force_destroy               = true # demo project; a real one would keep backups

  soft_delete_policy {
    retention_duration_seconds = 604800 # 7 days
  }

  depends_on = [google_project_service.this]
}

# The namespace is the trust boundary: anything that runs in it, including a
# restore-drill cluster, can use the team's bucket. Scoping to the CNPG service
# account would not narrow that, since namespace editors can run pods as it.
# barman-cloud also needs storage.buckets.get, which objectUser lacks.
resource "google_storage_bucket_iam_member" "pg_backups" {
  for_each = {
    for pair in setproduct(keys(local.pg_teams), ["roles/storage.objectUser", "roles/storage.legacyBucketReader"]) :
    "${pair[0]}/${pair[1]}" => { team = pair[0], role = pair[1] }
  }

  bucket = google_storage_bucket.pg_backups[each.value.team].name
  role   = each.value.role
  member = "principalSet://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${local.wi_pool}/namespace/${each.value.team}"
}

# Lets owners reach the cluster's DNS endpoint (container.clusters.connect);
# what they can do inside it is Kubernetes RBAC from the team chart.
resource "google_project_iam_member" "owners" {
  for_each = local.owners

  project = var.project_id
  role    = "roles/container.clusterViewer"
  member  = "user:${each.value}"
}
