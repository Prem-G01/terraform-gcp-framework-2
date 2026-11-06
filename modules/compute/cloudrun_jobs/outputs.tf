output "names" {
  value = { for key, job in google_cloud_run_v2_job.job : key => job.name }
}
