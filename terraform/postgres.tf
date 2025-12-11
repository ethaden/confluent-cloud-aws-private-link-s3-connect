// POSTGRES
resource "aws_security_group" "postgres" {
  name = "security_group_name"
  vpc_id = data.aws_vpc.vpc.id

  ingress {
    from_port   = var.postgres_port
    to_port     = var.postgres_port
    protocol    = "tcp"
    description = "PostgreSQL"
    cidr_blocks = [data.aws_vpc.vpc.cidr_block]
    ipv6_cidr_blocks = var.use_ipv6 ? [ data.aws_vpc.vpc.ipv6_cidr_block] : null
  }
}

resource "aws_db_subnet_group" "subnet_group" {
  name = "${local.resource_prefix}-db-subnet-group"
  subnet_ids = data.aws_subnets.vpc_subnets.ids
}

resource "aws_rds_cluster" "postgres" {
  #vpc = 
  cluster_identifier      = "${local.resource_prefix}-aurora"
  engine                  = "aurora-postgresql"
  #availability_zones      = local.availability_zone_ids
  availability_zones      = data.aws_availability_zones.available.names
  database_name           = var.postgres_database_name
  master_username         = var.postgres_user_name
  master_password         = var.postgres_user_password
  backup_retention_period = 5
  preferred_backup_window = "07:00-09:00"
  deletion_protection       = false  # Change to "true" in production!
  db_subnet_group_name = aws_db_subnet_group.subnet_group.name
  skip_final_snapshot = true
  vpc_security_group_ids = [ aws_security_group.postgres.id ]
  serverlessv2_scaling_configuration {
    max_capacity             = 1.0
    min_capacity             = 0.0
  }
}

resource "aws_rds_cluster_instance" "postgres" {
  cluster_identifier = aws_rds_cluster.postgres.id
  instance_class     = var.postgres_database_instance_class
  engine             = aws_rds_cluster.postgres.engine
  engine_version     = aws_rds_cluster.postgres.engine_version
  db_subnet_group_name = aws_db_subnet_group.subnet_group.name
  publicly_accessible = false
  tags = local.confluent_tags

}

# We use RDS - a native AWS service and thus can use a simple configuration here where we point directly to the Azure service
# TO BE FIXED!
#resource "aws_vpc_endpoint" "postgres" {
#  vpc_id       = data.aws_vpc.vpc.id
#  service_name = "com.amazonaws.${var.aws_region}.rds"
#}


# For a custom service, something like the following needs to be done (not tested))
# resource "aws_vpc_endpoint" "ptfe_service" {
#   vpc_id            = data.aws_vpc.vpc.id
#   service_name      = var.postgres_custom_service_name
#   vpc_endpoint_type = "Interface"

#   security_group_ids = [
#     aws_security_group.postgres_vpc_endpoint.id,
#   ]

#   subnet_ids          = data.aws_subnets.vpc_subnets.ids
#   private_dns_enabled = false
# }

# resource "aws_security_group" "postgres_vpc_endpoint" {
#   name = "${local.resource_prefix}-postgres-vpc-endpoint"
#   vpc_id = data.aws_vpc.vpc.id

#   ingress {
#     from_port   = var.postgres_port
#     to_port     = var.postgres_port
#     protocol    = "tcp"
#     description = "PostgreSQL"
#     cidr_blocks = [data.aws_vpc.vpc.cidr_block]
#     ipv6_cidr_blocks = var.use_ipv6 ? [ data.aws_vpc.vpc.ipv6_cidr_block] : null
#   }
# }

# resource "aws_route53_zone" "internal" {
#   name = "vpc.internal."

#   vpc {
#     vpc_id = data.aws_vpc.vpc.id
#   }
# }

# resource "aws_route53_record" "postgres_route53_record" {
#   zone_id = aws_route53_zone.internal.zone_id
#   name    = "postgres.${aws_route53_zone.internal.name}"
#   type    = "CNAME"
#   ttl     = "60"
#   records = [aws_rds_cluster.postgres.endpoint]
# }


output "postgres_endpoint" {
    value = "${aws_rds_cluster.postgres.endpoint}"
}

output "postgres_user_credentials" {
    value = "${var.postgres_user_name}:${var.postgres_user_password}"
}
