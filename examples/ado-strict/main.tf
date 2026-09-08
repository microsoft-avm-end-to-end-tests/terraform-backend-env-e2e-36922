terraform {
  required_version = ">= 1.17.0-dev"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }

  backend "azurerm" {}
}

provider "azapi" {}

data "azapi_client_config" "current" {}

resource "azapi_resource" "example" {
  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = "rg-tf36922-e8195f-ado-strict"
  location  = "westeurope"
  parent_id = "/subscriptions/${data.azapi_client_config.current.subscription_id}"
  body      = {}
}
