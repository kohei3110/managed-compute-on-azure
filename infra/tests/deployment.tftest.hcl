mock_provider "azurerm" {}
mock_provider "azapi" {}

override_resource {
  target = azurerm_resource_group.demo
  values = {
    id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/qwen-test-rg"
  }
}

override_resource {
  target = azurerm_cognitive_account.foundry
  values = {
    id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/qwen-test-rg/providers/Microsoft.CognitiveServices/accounts/qwen-test-ai"
  }
}

override_resource {
  target = azapi_resource.project
  values = {
    id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/qwen-test-rg/providers/Microsoft.CognitiveServices/accounts/qwen-test-ai/projects/qwen-test-project"
    identity = {
      principal_id = "33333333-3333-3333-3333-333333333333"
      tenant_id    = "44444444-4444-4444-4444-444444444444"
    }
  }
}

variables {
  subscription_id               = "11111111-1111-1111-1111-111111111111"
  location                      = "eastus2"
  name_prefix                   = "qwen-test"
  inference_principal_object_id = "22222222-2222-2222-2222-222222222222"

  # Null exercises nullable=false defaults without inheriting real tfvars values.
  deploy_model           = null
  deployment_name        = null
  model_instance_count   = null
  model_id               = null
  deployment_template_id = null
  accelerator_type       = null
  tags                   = {}
}

run "foundation_only_by_default" {
  command = apply

  assert {
    condition     = length(azapi_resource.qwen) == 0 && !output.deployment_enabled && output.deployment_name == null
    error_message = "The default must not create a billable GPU deployment or expose a usable deployment name."
  }

  assert {
    condition     = azurerm_cognitive_account.foundry.kind == "AIServices" && azurerm_cognitive_account.foundry.project_management_enabled
    error_message = "Use a new Foundry account with project management, not a classic AML hub."
  }

  assert {
    condition     = !azurerm_cognitive_account.foundry.local_auth_enabled && azurerm_cognitive_account.foundry.public_network_access_enabled
    error_message = "The public endpoint must require Entra ID instead of account keys."
  }

  assert {
    condition     = azurerm_role_assignment.inference_user.scope == azurerm_cognitive_account.foundry.id && endswith(azurerm_role_assignment.inference_user.role_definition_id, "/53ca6127-db72-4b80-b1b0-d745d6d5456d")
    error_message = "Inference requires Foundry User at account scope."
  }

  assert {
    condition     = azurerm_role_assignment.project_user.principal_id == "33333333-3333-3333-3333-333333333333"
    error_message = "The project managed identity must receive its own account-scoped role."
  }

  assert {
    condition     = output.openai_base_url == "https://qwen-test-ai.services.ai.azure.com/openai/v1/" && output.foundry_project_endpoint == "https://qwen-test-ai.services.ai.azure.com/api/projects/qwen-test-project"
    error_message = "Project and OpenAI endpoints must not be confused."
  }
}

# These fixture assets are intentionally not deployable registry references.
run "enable_model_with_mocked_apply" {
  command = apply

  variables {
    deploy_model           = true
    model_id               = "azureml://registries/azure-huggingface/models/qwen-test-fixture/versions/1"
    deployment_template_id = "azureml://registries/azure-huggingface/deploymenttemplates/qwen-test-fixture/labels/latest"
    accelerator_type       = "A100_80GB"
  }

  assert {
    condition     = length(azapi_resource.qwen) == 1 && output.deployment_name == "qwen-demo"
    error_message = "Explicit opt-in must manage exactly one named deployment."
  }

  assert {
    condition     = azapi_resource.qwen[0].type == "Microsoft.CognitiveServices/accounts/managedComputeDeployments@2026-05-15-preview" && azapi_resource.qwen[0].parent_id == azurerm_cognitive_account.foundry.id
    error_message = "Managed compute must be an account child using the preview API."
  }

  assert {
    condition     = azapi_resource.qwen[0].body.sku.name == "GlobalManagedCompute" && azapi_resource.qwen[0].body.sku.capacity == 1
    error_message = "Use GlobalManagedCompute with one model instance by default."
  }

  assert {
    condition     = azapi_resource.qwen[0].body.properties.model == var.model_id && azapi_resource.qwen[0].body.properties.deploymentTemplate == var.deployment_template_id && azapi_resource.qwen[0].body.properties.acceleratorType == var.accelerator_type && azapi_resource.qwen[0].body.properties.versionUpgradeOption == "NoAutoUpgrade"
    error_message = "Preserve the explicitly selected model, template, accelerator, and upgrade policy."
  }
}

run "scale_model_instances" {
  command = plan

  variables {
    deploy_model           = true
    model_id               = "azureml://registries/azure-huggingface/models/qwen-test-fixture/versions/1"
    deployment_template_id = "azureml://registries/azure-huggingface/deploymenttemplates/qwen-test-fixture/labels/latest"
    accelerator_type       = "A100_80GB"
    model_instance_count   = 2
  }

  assert {
    condition     = azapi_resource.qwen[0].body.sku.capacity == 2
    error_message = "Instance count must control SKU capacity, not create additional deployment resources."
  }
}

run "disable_previously_enabled_model" {
  command = plan

  assert {
    condition     = length(azapi_resource.qwen) == 0 && output.deployment_name == null && output.managed_compute_deployment_id == null
    error_message = "Disabling must remove the model resource and its inference outputs."
  }
}

run "require_model_settings_before_opt_in" {
  command = plan

  variables {
    deploy_model = true
  }

  expect_failures = [
    var.model_id,
    var.deployment_template_id,
    var.accelerator_type,
  ]
}

run "reject_unversioned_model" {
  command = plan

  variables {
    model_id = "azureml://registries/azure-huggingface/models/qwen-test-fixture/labels/latest"
  }

  expect_failures = [var.model_id]
}

run "reject_versioned_template_unsupported_by_service" {
  command = plan

  variables {
    deployment_template_id = "azureml://registries/azure-huggingface/deploymenttemplates/qwen-test-fixture/versions/1"
  }

  expect_failures = [var.deployment_template_id]
}

run "reject_unsupported_template_label" {
  command = plan

  variables {
    deployment_template_id = "azureml://registries/azure-huggingface/deploymenttemplates/qwen-test-fixture/labels/production"
  }

  expect_failures = [var.deployment_template_id]
}

run "reject_classic_model_registry" {
  command = plan

  variables {
    model_id = "azureml://registries/azureml/models/qwen-test-fixture/versions/1"
  }

  expect_failures = [var.model_id]
}

run "reject_unknown_accelerator" {
  command = plan

  variables {
    accelerator_type = "Standard_NC24ads_A100_v4"
  }

  expect_failures = [var.accelerator_type]
}

run "reject_zero_capacity" {
  command = plan

  variables {
    model_instance_count = 0
  }

  expect_failures = [var.model_instance_count]
}

run "reject_fractional_capacity" {
  command = plan

  variables {
    model_instance_count = 1.5
  }

  expect_failures = [var.model_instance_count]
}

run "reject_invalid_names" {
  command = plan

  variables {
    name_prefix     = "Invalid_Prefix"
    deployment_name = "invalid.deployment"
  }

  expect_failures = [var.name_prefix, var.deployment_name]
}

run "accept_minimum_name_lengths" {
  command = plan

  variables {
    name_prefix     = "qwe"
    deployment_name = "qw"
  }

  assert {
    condition     = azurerm_cognitive_account.foundry.name == "qwe-ai"
    error_message = "A three-character prefix must be accepted."
  }
}

run "accept_maximum_name_lengths" {
  command = plan

  variables {
    name_prefix     = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    deployment_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  assert {
    condition     = length(azurerm_cognitive_account.foundry.name) == 43
    error_message = "A 40-character prefix must fit the generated account name."
  }
}

run "reject_names_below_minimum_lengths" {
  command = plan

  variables {
    name_prefix     = "qw"
    deployment_name = "q"
  }

  expect_failures = [var.name_prefix, var.deployment_name]
}

run "reject_names_above_maximum_lengths" {
  command = plan

  variables {
    name_prefix     = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    deployment_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  expect_failures = [var.name_prefix, var.deployment_name]
}

run "reject_invalid_identity" {
  command = plan

  variables {
    subscription_id               = "not-a-subscription"
    inference_principal_object_id = "not-an-object-id"
  }

  expect_failures = [var.subscription_id, var.inference_principal_object_id]
}

run "reject_region_display_name" {
  command = plan

  variables {
    location = "East US 2"
  }

  expect_failures = [var.location]
}
