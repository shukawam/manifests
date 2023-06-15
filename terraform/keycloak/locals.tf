locals {
  scope_name_groups = "groups"
  client_id         = "grafana"
  client_name       = "Grafana"
  default_scopes = [
    "profile",
    "email",
    "groups"
  ]
  initial_password = "ChangeMe!!"
}
