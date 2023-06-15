#####
# Provider
client_id     = "terraform"
client_secret = "<terraform-client-secret>"
url           = "<keycloak-url>" # e.g. https://keycloak.example.com

#####
# Keycloak
realm_id = "example-realm"
admin_users = [
  {
    "username"   = "admin001",
    "email"      = "admin@example.com",
    "first_name" = "Admin",
    "last_name"  = "Admin"
  },
  {
    "username"   = "admin002",
    "email"      = "admin@example.com",
    "first_name" = "Admin",
    "last_name"  = "Admin"
  }
]
guest_users = [
  {
    "username"   = "guest001",
    "email"      = "guest@example.com",
    "first_name" = "Guest",
    "last_name"  = "Guest"
  },
  {
    "username"   = "guest002",
    "email"      = "guest@example.com",
    "first_name" = "Guest",
    "last_name"  = "Guest"
  }
]
valid_redirect_uris = [
  "https://<grafana>/login/generic_oauth" # e.g. https://grafana.example.com/login/generic_oauth
]
