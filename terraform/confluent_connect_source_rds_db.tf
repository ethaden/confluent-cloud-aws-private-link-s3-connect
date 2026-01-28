# This file sets up:
# - An elastic load balancer (ELB) which forwards the RDS data connections originating from Confleuent Cloud via (egress) private link to the VPC-local endpoint
# - an outbound private link connection to the ELB
# - corresponding dns entries in CCloud
# - a source connector in Postgres mode

resource "aws_lb_target_group" "rds-db" {
  name     = "${local.resource_prefix}-rds-db-elb-tg"
  port     = 5432
  protocol = "TCP"
  vpc_id   = data.aws_vpc.vpc.id
}

resource "aws_lb" "rds-db" {
  name               = "${local.resource_prefix}-rds-db-lb"
  internal           = true
  load_balancer_type = "network"
  subnets            = toset(data.aws_subnets.vpc_subnets.ids)

  enable_deletion_protection = false
}

locals {
  aws_rds_cluster_instance_rds_db_subnet = local.availability_zone_name_to_subnet_id[aws_rds_cluster_instance.rds-db.availability_zone]
}

resource "aws_vpc_endpoint_service" "rds-db" {
  acceptance_required        = true
  network_load_balancer_arns = [aws_lb.rds-db.arn]
  supported_ip_address_types = ["ipv4"]
  allowed_principals = [data.confluent_gateway.main.aws_egress_private_link_gateway[0].principal_arn]
}

#resource "confluent_gateway" "gw" {
#  display_name = "${local.resource_prefix}-gw"
#  environment {
#    id = confluent_environment.example_env.id
#  }
#  aws_egress_private_link_gateway {
#    region = var.aws_region
#  }
#}

data "confluent_gateway" "main" {
  id = confluent_network.network.gateway[0].id
  environment {
    id = confluent_environment.example_env.id
  }
}

resource "confluent_access_point" "rds-db" {
  display_name = "${local.resource_prefix}-rds-db"
  environment {
    id = confluent_environment.example_env.id
  }
  gateway {
    id = confluent_network.network.gateway[0].id
  }
  aws_egress_private_link_endpoint {
    vpc_endpoint_service_name = aws_vpc_endpoint_service.rds-db.service_name
  }
}

resource "confluent_dns_record" "rds-db" {
  display_name = "rds-db"
  environment {
    id = confluent_environment.example_env.id
  }
  domain = aws_rds_cluster_instance.rds-db.endpoint
  gateway {
    id = confluent_network.network.gateway[0].id
  }
  private_link_access_point {
    id = confluent_access_point.rds-db.id
  }
}

resource "confluent_service_account" "database_service_account" {
    display_name = "${local.resource_prefix}_database_sa"

}

resource "confluent_api_key" "database_connector_key" {
    display_name = "${local.resource_prefix}_database_api_key"
    description = "${local.resource_prefix} Service account"
    owner {
        id = confluent_service_account.database_service_account.id
        api_version = confluent_service_account.database_service_account.api_version
        kind = confluent_service_account.database_service_account.kind
    }
}

# The connector needs these roles:
# - DeveloperManage (for creating the topics)
# - DeveloperWrite (for producing to the topics)
# - ResourceOwner on Schema Registry Subject Prefix

resource "confluent_role_binding" "database_service_account_developer_manage" {
  principal   = "User:${confluent_service_account.database_service_account.id}"
  role_name   = "DeveloperManage"
  crn_pattern = "${confluent_kafka_cluster.example_aws_private_link_cluster.rbac_crn}/kafka=${confluent_kafka_cluster.example_aws_private_link_cluster.id}/topic=var.database_topic_profix*"
  lifecycle {
    prevent_destroy = false
  }
}
resource "confluent_role_binding" "database_service_account_developer_write" {
  principal   = "User:${confluent_service_account.database_service_account.id}"
  role_name   = "DeveloperWrite"
  crn_pattern = "${confluent_kafka_cluster.example_aws_private_link_cluster.rbac_crn}/kafka=${confluent_kafka_cluster.example_aws_private_link_cluster.id}/topic=var.database_topic_profix*"
  lifecycle {
    prevent_destroy = false
  }
}
resource "confluent_role_binding" "database_service_account_sr_manage" {
  principal   = "User:${confluent_service_account.database_service_account.id}"
  role_name   = "ResourceOwner"
  crn_pattern = "${data.confluent_schema_registry_cluster.essentials.resource_name}/subject=var.database_topic_profix*"
  lifecycle {
    prevent_destroy = false
  }
}

resource "confluent_connector" "postgre-sql-cdc-source" {
  environment {
    id = confluent_environment.example_env.id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.example_aws_private_link_cluster.id
  }

  // Block for custom *sensitive* configuration properties that are labelled with "Type: password" under "Configuration Properties" section in the docs:
  // https://docs.confluent.io/cloud/current/connectors/cc-postgresql-cdc-source-debezium.html#configuration-properties
  config_sensitive = {
    "database.password" = var.database_password
  }

  // Block for custom *nonsensitive* configuration properties that are *not* labelled with "Type: password" under "Configuration Properties" section in the docs:
  // https://docs.confluent.io/cloud/current/connectors/cc-postgresql-cdc-source-debezium.html#configuration-properties
  config_nonsensitive = {
    "connector.class"          = "PostgresCdcSource"
    "name"                     = "PostgresCdcSourceConnector_0"
    "kafka.auth.mode"          = "SERVICE_ACCOUNT"
    "kafka.service.account.id" = confluent_service_account.database_service_account.id
    "database.hostname"        = aws_rds_cluster_instance.rds-db.endpoint
    "database.port"            = aws_rds_cluster_instance.rds-db.port
    "database.user"            = var.database_username
    "database.dbname"          = var.database_name
    "database.server.name"     = "${local.resource_prefix}-rds-db"
    "plugin.name"              = "pgoutput",
    "output.data.format"       = "AVRO",
    "tasks.max"                = "1",
    "topic.prefix"             = var.database_topic_profix
  }

  depends_on = [
    confluent_access_point.rds-db,
    confluent_role_binding.database_service_account_developer_manage,
    confluent_role_binding.database_service_account_developer_write,
    confluent_role_binding.database_service_account_sr_manage,
  ]
}


# outputs

output "database_api_key" {
    description = "database API Key"
    value = confluent_api_key.database_connector_key.id
}

output "database_api_secret" {
    description = "database API Secret"
    value = nonsensitive(confluent_api_key.database_connector_key.secret)
}
