#####
# Realm
resource "keycloak_realm" "realm" {
  realm = local.realm_id
}

#####
# Groups
resource "keycloak_group" "admin" {
  name     = "admin"
  realm_id = keycloak_realm.realm.id
}

resource "keycloak_group" "guest" {
  name     = "guest"
  realm_id = keycloak_realm.realm.id
}

#####
# Users
resource "keycloak_user" "admin_users" {
  for_each       = { for i in var.admin_users : i.username => i }
  realm_id       = keycloak_realm.realm.id
  username       = each.value.username
  enabled        = true
  email          = each.value.email
  email_verified = true
  first_name     = each.value.first_name
  last_name      = each.value.last_name
  initial_password {
    value = local.initial_password
  }
}

resource "keycloak_user" "guest_users" {
  for_each       = { for i in var.guest_users : i.username => i }
  realm_id       = keycloak_realm.realm.id
  username       = each.value.username
  enabled        = true
  email          = each.value.email
  email_verified = true
  first_name     = each.value.first_name
  last_name      = each.value.last_name
  initial_password {
    value = local.initial_password
  }
}

#####
# Group membership
resource "keycloak_group_memberships" "admin_group_membershop" {
  for_each = { for i in var.admin_users : i.username => i }
  realm_id = keycloak_realm.realm.id
  group_id = keycloak_group.admin.id
  members = [
    each.value.username
  ]
}

resource "keycloak_group_memberships" "guest_group_membershop" {
  for_each = { for i in var.guest_users : i.username => i }
  realm_id = keycloak_realm.realm.id
  group_id = keycloak_group.guest.id
  members = [
    each.value.username
  ]
}

#####
# OpenID Connect Client Scope
resource "keycloak_openid_client_scope" "groups" {
  realm_id               = keycloak_realm.realm.id
  name                   = local.scope_name_groups
  include_in_token_scope = true
}

resource "keycloak_openid_group_membership_protocol_mapper" "groups_mapper" {
  realm_id        = keycloak_realm.realm.id
  client_scope_id = keycloak_openid_client_scope.groups.id
  name            = local.scope_name_groups
  claim_name      = local.scope_name_groups
  full_path       = false
}

#####
# OpenID Connect Client
resource "keycloak_openid_client" "grafana_client" {
  realm_id              = keycloak_realm.realm.id
  enabled               = true
  name                  = local.client_name
  client_id             = local.client_id
  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  valid_redirect_uris   = var.valid_redirect_uris
}

resource "keycloak_openid_client_default_scopes" "grafana_client_default_scopes" {
  realm_id       = keycloak_realm.realm.id
  client_id      = keycloak_openid_client.grafana_client.id
  default_scopes = local.default_scopes
}
