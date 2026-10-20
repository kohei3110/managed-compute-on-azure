output "resource_group_name" {
  description = "Dedicated resource group managed by this sample."
  value       = azurerm_resource_group.demo.name
}

output "foundry_account_name" {
  description = "Foundry account name."
  value       = azurerm_cognitive_account.foundry.name
}

output "foundry_account_id" {
  description = "Foundry account ARM resource ID and RBAC scope."
  value       = azurerm_cognitive_account.foundry.id
}

output "foundry_project_id" {
  description = "Foundry project ARM resource ID."
  value       = azapi_resource.project.id
}

output "foundry_project_endpoint" {
  description = "Project API endpoint; not the account-level OpenAI inference base URL."
  value       = "${local.endpoint}/api/projects/${azapi_resource.project.name}"
}

output "openai_base_url" {
  description = "Account-level OpenAI-compatible base URL; inference also requires an enabled, healthy model deployment."
  value       = "${local.endpoint}/openai/v1/"
}

output "deployment_enabled" {
  description = "Whether this configuration manages a billable GPU model deployment."
  value       = var.deploy_model
}

output "deployment_name" {
  description = "Use this value in the inference model field. Omitted while the GPU deployment is disabled."
  value       = var.deploy_model ? azapi_resource.qwen[0].name : null
}

output "managed_compute_deployment_id" {
  description = "Managed compute ARM resource ID. Omitted while disabled."
  value       = var.deploy_model ? azapi_resource.qwen[0].id : null
}
