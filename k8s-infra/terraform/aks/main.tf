locals {
  normalized_prefix = trim(replace(lower(var.name_prefix), "/[^0-9a-z-]/", ""), "-")
  compact_prefix    = replace(local.normalized_prefix, "-", "")
  unique_suffix     = substr(md5("${var.subscription_id}:${var.location}:${local.normalized_prefix}"), 0, 8)

  resource_group_name = var.resource_group_name != null ? var.resource_group_name : "rg-${local.normalized_prefix}"
  aks_name            = var.aks_name != null ? var.aks_name : "aks-${local.normalized_prefix}"
  node_resource_group = var.node_resource_group_name != null ? var.node_resource_group_name : "${local.resource_group_name}-nodes"
  acr_name = var.acr_name != null ? var.acr_name : substr(
    "${local.compact_prefix}${local.unique_suffix}acr",
    0,
    50,
  )

  tags = merge(
    {
      environment = "loadtest"
      ephemeral   = "true"
      managed-by  = "terraform"
      purpose     = "featbit-growth-test"
    },
    var.tags,
  )
}

resource "azurerm_resource_group" "this" {
  count = var.create_resource_group ? 1 : 0

  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

data "azurerm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1

  name = local.resource_group_name

  lifecycle {
    precondition {
      condition     = var.resource_group_name != null
      error_message = "resource_group_name must be set when create_resource_group is false."
    }
  }
}

locals {
  effective_resource_group_name = var.create_resource_group ? (
    azurerm_resource_group.this[0].name
    ) : (
    data.azurerm_resource_group.existing[0].name
  )
  resource_group_metadata_location = var.create_resource_group ? (
    azurerm_resource_group.this[0].location
    ) : (
    data.azurerm_resource_group.existing[0].location
  )
}

resource "azurerm_container_registry" "this" {
  name                = local.acr_name
  resource_group_name = local.effective_resource_group_name
  location            = var.location
  sku                 = var.acr_sku
  admin_enabled       = false
  tags                = local.tags
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = local.aks_name
  location            = var.location
  resource_group_name = local.effective_resource_group_name
  node_resource_group = local.node_resource_group
  dns_prefix          = local.aks_name
  kubernetes_version  = var.kubernetes_version

  sku_tier                          = "Free"
  role_based_access_control_enabled = true
  local_account_disabled            = false
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  private_cluster_enabled           = var.private_cluster_enabled

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_vm_size
    node_count                   = var.system_node_count
    zones                        = length(var.availability_zones) > 0 ? var.availability_zones : null
    max_pods                     = 50
    os_disk_size_gb              = 64
    os_disk_type                 = "Managed"
    only_critical_addons_enabled = true
    temporary_name_for_rotation  = "systmp"

    node_labels = {
      workload = "system"
    }

    upgrade_settings {
      max_surge = "1"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  # Keep the managed Prometheus profile that the AKS load-test workflow uses
  # for historical per-node and per-container resource evidence.
  monitor_metrics {}

  dynamic "api_server_access_profile" {
    for_each = length(var.api_server_authorized_ip_ranges) > 0 ? [1] : []

    content {
      authorized_ip_ranges = var.api_server_authorized_ip_ranges
    }
  }

  dynamic "key_vault_secrets_provider" {
    for_each = var.enable_key_vault_secrets_provider ? [1] : []

    content {
      secret_rotation_enabled = true
    }
  }

  lifecycle {
    precondition {
      condition     = lower(local.node_resource_group) != lower(local.effective_resource_group_name)
      error_message = "AKS requires the node resource group to differ from the cluster resource group."
    }

    precondition {
      condition = !(
        var.private_cluster_enabled &&
        length(var.api_server_authorized_ip_ranges) > 0
      )
      error_message = "api_server_authorized_ip_ranges must be empty for a private cluster."
    }
  }

  tags = local.tags
}

resource "azurerm_kubernetes_cluster_node_pool" "target" {
  name                        = "featbit"
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.this.id
  vm_size                     = var.target_node_vm_size
  node_count                  = var.target_node_count
  zones                       = length(var.availability_zones) > 0 ? var.availability_zones : null
  mode                        = "User"
  max_pods                    = 50
  os_disk_size_gb             = 64
  os_disk_type                = "Managed"
  temporary_name_for_rotation = "fbtmp"

  node_labels = {
    workload = "featbit"
  }

  node_taints = [
    "workload=featbit:NoSchedule",
  ]

  upgrade_settings {
    max_surge = "1"
  }

  tags = local.tags
}

resource "azurerm_kubernetes_cluster_node_pool" "loadgen" {
  name                        = "loadgen"
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.this.id
  vm_size                     = var.loadgen_node_vm_size
  node_count                  = var.loadgen_node_count
  zones                       = length(var.availability_zones) > 0 ? var.availability_zones : null
  mode                        = "User"
  max_pods                    = 30
  os_disk_size_gb             = 64
  os_disk_type                = "Managed"
  temporary_name_for_rotation = "k6tmp"

  node_labels = {
    workload = "loadgen"
  }

  node_taints = [
    "workload=loadgen:NoSchedule",
  ]

  upgrade_settings {
    max_surge = "1"
  }

  tags = local.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}
