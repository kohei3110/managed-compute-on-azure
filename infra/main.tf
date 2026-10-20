locals {
  account_name = "${var.name_prefix}-ai"
  project_name = "${var.name_prefix}-project"
  endpoint     = "https://${azurerm_cognitive_account.foundry.custom_subdomain_name}.services.ai.azure.com"

  # The Foundry User role was formerly named Azure AI User; its ID is unchanged.
  foundry_user_role_id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/53ca6127-db72-4b80-b1b0-d745d6d5456d"

  tags = merge({
    workload   = "qwen-managed-compute-demo"
    managed_by = "terraform"
  }, var.tags)
}

resource "azurerm_resource_group" "demo" {
  name     = "${var.name_prefix}-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_cognitive_account" "foundry" {
  name                          = local.account_name
  resource_group_name           = azurerm_resource_group.demo.name
  location                      = azurerm_resource_group.demo.location
  kind                          = "AIServices"
  sku_name                      = "S0"
  custom_subdomain_name         = local.account_name
  project_management_enabled    = true
  public_network_access_enabled = true
  local_auth_enabled            = false
  tags                          = local.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azapi_resource" "project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2026-03-01"
  parent_id = azurerm_cognitive_account.foundry.id
  name      = local.project_name
  location  = azurerm_resource_group.demo.location
  tags      = local.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      displayName = local.project_name
      description = "Qwen on Foundry Managed compute demo"
    }
  }

  response_export_values = []
}

resource "azurerm_role_assignment" "inference_user" {
  scope              = azurerm_cognitive_account.foundry.id
  role_definition_id = local.foundry_user_role_id
  principal_id       = var.inference_principal_object_id
}

resource "azurerm_role_assignment" "project_user" {
  scope                            = azurerm_cognitive_account.foundry.id
  role_definition_id               = local.foundry_user_role_id
  principal_id                     = azapi_resource.project.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azapi_resource" "qwen" {
  count = var.deploy_model ? 1 : 0

  type      = "Microsoft.CognitiveServices/accounts/managedComputeDeployments@2026-05-15-preview"
  parent_id = azurerm_cognitive_account.foundry.id
  name      = var.deployment_name

  body = {
    sku = {
      name     = "GlobalManagedCompute"
      capacity = var.model_instance_count
    }
    properties = {
      model                = var.model_id
      deploymentTemplate   = var.deployment_template_id
      acceleratorType      = var.accelerator_type
      versionUpgradeOption = "NoAutoUpgrade"
    }
  }

  # The API marks the model and accelerator immutable; replace rather than PATCH.
  replace_triggers_external_values = [var.model_id, var.accelerator_type]
  response_export_values           = ["properties.provisioningState"]

  depends_on = [
    azurerm_role_assignment.inference_user,
    azurerm_role_assignment.project_user,
  ]

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}
