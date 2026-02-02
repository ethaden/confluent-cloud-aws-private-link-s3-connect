// AWS RDS DB
resource "aws_security_group" "rds_db" {
  name = "${local.resource_prefix}-rds-db"
  vpc_id = data.aws_vpc.vpc.id

  ingress {
    from_port   = var.database_port
    to_port     = var.database_port
    protocol    = "tcp"
    description = "RDS DB"
    cidr_blocks = [data.aws_vpc.vpc.cidr_block]
    #ipv6_cidr_blocks = var.use_ipv6 ? [ data.aws_vpc.vpc.ipv6_cidr_block] : null
  }
}

resource "aws_db_subnet_group" "subnet_group" {
  name = "${local.resource_prefix}-db-subnet-group"
  subnet_ids = data.aws_subnets.vpc_subnets.ids
}

resource "aws_rds_cluster" "rds_db" {
  #vpc = 
  cluster_identifier      = "${local.resource_prefix}-rds-db"
  engine                  = "aurora-postgresql"
  #availability_zones      = local.availability_zone_ids
  availability_zones      = data.aws_availability_zones.available.names
  database_name           = var.database_name
  master_username         = var.database_username
  master_password         = var.database_password
  backup_retention_period = 5
  preferred_backup_window = "07:00-09:00"
  deletion_protection       = false  # Change to "true" in production!
  db_subnet_group_name    = var.aws_db_subnet_group_name!="" ? var.aws_db_subnet_group_name : aws_db_subnet_group.subnet_group.name
  skip_final_snapshot = true
  vpc_security_group_ids = [ aws_security_group.rds_db.id ]
  serverlessv2_scaling_configuration {
    max_capacity             = 1.0
    min_capacity             = 0.0
  }
}

resource "aws_rds_cluster_instance" "rds_db" {
  cluster_identifier = aws_rds_cluster.rds_db.id
  instance_class     = var.database_instance_class
  engine             = aws_rds_cluster.rds_db.engine
  engine_version     = aws_rds_cluster.rds_db.engine_version
  db_subnet_group_name    = var.aws_db_subnet_group_name!="" ? var.aws_db_subnet_group_name : aws_db_subnet_group.subnet_group.name
  publicly_accessible = false
  tags = local.extra_tags
}


output "database_endpoint" {
    value = "${aws_rds_cluster.rds_db.endpoint}"
}

output "database_credentials" {
    value = "${var.database_username}:${var.database_password}"
}
