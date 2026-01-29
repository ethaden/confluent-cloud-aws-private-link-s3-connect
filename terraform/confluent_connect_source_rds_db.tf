# This file sets up:
# - An elastic load balancer (ELB) which forwards the RDS data connections originating from Confleuent Cloud via (egress) private link to the VPC-local endpoint
# - an outbound private link connection to the ELB
# - corresponding dns entries in CCloud
# - a source connector in Postgres mode

resource "aws_lb_target_group" "rds-db" {
  name     = "${local.resource_prefix}-rds-db-elb-tg"
  port     = var.database_port
  protocol = "TCP"
  target_type = "ip"
  vpc_id   = data.aws_vpc.vpc.id
}

resource "aws_lb" "rds-db" {
  name               = "${local.resource_prefix}-rds-db-lb"
  internal           = true
  load_balancer_type = "network"
  subnets            = toset(data.aws_subnets.vpc_subnets.ids)

  enable_deletion_protection = false
}

resource "aws_lb_listener" "rds-db" {
  load_balancer_arn = aws_lb.rds-db.arn
  port              = var.database_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.rds-db.arn
  }
}

# The IP addresses of AWS RDS instances are dynamic, but load balancers need static IP addresses (or you need to update them each time the database starts using a new IP address)
# Thus, it is recommended to use a proxy in front of the actual RDS instance
# The Amazon RDS Proxy is very powerful, but too heavy for this use-case as it also implements its own authentication layer
# Instead, we use a simple tcp forwarding proxy

# resource "aws_lb_target_group_attachment" "rds-db" {
#   target_group_arn = aws_lb_target_group.rds-db.arn
#   target_id        = data.aws_network_interface.rds_db_eni[0].private_ip
#   port             = var.database_port
# }

locals {
  aws_rds_cluster_instance_rds_db_subnet = local.availability_zone_name_to_subnet_id[aws_rds_cluster_instance.rds-db.availability_zone]
}

resource "aws_vpc_endpoint_service" "rds-db" {
  network_load_balancer_arns = [aws_lb.rds-db.arn]
  supported_ip_address_types = ["ipv4"]
  # Accept connections automatically, but only from the list of allowd principals
  acceptance_required        = false
  allowed_principals = [confluent_gateway.gw.aws_egress_private_link_gateway[0].principal_arn]
}

# Create a separate egress gateway instead of using the default one.
# This is required for using custom connectors and thus is the better option here as it unlocks more features
resource "confluent_gateway" "gw" {
 display_name = "${local.resource_prefix}-egress-gw"
 environment {
   id = confluent_environment.example_env.id
 }
 aws_egress_private_link_gateway {
   region = var.aws_region
 }
}

# This is just an example for how to get the default gateway created automatically for every customer network in Confluent Cloud
# We use a dedicated egress gateway instead here, for thre reasons stated above.
# data "confluent_gateway" "main" {
#   id = confluent_network.network.gateway[0].id
#   environment {
#     id = confluent_environment.example_env.id
#   }
# }

# resource "confluent_access_point" "rds-db" {
#   display_name = "${local.resource_prefix}-rds-db"
#   environment {
#     id = confluent_environment.example_env.id
#   }
#   gateway {
#     id = confluent_gateway.gw.id
#   }
#   aws_egress_private_link_endpoint {
#     vpc_endpoint_service_name = aws_vpc_endpoint_service.rds-db.service_name
#   }
#   depends_on = [
#     aws_vpc_endpoint_service.rds-db,
#     aws_lb_target_group_attachment.rds-db,
#    ]
# }

# resource "confluent_dns_record" "rds-db" {
#   display_name = "rds-db"
#   environment {
#     id = confluent_environment.example_env.id
#   }
#   domain = aws_rds_cluster_instance.rds-db.endpoint
#   gateway {
#     id = confluent_gateway.gw.id
#   }
#   private_link_access_point {
#     id = confluent_access_point.rds-db.id
#   }
#   depends_on = [ 
#     aws_db_subnet_group.subnet_group
#   ]
# }

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
    "name"                      = "PostgresSource_rds_db"
    "connector.class"           = "PostgresSource"
    "kafka.auth.mode"           = "SERVICE_ACCOUNT"
    "kafka.service.account.id"  = confluent_service_account.database_service_account.id
    "connection.host"           = aws_rds_cluster_instance.rds-db.endpoint
    "connection.port"           = aws_rds_cluster_instance.rds-db.port
    "connection.user"           = var.database_username
    "ssl.mode"                  = "prefer"
    "db.name"                   = var.database_name
    "database.server.name"      = "${local.resource_prefix}-rds-db"
    "output.data.format"        = "AVRO",
    "tasks.max"                 = "1",
    "db.timezone"               = "UTC",
    #"table.include.list"        = ".*",
    #"table.exclude.list"        = ".*",
    "topic.prefix"              = var.database_topic_profix
  }

  depends_on = [
    #confluent_access_point.rds-db,
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
