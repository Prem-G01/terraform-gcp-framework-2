output "database_ids" {
  value = { for key, database in google_firestore_database.database : key => database.id }
}
