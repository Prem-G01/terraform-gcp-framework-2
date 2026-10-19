resource "google_compute_firewall" "firewall" {

  for_each = var.config.firewalls



  project = var.project_id



  name = each.key



  network = var.vpcs[

    each.value.network

  ]



  direction = lookup(

    each.value,

    "direction",

    "INGRESS"

  )



  priority = lookup(

    each.value,

    "priority",

    1000

  )



  source_ranges = lookup(

    each.value,

    "source_ranges",

    null

  )



  source_tags = lookup(each.value, "source_tags", null)

  target_tags = lookup(

    each.value,

    "target_tags",

    null

  )



  dynamic "allow" {

    for_each = lookup(

      each.value,

      "allow",

      []

    )



    content {

      protocol = allow.value.protocol



      ports = lookup(

        allow.value,

        "ports",

        null

      )

    }

  }

}
