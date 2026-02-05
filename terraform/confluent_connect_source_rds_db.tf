# This file sets up:
# - An elastic load balancer (ELB) which forwards the RDS data connections originating from Confleuent Cloud via (egress) private link to the VPC-local endpoint
# - an outbound private link connection to the ELB
# - corresponding dns entries in CCloud
# - a source connector in Postgres mode

resource "aws_lb_target_group" "rds_db" {
  name     = "${local.resource_prefix}-rds-db-elb-tg"
  port     = var.database_port
  protocol = "TCP"
  target_type = "ip"
  vpc_id   = data.aws_vpc.vpc.id
}

resource "aws_lb" "rds_db" {
  name               = "${local.resource_prefix}-rds-db-lb"
  internal           = true
  load_balancer_type = "network"
  subnets            = toset(data.aws_subnets.vpc_subnets.ids)

  enable_deletion_protection = false
}

resource "aws_lb_listener" "rds_db" {
  load_balancer_arn = aws_lb.rds_db.arn
  port              = var.database_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.rds_db.arn
  }
}

resource "aws_lb_target_group_attachment" "rds_db" {
  target_group_arn = aws_lb_target_group.rds_db.arn
  target_id        = data.aws_network_interface.rds_writer_eni.private_ip
  port             = var.database_port

  lifecycle {
    # CRITICAL: Prevents Terraform from reverting the IP when the Lambda 
    # function updates it after an Aurora failover.
    ignore_changes = [target_id]
  }
}

# The IP addresses of AWS RDS instances are dynamic, but load balancers need static IP addresses (or you need to update them each time the database starts using a new IP address)
# Thus, it is recommended to use a proxy in front of the actual RDS instance
# The Amazon RDS Proxy is very powerful, but too heavy for this use-case as it also implements its own authentication layer
# Instead, we use a simple tcp forwarding proxy

data "aws_db_instance" "writer_instance" {
  db_instance_identifier = aws_rds_cluster.rds_db.replication_source_identifier != null ? aws_rds_cluster.rds_db.replication_source_identifier : tolist(aws_rds_cluster.rds_db.cluster_members)[0]
  depends_on = [ aws_rds_cluster_instance.rds_db ]
}

# 3. Find the ENI using a filter for the Writer Instance ID
# This needs to be fixed: Initially, the db_instance_identifier is null and terraform fails
data "aws_network_interface" "rds_writer_eni" {
  filter {
    name   = "description"
    values = ["RDSNetworkInterface", "RDS ${data.aws_db_instance.writer_instance.db_instance_identifier}"]
  }

  filter {
    name   = "status"
    values = ["in-use"]
  }
  depends_on = [ 
    data.aws_db_instance.writer_instance
   ]
}

locals {
  aws_rds_cluster_instance_rds_db_subnet = local.availability_zone_name_to_subnet_id[aws_rds_cluster_instance.rds_db.availability_zone]
}

resource "aws_vpc_endpoint_service" "rds_db" {
  network_load_balancer_arns = [aws_lb.rds_db.arn]
  supported_ip_address_types = ["ipv4"]
  # Accept connections automatically, but only from the list of allowd principals
  acceptance_required        = false
  allowed_principals = [data.confluent_gateway.gw.aws_egress_private_link_gateway[0].principal_arn]
}

# Create a separate egress gateway instead of using the default one.
# This is required for using custom connectors and thus is the better option here as it unlocks more features
# Today, this serverless gateway cannot 
# resource "confluent_gateway" "gw" {
#  display_name = "${local.resource_prefix}-egress-gw"
#  environment {
#    id = confluent_environment.example_env.id
#  }
#  aws_egress_private_link_gateway {
#    region = var.aws_region
#  }
# }

# This is just an example for how to get the default gateway created automatically for every customer network in Confluent Cloud
# We use a dedicated egress gateway instead here, for thre reasons stated above.
data "confluent_gateway" "gw" {
  id = confluent_network.network.gateway[0].id
  environment {
    id = confluent_environment.example_env.id
  }
}

resource "confluent_access_point" "rds_db" {
  display_name = "${local.resource_prefix}-rds-db"
  environment {
    id = confluent_environment.example_env.id
  }
  gateway {
    id = data.confluent_gateway.gw.id
  }
  aws_egress_private_link_endpoint {
    vpc_endpoint_service_name = aws_vpc_endpoint_service.rds_db.service_name
  }
  depends_on = [
    aws_vpc_endpoint_service.rds_db,
    aws_lb_target_group_attachment.rds_db,
   ]
}

resource "confluent_dns_record" "rds_db" {
  display_name = "rds_db"
  environment {
    id = confluent_environment.example_env.id
  }
  domain = aws_rds_cluster_instance.rds_db.endpoint
  gateway {
    id = data.confluent_gateway.gw.id
  }
  private_link_access_point {
    id = confluent_access_point.rds_db.id
  }
  depends_on = [ 
    aws_db_subnet_group.subnet_group
  ]
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
    "name"                      = "PostgresSource_rds_db"
    "connector.class"           = "PostgresSource"
    "kafka.auth.mode"           = "SERVICE_ACCOUNT"
    "kafka.service.account.id"  = confluent_service_account.database_service_account.id
    "connection.host"           = aws_rds_cluster_instance.rds_db.endpoint
    "connection.port"           = aws_rds_cluster_instance.rds_db.port
    "connection.user"           = var.database_username
    "connection.password"       = var.database_password
    "ssl.mode"                  = "prefer"
    "db.name"                   = var.database_name
    "database.server.name"      = "${local.resource_prefix}-rds-db"
    "output.data.format"        = "AVRO",
    "tasks.max"                 = "1",
    "db.timezone"               = "UTC",
    "table.include.list"        = ".*",
    #"table.exclude.list"        = ".*",
    "topic.prefix"              = var.database_topic_profix
  }

  depends_on = [
    confluent_access_point.rds_db,
    confluent_role_binding.database_service_account_developer_manage,
    confluent_role_binding.database_service_account_developer_write,
    confluent_role_binding.database_service_account_sr_manage,
  ]
}

# This code will generate a lambda which checks and updates the load balancer target group IP addresses

# 1. Write the Python code into a local file
resource "local_file" "lambda_script" {
  filename = "${path.module}/index.py"
  content  = <<EOF
import boto3, socket, os

client = boto3.client('elbv2')

def handler(event, context):
    rds_endpoint = os.environ['RDS_ENDPOINT']
    tg_arn = os.environ['TARGET_GROUP_ARN']
    tn_port = os.environ['TARGET_GROUP_PORT']
    
    # 1. Resolve current IP
    new_ip = socket.gethostbyname(rds_endpoint)
    
    # 2. Get currently registered targets
    current_targets = client.describe_target_health(TargetGroupArn=tg_arn)
    registered_ips = [t['Target']['Id'] for t in current_targets['TargetHealthDescriptions']]
    
    # 3. Update if IP changed
    if new_ip not in registered_ips:
        if registered_ips:
            client.deregister_targets(TargetGroupArn=tg_arn, Targets=[{'Id': ip} for ip in registered_ips])
        client.register_targets(TargetGroupArn=tg_arn, Targets=[{'Id': new_ip, 'Port': tn_port}])
        print(f"Updated Target Group with new IP: {new_ip}")
EOF
}

# 2. Create the ZIP archive from the generated file
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = local_file.lambda_script.filename
  output_path = "${path.module}/lambda_function_payload.zip"

  # Ensures the zip is only created after the file is written
  depends_on = [local_file.lambda_script] 
}

resource "aws_lambda_function" "ip_updater" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256 # Triggers update on code change
  function_name = "rds_ip_target_updater"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.handler"
  runtime       = "python3.9"

  environment {
    variables = {
      RDS_ENDPOINT     = aws_rds_cluster_instance.rds_db.endpoint
      TARGET_GROUP_ARN = aws_lb_target_group.rds_db.arn
      TARGET_GROUP_PORT = var.database_port
    }
  }
}

resource "aws_cloudwatch_event_rule" "every_five_minutes" {
  name                = "trigger-rds-ip-sync"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "sync_rds_ip" {
  rule      = aws_cloudwatch_event_rule.every_five_minutes.name
  target_id = "SyncRDSIP"
  arn       = aws_lambda_function.ip_updater.arn
}

resource "aws_lambda_permission" "allow_cloudwatch" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ip_updater.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_five_minutes.arn
}

resource "aws_iam_role_policy" "lambda_tg_policy" {
  role = aws_iam_role.lambda_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:DescribeTargetHealth"
      ]
      Resource = aws_lb_target_group.rds_db.arn
    }]
  })
}

resource "aws_iam_role" "lambda_exec" {
  name = "rds-target-updater-role"

  # Trust policy allows Lambda service to use this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# 2. Attach the standard AWS Basic Execution Role
# This provides permissions for CloudWatch Logs
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Also trigger on DNS update
# Omitted in this demo, but recommended in practice. This is how you could implement it:
# 1. Enable Cloud Trail (management events, write), 
# 2. Configure cloud watch to trigger on updates of the DNS A record of the private endpoing of the RDS instance
# 3. Call the same lambda used above 
# resource "aws_cloudwatch_event_rule" "watch_rds_db_instance_dns_a_record_change" {
#   name        = "trigger-on-specific-dns-update"
#   description = "Triggers only when ${aws_rds_cluster_instance.rds_db.endpoint} A record is updated"

#   event_pattern = jsonencode({
#     source      = ["aws.route53"]
#     detail-type = ["AWS API Call via CloudTrail"]
#     detail = {
#       eventSource = ["route53.amazonaws.com"]
#       eventName   = ["ChangeResourceRecordSets"]
#       requestParameters = {
#         changeBatch = {
#           changes = {
#             resourceRecordSet = {
#               # Matches the specific DNS entry (must include trailing dot)
#               #name = [aws_rds_cluster_instance.rds_db.endpoint]
#               type = ["A"]
#             }
#           }
#         }
#       }
#     }
#   })
# }

# # 2. Target your EXISTING Lambda
# resource "aws_cloudwatch_event_target" "lambda_target" {
#   rule      = aws_cloudwatch_event_rule.watch_rds_db_instance_dns_a_record_change.name
#   target_id = "SyncRDSIP"
#   arn       = aws_lambda_function.ip_updater.arn
# }

# # 3. Grant Invoke Permission
# resource "aws_lambda_permission" "allow_eventbridge" {
#   statement_id  = "AllowExecutionFromEventBridgeSpecific"
#   action        = "lambda:InvokeFunction"
#   function_name = aws_lambda_function.ip_updater.function_name
#   principal     = "events.amazonaws.com"
#   source_arn    = aws_cloudwatch_event_rule.watch_rds_db_instance_dns_a_record_change.arn
# }

# outputs

output "database_api_key" {
    description = "database API Key"
    value = confluent_api_key.database_connector_key.id
}

output "database_api_secret" {
    description = "database API Secret"
    value = nonsensitive(confluent_api_key.database_connector_key.secret)
}
