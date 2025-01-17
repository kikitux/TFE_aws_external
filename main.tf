data "http" "myip" {
  url = "https://api.ipify.org"
}

# data.http.myip.body

locals {
  mypublicip = data.http.myip.response_body
}

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  tags = {
    Name = "${var.tag_prefix}-vpc"
  }
}

resource "aws_subnet" "public1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone = local.az1
  tags = {
    Name = "${var.tag_prefix}-public"
  }
}

resource "aws_subnet" "private1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 11)
  availability_zone = local.az1
  tags = {
    Name = "${var.tag_prefix}-private"
  }
}

resource "aws_subnet" "private2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 12)
  availability_zone = local.az2
  tags = {
    Name = "${var.tag_prefix}-private"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.tag_prefix}-gw"
  }
}

resource "aws_route_table" "publicroutetable" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "${var.tag_prefix}-route-table-gw"
  }
}

resource "aws_route_table_association" "PublicRT1" {
  subnet_id      = aws_subnet.public1.id
  route_table_id = aws_route_table.publicroutetable.id
}



resource "aws_security_group" "default-sg" {
  vpc_id      = aws_vpc.main.id
  name        = "${var.tag_prefix}-sg"
  description = "${var.tag_prefix}-sg"

  ingress {
    description = "https from private ip"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["${local.mypublicip}/32", "0.0.0.0/0"]
  }

  ingress {
    description = "netdata listening"
    from_port   = 19999
    to_port     = 19999
    protocol    = "tcp"
    cidr_blocks = ["${local.mypublicip}/32", "0.0.0.0/0"]
  }

  ingress {
    description = "ssh from private ip"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${local.mypublicip}/32", "0.0.0.0/0"]
  }

  ingress {
    description = "replicated dashboard from internet"
    from_port   = 8800
    to_port     = 8800
    protocol    = "tcp"
    cidr_blocks = ["${local.mypublicip}/32", "0.0.0.0/0"]
  }

  ingress {
    description = "postgresql from internal"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "${var.tag_prefix}-tfe_sg"
  }
}

resource "aws_s3_bucket" "tfe-bucket" {
  bucket = "${var.tag_prefix}-bucket"
  force_destroy = true

  tags = {
    Name = "${var.tag_prefix}-bucket"
  }
}

resource "aws_s3_bucket" "tfe-bucket-software" {
  bucket = "${var.tag_prefix}-software"
  force_destroy = true

  tags = {
    Name = "${var.tag_prefix}-software"
  }
}


resource "aws_s3_object" "object_license" {
  bucket = "${var.tag_prefix}-software"
  key    = var.filename_license
  source = "files/${var.filename_license}"

  depends_on = [
    aws_s3_bucket.tfe-bucket-software
  ]

}

resource "aws_s3_bucket_acl" "tfe-bucket" {
  bucket = aws_s3_bucket.tfe-bucket.id
  acl    = "private"
}

resource "aws_iam_role" "role" {
  name = "${var.tag_prefix}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "profile" {
  name = "${var.tag_prefix}-instance"
  role = aws_iam_role.role.name
}

resource "aws_iam_role_policy" "policy" {
  name = "${var.tag_prefix}-bucket"
  role = aws_iam_role.role.id

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "VisualEditor0",
        "Effect" : "Allow",
        "Action" : [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject",
          "s3:GetBucketLocation"
        ],
        "Resource" : [
          "arn:aws:s3:::${var.tag_prefix}-bucket",
          "arn:aws:s3:::${var.tag_prefix}-software",
          "arn:aws:s3:::*/*"
        ]
      },
      {
        "Sid" : "VisualEditor1",
        "Effect" : "Allow",
        "Action" : "s3:ListAllMyBuckets",
        "Resource" : "*"
      }
    ]
  })
}

# code idea from https://itnext.io/lets-encrypt-certs-with-terraform-f870def3ce6d
data "aws_route53_zone" "base_domain" {
  name = var.dns_zonename
}

resource "tls_private_key" "private_key" {
  algorithm = "RSA"
}

resource "acme_registration" "registration" {
  account_key_pem = tls_private_key.private_key.private_key_pem
  email_address   = var.certificate_email
}

resource "acme_certificate" "certificate" {
  account_key_pem = acme_registration.registration.account_key_pem
  common_name     = "${var.dns_hostname}.${var.dns_zonename}"

  dns_challenge {
    provider = "route53"

    config = {
      AWS_HOSTED_ZONE_ID = data.aws_route53_zone.base_domain.zone_id
    }
  }

  depends_on = [acme_registration.registration]
}

resource "aws_s3_object" "certificate_artifacts_s3_objects" {
  for_each = toset(["certificate_pem", "issuer_pem", "private_key_pem"])

  bucket  = "${var.tag_prefix}-software"
  key     = each.key # TODO set your own bucket path
  content = lookup(acme_certificate.certificate, "${each.key}")
}

data "aws_route53_zone" "selected" {
  name         = var.dns_zonename
  private_zone = false
}

resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = var.dns_hostname
  type    = "A"
  ttl     = "300"
  records = [aws_eip.tfe-eip.public_ip]
  depends_on = [
    aws_eip.tfe-eip
  ]
}

resource "aws_network_interface" "tfe-priv" {
  subnet_id   = aws_subnet.public1.id
  private_ips = [cidrhost(cidrsubnet(var.vpc_cidr, 8, 1), 22)]

  tags = {
    Name = "primary_network_interface"
  }
}

resource "aws_network_interface_sg_attachment" "sg_attachment" {
  security_group_id    = aws_security_group.default-sg.id
  network_interface_id = aws_network_interface.tfe-priv.id
}

resource "aws_eip" "tfe-eip" {
  vpc = true

  instance                  = aws_instance.tfe_server.id
  associate_with_private_ip = aws_network_interface.tfe-priv.private_ip
  depends_on                = [aws_internet_gateway.gw]

  tags = {
    Name = "${var.tag_prefix}-eip"
  }
}

resource "aws_ebs_volume" "tfe_swap" {
  availability_zone = local.az1
  size              = 32
  # default is the gp2 disk
  # type              = "gp2"
  # faster disks is the IOPS version
  type = "io2"
  iops = 1000
}

resource "aws_ebs_volume" "tfe_docker" {
  availability_zone = local.az1
  size              = 100
  # default is the gp2 disk
  # type              = "gp2"
  # faster disks is the IOPS version
  type = "io2"
  iops = 2000
}

resource "aws_key_pair" "default-key" {
  key_name   = "${var.tag_prefix}-key"
  public_key = var.public_key
}

resource "aws_instance" "tfe_server" {
  ami           = var.ami
  instance_type = "t3.xlarge"
  key_name      = "${var.tag_prefix}-key"

  network_interface {
    network_interface_id = aws_network_interface.tfe-priv.id
    device_index         = 0
  }

  root_block_device {
    volume_size = 50

  }


  iam_instance_profile = aws_iam_instance_profile.profile.name

  user_data = templatefile("${path.module}/scripts/user-data.sh", {
    tag_prefix         = var.tag_prefix
    filename_license   = var.filename_license
    dns_hostname       = var.dns_hostname
    tfe-private-ip     = cidrhost(cidrsubnet(var.vpc_cidr, 8, 1), 22)
    tfe_password       = var.tfe_password
    dns_zonename       = var.dns_zonename
    pg_dbname          = aws_db_instance.default.db_name
    pg_address         = aws_db_instance.default.address
    rds_password       = var.rds_password
    tfe_bucket         = "${var.tag_prefix}-bucket"
    region             = var.region
    tfe_release_sequence = var.tfe_release_sequence
  })

  tags = {
    Name = "${var.tag_prefix}-tfe"
  }

  depends_on = [
    aws_network_interface_sg_attachment.sg_attachment, aws_db_instance.default
  ]
}

resource "aws_volume_attachment" "ebs_att_tfe_swap" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.tfe_swap.id
  instance_id = aws_instance.tfe_server.id
}

resource "aws_volume_attachment" "ebs_att_tfe_docker" {
  device_name = "/dev/sdi"
  volume_id   = aws_ebs_volume.tfe_docker.id
  instance_id = aws_instance.tfe_server.id
}

resource "aws_db_subnet_group" "default" {
  name       = "${var.tag_prefix}-main"
  subnet_ids = [aws_subnet.private1.id, aws_subnet.private2.id]

  tags = {
    Name = "My DB subnet group"
  }
}

resource "aws_db_instance" "default" {
  allocated_storage      = 10
  engine                 = "postgres"
  engine_version         = "12"
  instance_class         = "db.t3.large"
  username               = "postgres"
  password               = var.rds_password
  parameter_group_name   = "default.postgres12"
  skip_final_snapshot    = true
  db_name                = "tfe"
  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.default-sg.id]
  db_subnet_group_name   = aws_db_subnet_group.default.name
  identifier             = "${var.tag_prefix}-rds"
  tags = {
    "Name" = var.tag_prefix
  }

  depends_on = [
    aws_s3_object.certificate_artifacts_s3_objects
  ]
}