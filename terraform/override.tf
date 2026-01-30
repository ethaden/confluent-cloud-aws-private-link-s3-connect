module "confluent_terraform_aws_csta_base_module" {
    source = "github.com/ethaden/confluent-terraform-aws-csta-base-module.git"
    #source = "../confluent-terraform-aws-csta-base-module"

    #username = var.username
    #public_ssh_key = var.public_ssh_key
    owner = var.owner
    owner_email = var.owner_email
}
