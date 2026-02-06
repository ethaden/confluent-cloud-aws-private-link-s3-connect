# Basic setup for AWS including basic networking

locals {
  dns_domain = confluent_network.network.dns_domain
}

data "aws_vpc" "vpc" {
  id = var.aws_vpc_id
}

# Get default subnets of the VPC. Customize if necessary!
data "aws_subnets" "vpc_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.vpc.id]
  }
}

# get IDs of the subnets
data "aws_subnet" "vpc_subnet" {
  for_each = { for index, subnetid in data.aws_subnets.vpc_subnets.ids : index => subnetid }
  id       = each.value
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  bootstrap_prefix = split(".", confluent_kafka_cluster.example_aws_private_link_cluster.bootstrap_endpoint)[0]
  zone_to_availability_zone_map = { for subnet in data.aws_subnet.vpc_subnet : subnet.id => subnet.availability_zone_id }
  availability_zone_name_to_subnet_id = { for subnet in data.aws_subnet.vpc_subnet : subnet.availability_zone => subnet.id }
  # Create mapping of AWS Zone IDS to zone names, this will look something like this:
  # availability_zone_map    = {
  #    + euc1-az1 = "eu-central-1c"
  #    + euc1-az2 = "eu-central-1a"
  #    + euc1-az3 = "eu-central-1b"
  #  }
  availability_zone_map = { for subnet in data.aws_subnet.vpc_subnet : subnet.availability_zone_id => subnet.availability_zone }
  availability_zone_ids = [ for subnet in data.aws_subnet.vpc_subnet : subnet.availability_zone_id ]
}

resource "aws_security_group" "aws-private-link-to-ccloud" {
  # Ensure that SG is unique, so that this module can be used multiple times within a single VPC
  name        = "ccloud-privatelink_${local.bootstrap_prefix}_${data.aws_vpc.vpc.id}"
  description = "Confluent Cloud Private Link minimal security group for ${confluent_kafka_cluster.example_aws_private_link_cluster.bootstrap_endpoint} in ${data.aws_vpc.vpc.id}"
  vpc_id      = data.aws_vpc.vpc.id

  ingress {
    # only necessary if redirect support from http/https is desired
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.vpc.cidr_block]
    ipv6_cidr_blocks = var.use_ipv6 ? [data.aws_vpc.vpc.ipv6_cidr_block] : null
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.vpc.cidr_block]
    ipv6_cidr_blocks = var.use_ipv6 ? [data.aws_vpc.vpc.ipv6_cidr_block] : null
  }

  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.vpc.cidr_block]
    ipv6_cidr_blocks = var.use_ipv6 ? [data.aws_vpc.vpc.ipv6_cidr_block] : null
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_endpoint" "aws-private-link-to-ccloud" {
  vpc_id            = data.aws_vpc.vpc.id
  service_name      = confluent_network.network.aws[0].private_link_endpoint_service
  vpc_endpoint_type = "Interface"

  security_group_ids = [
    aws_security_group.aws-private-link-to-ccloud.id,
  ]

  subnet_ids         = toset(data.aws_subnets.vpc_subnets.ids)
  private_dns_enabled = false

  depends_on = [
    confluent_private_link_access.aws,
  ]
}

resource "aws_route53_zone" "aws-private-link-to-ccloud" {
  name = local.dns_domain

  vpc {
    vpc_id = data.aws_vpc.vpc.id
  }
  tags = local.extra_tags
}

resource "aws_route53_record" "aws-private-link-to-ccloud" {
  zone_id = aws_route53_zone.aws-private-link-to-ccloud.zone_id
  name    = "*.${aws_route53_zone.aws-private-link-to-ccloud.name}"
  type    = "CNAME"
  ttl     = "60"
  records = [
    aws_vpc_endpoint.aws-private-link-to-ccloud.dns_entry[0]["dns_name"]
  ]
}

locals {
  endpoint_prefix = split(".", aws_vpc_endpoint.aws-private-link-to-ccloud.dns_entry[0]["dns_name"])[0]
}

resource "aws_route53_record" "aws-private-link-to-ccloud-zonal" {

  for_each = local.availability_zone_map

  zone_id = aws_route53_zone.aws-private-link-to-ccloud.zone_id
  #name    = length(var.subnets_to_privatelink) == 1 ? "*" : "*.${each.key}"
  name    = "*.${each.key}"
  type    = "CNAME"
  ttl     = "60"
  records = [
    format("%s-%s%s",
      local.endpoint_prefix,
      each.value,
      replace(aws_vpc_endpoint.aws-private-link-to-ccloud.dns_entry[0]["dns_name"], local.endpoint_prefix, "")
    )
  ]
}

output "availability_zone_map" {
    description = "The AWS AZ ID map to these AZ names"
    value = local.availability_zone_map
}
