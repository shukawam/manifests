provider "keycloak" {
  client_id     = var.client_id
  client_secret = var.client_secret
  url           = var.url
}

terraform {
  required_providers {
    keycloak = {
      source  = "mrparkers/keycloak"
      version = ">= 4.0.0"
    }
  }
}
