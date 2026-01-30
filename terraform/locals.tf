# The following module is just empty and only used for making Terraform happy.
# Copy override.tf-template override.tf if you want to actually use it
module "confluent_terraform_aws_csta_base_module" {
    source = "./empty_module"
}

locals {
    extra_tags = try (module.confluent_terraform_aws_csta_base_module.extra_tags, {})
    resource_prefix = var.resource_prefix!="" ? var.resource_prefix : try (module.confluent_terraform_aws_csta_base_module.username, "")
}

locals {
    # Comment the next four lines if this project is not using Confluent Cloud
    #confluent_creds = {
    #    api_key = "<YOUR_API_KEY_ID>"
    #    api_secret = "<YOUR_API_KEY_SECRET>"
    #}
}

output "extra_tags" {
    value = local.extra_tags
}
