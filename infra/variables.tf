variable "subscription_id" {
  description = "Azure public-cloud subscription ID."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.subscription_id))
    error_message = "subscription_id must be a UUID."
  }
}

variable "location" {
  description = "Azure region for the Foundry account; verify Managed compute availability and quota separately."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9]+$", var.location))
    error_message = "location must be an Azure region identifier such as eastus2, not a display name."
  }
}

variable "name_prefix" {
  description = "Globally unique prefix for the account subdomain: 3-40 lowercase letters, digits, or hyphens."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-40 characters, start with a lowercase letter, and end with a letter or digit."
  }
}

variable "inference_principal_object_id" {
  description = "Entra object ID of the user, group, or service principal that will call the model; not an application/client ID."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.inference_principal_object_id))
    error_message = "inference_principal_object_id must be an Entra object ID in UUID format."
  }
}

variable "deploy_model" {
  description = "Explicitly enable the billable GPU deployment after checking the model, template, quota, and price."
  type        = bool
  default     = false
  nullable    = false
}

variable "deployment_name" {
  description = "Application-facing deployment name sent in the inference request's model field."
  type        = string
  default     = "qwen-demo"
  nullable    = false

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{1,63}$", var.deployment_name))
    error_message = "deployment_name must be 2-64 characters using letters, digits, underscores, or hyphens, starting with a letter or digit."
  }
}

variable "model_id" {
  description = "Verified azure-huggingface registry model URI with an explicit version. Required when deploy_model is true."
  type        = string
  default     = null

  validation {
    condition = var.model_id == null ? !var.deploy_model : can(regex(
      "^azureml://registries/azure-huggingface/models/[a-zA-Z0-9._-]+/versions/[0-9]+$",
      var.model_id
    ))
    error_message = "Set model_id to a verified azureml://registries/azure-huggingface/models/<model>/versions/<number> URI before enabling deploy_model."
  }
}

variable "deployment_template_id" {
  description = "Compatible registry deployment template URI ending in labels/latest, as required by the Managed compute API."
  type        = string
  default     = null

  validation {
    condition = var.deployment_template_id == null ? !var.deploy_model : can(regex(
      "^azureml://registries/azure-huggingface/deploymenttemplates/[a-zA-Z0-9._-]+/labels/latest$",
      var.deployment_template_id
    ))
    error_message = "Set deployment_template_id to a compatible azureml://registries/azure-huggingface/deploymenttemplates/<template>/labels/latest URI; the service rejects versioned template references."
  }
}

variable "accelerator_type" {
  description = "Accelerator family supported by the chosen template. Required when deploy_model is true."
  type        = string
  default     = null

  validation {
    condition     = var.accelerator_type == null ? !var.deploy_model : contains(["A100_80GB", "H100_80GB", "MI300_192GB"], var.accelerator_type)
    error_message = "accelerator_type must be A100_80GB, H100_80GB, or MI300_192GB and must be set when deploy_model is true."
  }
}

variable "model_instance_count" {
  description = "Model instances, not GPU count. Total GPUs also depend on the deployment template."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.model_instance_count >= 1 && floor(var.model_instance_count) == var.model_instance_count
    error_message = "model_instance_count must be a positive integer."
  }
}

variable "tags" {
  description = "Additional tags for the resource group, account, and project."
  type        = map(string)
  default     = {}
  nullable    = false
}
