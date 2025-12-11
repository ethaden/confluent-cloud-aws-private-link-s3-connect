# Confluent Cloud Environment

resource "confluent_environment" "example_env" {
  display_name = var.ccloud_environment_name

  stream_governance {
    package = "ESSENTIALS"
  }

  lifecycle {
    prevent_destroy = false
  }
}

data "confluent_schema_registry_cluster" "essentials" {
  environment {
    id = confluent_environment.example_env.id
  }

  depends_on = [
    confluent_kafka_cluster.example_aws_private_link_cluster
  ]
}

# Confluent Cloud Kafka Cluster

# Set up a basic cluster (or a standard cluster, see below)
resource "confluent_kafka_cluster" "example_aws_private_link_cluster" {
  display_name = var.ccloud_cluster_name
  availability = var.ccloud_cluster_availability
  cloud        = "AWS"
  region       = var.aws_region

  dedicated {
    cku = var.ccloud_cluster_ckus
  }

  network {
    id = confluent_network.aws-private-link.id
  }
  environment {
    id = confluent_environment.example_env.id
  }

  lifecycle {
    prevent_destroy = false
  }
}

resource "confluent_network" "aws-private-link" {
  display_name     = "${local.resource_prefix}_aws_private_link_network"
  cloud            = "AWS"
  region           = var.aws_region
  connection_types = ["PRIVATELINK"]

  zones = local.availability_zone_ids
  environment {
    id = confluent_environment.example_env.id
  }

  lifecycle {
    prevent_destroy = false
  }
}

resource "confluent_private_link_access" "aws" {
  display_name = "${local.resource_prefix}_aws_private_link_access"
  aws {
    account = var.aws_account_id
  }
  environment {
    id = confluent_environment.example_env.id
  }
  network {
    id = confluent_network.aws-private-link.id
  }

  lifecycle {
    prevent_destroy = false
  }
}

# Topic with configured name
resource "confluent_kafka_topic" "example_aws_private_link_topic_test" {
  kafka_cluster {
    id = confluent_kafka_cluster.example_aws_private_link_cluster.id
  }
  topic_name         = var.ccloud_cluster_topic
  rest_endpoint      = confluent_kafka_cluster.example_aws_private_link_cluster.rest_endpoint
  partitions_count = 1
  credentials {
    key    = confluent_api_key.example_aws_private_link_api_key_sa_cluster_admin.id
    secret = confluent_api_key.example_aws_private_link_api_key_sa_cluster_admin.secret
  }

  # Required to make sure the role binding is created before trying to create a topic using these credentials
  depends_on = [ 
    ## TODO#aws_route53_record.privatelink-zonal, # Need to wait for DNS to be configured as the cluster REST endpoint can only be accessed via private link
    confluent_role_binding.example_aws_private_link_role_binding_cluster_admin 
    ]

  lifecycle {
    prevent_destroy = false
  }
}

# Service Account, API Key and role bindings for the cluster admin
resource "confluent_service_account" "example_aws_private_link_sa_cluster_admin" {
  display_name = "${local.resource_prefix}_example_aws_private_link_sa_cluster_admin"
  description  = "Service Account mTLS Example Cluster Admin"
}

# An API key with Cluster Admin access. Required for provisioning the cluster-specific resources such as our topic
resource "confluent_api_key" "example_aws_private_link_api_key_sa_cluster_admin" {
  display_name = "${local.resource_prefix}_example_aws_private_link_api_key_sa_cluster_admin"
  description  = "Kafka API Key that is owned by '${local.resource_prefix}_example_aws_private_link_sa_cluster_admin' service account"
  owner {
    id          = confluent_service_account.example_aws_private_link_sa_cluster_admin.id
    api_version = confluent_service_account.example_aws_private_link_sa_cluster_admin.api_version
    kind        = confluent_service_account.example_aws_private_link_sa_cluster_admin.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.example_aws_private_link_cluster.id
    api_version = confluent_kafka_cluster.example_aws_private_link_cluster.api_version
    kind        = confluent_kafka_cluster.example_aws_private_link_cluster.kind

    environment {
      id = confluent_environment.example_env.id
    }
  }

  lifecycle {
    prevent_destroy = false
  }
}

# Assign the CloudClusterAdmin role to the cluster admin service account
resource "confluent_role_binding" "example_aws_private_link_role_binding_cluster_admin" {
  principal   = "User:${confluent_service_account.example_aws_private_link_sa_cluster_admin.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.example_aws_private_link_cluster.rbac_crn
  lifecycle {
    prevent_destroy = false
  }
}

# Service Account, API Key and role bindings for the producer
resource "confluent_service_account" "example_aws_private_link_sa_producer" {
  display_name = "${local.resource_prefix}_example_aws_private_link_sa_producer"
  description  = "Service Account mTLS Example Producer"
}

resource "confluent_api_key" "example_aws_private_link_api_key_producer" {
  display_name = "${local.resource_prefix}_example_aws_private_link_api_key_producer"
  description  = "Kafka API Key that is owned by '${local.resource_prefix}_example_aws_private_link_sa' service account"
  owner {
    id          = confluent_service_account.example_aws_private_link_sa_producer.id
    api_version = confluent_service_account.example_aws_private_link_sa_producer.api_version
    kind        = confluent_service_account.example_aws_private_link_sa_producer.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.example_aws_private_link_cluster.id
    api_version = confluent_kafka_cluster.example_aws_private_link_cluster.api_version
    kind        = confluent_kafka_cluster.example_aws_private_link_cluster.kind

    environment {
      id = confluent_environment.example_env.id
    }
  }

  lifecycle {
    prevent_destroy = false
  }
}

# For role bindings such as DeveloperRead and DeveloperWrite at least a standard cluster type would be required. We use ACLs instead for basic clusters
resource "confluent_role_binding" "example_aws_private_link_role_binding_producer" {
  principal   = "User:${confluent_service_account.example_aws_private_link_sa_producer.id}"
  role_name   = "DeveloperWrite"
  crn_pattern = "${confluent_kafka_cluster.example_aws_private_link_cluster.rbac_crn}/kafka=${confluent_kafka_cluster.example_aws_private_link_cluster.id}/topic=${confluent_kafka_topic.example_aws_private_link_topic_test.topic_name}"
  lifecycle {
    prevent_destroy = false
  }
}
# resource "confluent_kafka_acl" "example_aws_private_link_acl_producer" {
#   kafka_cluster {
#      id = confluent_kafka_cluster.example_aws_private_link_cluster.id
#   }
#   rest_endpoint  = confluent_kafka_cluster.example_aws_private_link_cluster.rest_endpoint
#   resource_type = "TOPIC"
#   resource_name = confluent_kafka_topic.example_aws_private_link_topic_test.topic_name
#   pattern_type  = "LITERAL"
#   principal     = "User:${confluent_service_account.example_aws_private_link_sa_producer.id}"
#   host          = "*"
#   operation     = "WRITE"
#   permission    = "ALLOW"
#   credentials {
#     key    = confluent_api_key.example_aws_private_link_api_key_sa_cluster_admin.id
#     secret = confluent_api_key.example_aws_private_link_api_key_sa_cluster_admin.secret
#   }
#   lifecycle {
#     prevent_destroy = false
#   }
# }

# Service Account, API Key and role bindings for the consumer
resource "confluent_service_account" "example_aws_private_link_sa_consumer" {
  display_name = "${local.resource_prefix}_example_aws_private_link_sa_consumer"
  description  = "Service Account mTLS Lambda Example Consumer"
}


resource "confluent_api_key" "example_aws_private_link_api_key_consumer" {
  display_name = "${local.resource_prefix}_example_aws_private_link_api_key_consumer"
  description  = "Kafka API Key that is owned by '${local.resource_prefix}_example_aws_private_link_sa' service account"
  owner {
    id          = confluent_service_account.example_aws_private_link_sa_consumer.id
    api_version = confluent_service_account.example_aws_private_link_sa_consumer.api_version
    kind        = confluent_service_account.example_aws_private_link_sa_consumer.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.example_aws_private_link_cluster.id
    api_version = confluent_kafka_cluster.example_aws_private_link_cluster.api_version
    kind        = confluent_kafka_cluster.example_aws_private_link_cluster.kind

    environment {
      id = confluent_environment.example_env.id
    }
  }

  lifecycle {
    prevent_destroy = false
  }
}

# For role bindings such as DeveloperRead and DeveloperWrite at least a standard cluster type would be required. Let's use ACLs instead
resource "confluent_role_binding" "example_aws_private_link_role_binding_consumer" {
  principal   = "User:${confluent_service_account.example_aws_private_link_sa_consumer.id}"
  role_name   = "DeveloperRead"
  crn_pattern = "${confluent_kafka_cluster.example_aws_private_link_cluster.rbac_crn}/kafka=${confluent_kafka_cluster.example_aws_private_link_cluster.id}/topic=${confluent_kafka_topic.example_aws_private_link_topic_test.topic_name}"
  lifecycle {
    prevent_destroy = false
  }
}
resource "confluent_role_binding" "example_aws_private_link_role_binding_consumer_group" {
  principal   = "User:${confluent_service_account.example_aws_private_link_sa_consumer.id}"
  role_name   = "DeveloperRead"
  crn_pattern = "${confluent_kafka_cluster.example_aws_private_link_cluster.rbac_crn}/kafka=${confluent_kafka_cluster.example_aws_private_link_cluster.id}/group=${var.ccloud_cluster_consumer_group_prefix}*"
  lifecycle {
    prevent_destroy = false
  }
}

# resource "confluent_kafka_acl" "example_aws_private_link_acl_consumer" {

#   kafka_cluster {
#      id = confluent_kafka_cluster.example_aws_private_link_cluster.id
#   }
#   rest_endpoint  = confluent_kafka_cluster.example_aws_private_link_cluster.rest_endpoint
#   resource_type = "TOPIC"
#   resource_name = confluent_kafka_topic.example_aws_private_link_topic_test.topic_name
#   pattern_type  = "LITERAL"
#   principal     = "User:${confluent_service_account.example_aws_private_link_sa_consumer.id}"
#   host          = "*"
#   operation     = "READ"
#   permission    = "ALLOW"
#   credentials {
#     key    = confluent_api_key.example_aws_private_link_api_key_sa_cluster_admin.id
#     secret = confluent_api_key.example_aws_private_link_api_key_sa_cluster_admin.secret
#   }
#   lifecycle {
#     prevent_destroy = false
#   }
# }

# resource "confluent_kafka_acl" "example_aws_private_link_acl_consumer_group" {

#   kafka_cluster {
#     id = confluent_kafka_cluster.example_aws_private_link_cluster.id
#   }
#   rest_endpoint  = confluent_kafka_cluster.example_aws_private_link_cluster.rest_endpoint
#   resource_type = "GROUP"
#   resource_name = var.ccloud_cluster_consumer_group_prefix
#   pattern_type  = "PREFIXED"
#   principal     = "User:${confluent_service_account.example_aws_private_link_sa_consumer.id}"
#   host          = "*"
#   operation     = "READ"
#   permission    = "ALLOW"
#   credentials {
#     key    = confluent_api_key.example_aws_private_link_api_key_sa_cluster_admin.id
#     secret = confluent_api_key.example_aws_private_link_api_key_sa_cluster_admin.secret
#   }
#   lifecycle {
#     prevent_destroy = false
#   }
# }

output "cluster_bootstrap_server" {
   value = confluent_kafka_cluster.example_aws_private_link_cluster.bootstrap_endpoint
}
output "cluster_rest_endpoint" {
    value = confluent_kafka_cluster.example_aws_private_link_cluster.rest_endpoint
}

# The next entries demonstrate how to output the generated API keys to the console even though they are considered to be sensitive data by Terraform
# Uncomment these lines if you want to generate that output
# output "cluster_api_key_admin" {
#     value = nonsensitive("Key: ${confluent_api_key.example_aws_private_link_api_key_sa_cluster_admin.id}\nSecret: ${confluent_api_key.example_aws_private_link_api_key_sa_cluster_admin.secret}")
# }

# output "cluster_api_key_producer" {
#     value = nonsensitive("Key: ${confluent_api_key.example_aws_private_link_api_key_producer.id}\nSecret: ${confluent_api_key.example_aws_private_link_api_key_producer.secret}")
# }

# output "cluster_api_key_consumer" {
#     value = nonsensitive("Key: ${confluent_api_key.example_aws_private_link_api_key_consumer.id}\nSecret: ${confluent_api_key.example_aws_private_link_api_key_consumer.secret}")
# }

# Generate console client configuration files for testing in subfolder "generated/client-configs"
# PLEASE NOTE THAT THESE FILES CONTAIN SENSITIVE CREDENTIALS
resource "local_sensitive_file" "client_config_files" {
  # Do not generate any files if var.ccloud_cluster_generate_client_config_files is false
  for_each = var.ccloud_cluster_generate_client_config_files ? {
    "admin" = confluent_api_key.example_aws_private_link_api_key_sa_cluster_admin,
    "producer" = confluent_api_key.example_aws_private_link_api_key_producer,
    "consumer" = confluent_api_key.example_aws_private_link_api_key_consumer} : {}

  content = templatefile("${path.module}/templates/client.conf.tpl",
  {
    client_name = "${each.key}"
    cluster_bootstrap_server = trimprefix("${confluent_kafka_cluster.example_aws_private_link_cluster.bootstrap_endpoint}", "SASL_SSL://")
    api_key = "${each.value.id}"
    api_secret = "${each.value.secret}"
    topic = var.ccloud_cluster_topic
    consumer_group_prefix = var.ccloud_cluster_consumer_group_prefix
  }
  )
  filename = "${var.generated_files_path}/client-${each.key}.conf"
}

resource "confluent_service_account" "dynamodb_service_account" {
    display_name = "${local.resource_prefix}_dynamodb_sa"

}

resource "confluent_api_key" "dynamodb_connector_key" {
    display_name = "${local.resource_prefix}_dynamodb_api_key"
    description = "${local.resource_prefix} Service account"
    owner {
        id = confluent_service_account.dynamodb_service_account.id
        api_version = confluent_service_account.dynamodb_service_account.api_version
        kind = confluent_service_account.dynamodb_service_account.kind
    }
}

# Egress access point for connecting from CCloud to Postgres
# TO BE FIXED! Not sure if vpc_endpoint_service_name is set correctly.
# Also still missing: Egress DNS Setup, IAM Role setup (if necessary), ...
resource "confluent_access_point" "postgres" {
  display_name = "${local.resource_prefix}-postgres"
  environment {
    id = confluent_environment.example_env.id
  }
  gateway {
    id = confluent_network.aws-private-link.gateway[0].id
  }
  aws_egress_private_link_endpoint {
    #vpc_endpoint_service_name = "com.amazonaws.vpce.us-west-2.vpce-svc-00000000000000000"
    vpc_endpoint_service_name = "com.amazonaws.${var.aws_region}.rds"
  }
}

output "dynamodb_api_key" {
    description = "DynamoDB API Key"
    value = confluent_api_key.dynamodb_connector_key.id
}

output "dynamodb_api_secret" {
    description = "DynamoDB API Secret"
    value = nonsensitive(confluent_api_key.dynamodb_connector_key.secret)
}
