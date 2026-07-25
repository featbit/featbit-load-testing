provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      # This applies only when create_resource_group=true. Reused resource groups are
      # data sources and are never removed by this stack.
      prevent_deletion_if_contains_resources = false
    }
  }
}
