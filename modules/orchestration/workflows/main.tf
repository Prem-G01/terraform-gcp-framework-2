resource "google_workflows_workflow" "workflow" {

  for_each = var.config.workflows



  project = var.project_id



  name = lookup(each.value, "name", each.key)



  region = each.value.region



  description = lookup(

    each.value,

    "description",

    ""

  )



  service_account = lookup(

    var.service_accounts,

    lookup(each.value, "service_account", ""),

    null

  )



  call_log_level          = lookup(each.value, "call_log_level", null)
  execution_history_level = lookup(each.value, "execution_history_level", null)
  labels                  = lookup(each.value, "labels", {})
  source_contents         = each.value.source_contents

  deletion_protection = lookup(each.value, "deletion_protection", true)

}