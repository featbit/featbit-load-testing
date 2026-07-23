variable "subscription_id" {
  description = "Azure subscription that will own the temporary load-test stack."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "subscription_id must be an Azure subscription UUID."
  }
}

variable "location" {
  description = "Azure region, for example eastasia or southeastasia."
  type        = string
}

variable "name_prefix" {
  description = "Short unique prefix used to derive resource names."
  type        = string
  default     = "featbit-growth"

  validation {
    condition = (
      length(trim(replace(lower(var.name_prefix), "/[^0-9a-z-]/", ""), "-")) >= 3 &&
      length(trim(replace(lower(var.name_prefix), "/[^0-9a-z-]/", ""), "-")) <= 24
    )
    error_message = "name_prefix must produce 3 to 24 lowercase letters, digits, or hyphens."
  }
}

variable "resource_group_name" {
  description = "Optional explicit resource group name. Required when reusing an existing group."
  type        = string
  default     = null
}

variable "create_resource_group" {
  description = "Create and own the main resource group. False reuses resource_group_name and preserves it on destroy."
  type        = bool
  default     = true
}

variable "node_resource_group_name" {
  description = "Optional name for the AKS-managed node resource group. It must not already exist or match the main resource group."
  type        = string
  default     = null
}

variable "aks_name" {
  description = "Optional explicit AKS cluster name."
  type        = string
  default     = null
}

variable "acr_name" {
  description = "Optional globally unique ACR name containing only lowercase letters and digits."
  type        = string
  default     = null

  validation {
    condition = (
      var.acr_name == null ||
      can(regex("^[a-z0-9]{5,50}$", var.acr_name))
    )
    error_message = "acr_name must be null or 5 to 50 lowercase letters and digits."
  }
}

variable "acr_sku" {
  description = "ACR tier. Basic is sufficient for the ephemeral k6 image by default."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.acr_sku)
    error_message = "acr_sku must be Basic, Standard, or Premium."
  }
}

variable "kubernetes_version" {
  description = "Optional supported AKS minor version. Null lets Azure select the current default."
  type        = string
  default     = null
}

variable "availability_zones" {
  description = "Zones supported by all selected SKUs in the region. Empty avoids regional failures."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for zone in var.availability_zones : contains(["1", "2", "3"], zone)
    ])
    error_message = "availability_zones may contain only 1, 2, and 3."
  }
}

variable "private_cluster_enabled" {
  description = "Create a private AKS API endpoint. Requires a control host with private network access."
  type        = bool
  default     = false
}

variable "api_server_authorized_ip_ranges" {
  description = "CIDRs allowed to reach a public AKS API endpoint. Empty means Azure's default public access behavior."
  type        = list(string)
  default     = []
}

variable "enable_key_vault_secrets_provider" {
  description = "Enable the AKS Key Vault Secrets Store CSI add-on."
  type        = bool
  default     = true
}

variable "system_node_vm_size" {
  description = "VM size for the short-lived AKS system pool."
  type        = string
  default     = "Standard_D2ds_v5"
}

variable "system_node_count" {
  description = "System node count. One is a cost tradeoff suitable only for an ephemeral test cluster."
  type        = number
  default     = 1

  validation {
    condition     = var.system_node_count >= 1
    error_message = "system_node_count must be at least 1."
  }
}

variable "target_node_vm_size" {
  description = "VM size for FeatBit UI, API, and ELS."
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "target_node_count" {
  description = "FeatBit target nodes. Two nodes host three ELS replicas for the default ephemeral topology."
  type        = number
  default     = 2

  validation {
    condition     = var.target_node_count >= 1
    error_message = "target_node_count must be at least 1."
  }
}

variable "loadgen_node_vm_size" {
  description = "VM size for each isolated k6 runner node."
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "loadgen_node_count" {
  description = "Load-generator nodes and recommended k6 parallelism."
  type        = number
  default     = 2

  validation {
    condition     = var.loadgen_node_count >= 2
    error_message = "loadgen_node_count must be at least 2 for the distributed AKS profile."
  }
}

variable "tags" {
  description = "Additional tags. Do not place secrets in tags."
  type        = map(string)
  default     = {}
}
