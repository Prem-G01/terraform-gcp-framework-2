resource "google_artifact_registry_repository" "repository" {
  for_each               = var.config.artifact_registry
  project                = var.project_id
  repository_id          = each.value.repository_id
  format                 = each.value.format
  location               = each.value.location
  description            = each.value.description
  labels                 = lookup(each.value, "labels", {})
  mode                   = lookup(each.value, "mode", null)
  cleanup_policy_dry_run = lookup(each.value, "cleanup_policy_dry_run", false)

  # `cleanup_policy` itself is optional (falls back to no cleanup policy
  # at all when omitted, matching GCP's own default) — found hard-required
  # with zero fallback, same class of gap as
  # docs/security.md's 2026-08-19/2026-08-24 audits found elsewhere.
  #
  # `keep_count` (set to 20/10/10 across the real dev config's docker/
  # python/maven repos) was being silently ignored entirely — only a
  # DELETE-after-30-days policy was ever created, so every operator's
  # actual "keep the last N versions" intent had zero effect. GCP's
  # provider schema requires a *separate* cleanup_policies block with
  # action = "KEEP" and a most_recent_versions { keep_count } — verified
  # directly against the installed provider schema, not assumed. Found
  # 2026-08-24.
  dynamic "cleanup_policies" {
    for_each = try(each.value.cleanup_policy.enabled, false) ? [1] : []
    content {
      id     = "delete-old-versions"
      action = "DELETE"
      condition {
        older_than = "30d"
      }
    }
  }

  dynamic "cleanup_policies" {
    for_each = try(each.value.cleanup_policy.enabled, false) && try(each.value.cleanup_policy.keep_count, null) != null ? [1] : []
    content {
      id     = "keep-recent-versions"
      action = "KEEP"
      most_recent_versions {
        keep_count = each.value.cleanup_policy.keep_count
      }
    }
  }
}
