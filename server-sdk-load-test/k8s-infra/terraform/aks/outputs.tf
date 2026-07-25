output "resource_group_name" {
  description = "Main resource group containing the AKS resource and ACR."
  value       = local.effective_resource_group_name
}

output "resource_group_created_by_stack" {
  description = "Whether Terraform created and will remove the main resource group."
  value       = var.create_resource_group
}

output "resource_group_metadata_location" {
  description = "Metadata location of the main resource group; resources use the separate location variable."
  value       = local.resource_group_metadata_location
}

output "aks_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.this.name
}

output "node_resource_group" {
  description = "AKS-managed node resource group."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "acr_name" {
  description = "ACR name used for the k6 runner image."
  value       = azurerm_container_registry.this.name
}

output "acr_login_server" {
  description = "ACR login server used in the TestRun image reference."
  value       = azurerm_container_registry.this.login_server
}

output "get_credentials_command" {
  description = "Command to merge the temporary AKS context into kubeconfig."
  value       = "az aks get-credentials --resource-group ${local.effective_resource_group_name} --name ${azurerm_kubernetes_cluster.this.name} --overwrite-existing"
}

output "recommended_k6_parallelism" {
  description = "One runner per isolated loadgen node."
  value       = var.loadgen_node_count
}

output "node_pools" {
  description = "Actual node-pool shape to store with each test report."
  value = {
    system = {
      count   = var.system_node_count
      vm_size = var.system_node_vm_size
    }
    featbit = {
      count   = var.target_node_count
      vm_size = var.target_node_vm_size
    }
    loadgen = {
      count   = var.loadgen_node_count
      vm_size = var.loadgen_node_vm_size
    }
  }
}
