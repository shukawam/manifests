#####
# Provider
variable "client_id" {
  description = "Keycloak client_id for Terraform"
}

variable "client_secret" {
  description = "Keycloak client_secret for Terraform"
}

variable "url" {
  description = "Keycloak URL"
}

#####
# Keycloak
variable "realm_id" {
  description = "Name of realm"
}

variable "admin_users" {
  description = "Member of admin group"
}

variable "guest_users" {
  description = "Member of guest group"
}

variable "valid_redirect_uris" {
  description = "Redirect URIs"
}
