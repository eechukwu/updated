provider "aws" {
  region = local.region
}

################################################################################
# Supporting Resources
################################################################################
data "aws_subnet_ids" "public_subnets" {
  vpc_id = data.aws_vpc.default.id
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

data "aws_subnet" "public_subnets" {
  for_each = data.aws_subnet_ids.public_subnets.ids
  id       = each.value
}

data "aws_vpc" "default" {
  default = true
}

################################################################################
# Local Variables
################################################################################
locals {
  region = "eu-west-2"
  name   = "devops-practise"

  instances = [
    {
      name      = "jenkins-instance"
      user_data = <<-EOT
      #!/bin/bash
      sudo yum update –y
      sudo amazon-linux-extras install java-openjdk11 -y
      sudo wget -O /etc/yum.repos.d/jenkins.repo \
        https://pkg.jenkins.io/redhat-stable/jenkins.repo
      sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
      sudo yum upgrade -y 
      sudo yum install git -y
      sudo yum install jenkins -y
      sudo systemctl start jenkins
      sudo amazon-linux-extras install epel -y
      sudo yum install ansible -y
      sudo yum install git -y
      sudo wget http://repos.fedorapeople.org/repos/dchen/apache-maven/epel-apache-maven.repo -O /etc/yum.repos.d/epel-apache-maven.repo
      sudo sed -i s/\$releasever/6/g /etc/yum.repos.d/epel-apache-maven.repo
      sudo yum install -y apache-maven
  EOT
    },
    {
      name      = "tomcaat-instance"
      user_data = <<-EOT
      #!/bin/bash
      sudo yum update –y
      sudo amazon-linux-extras install java-openjdk11 -y
      sudo amazon-linux-extras install epel -y
      sudo yum install ansible -y
      ansible-galaxy collection install community.general
      yum install -y python3-boto3
      yum install -y python3-pip
      pip3 install awscli
      aws s3 cp s3://${var.bucket_name}/ /home/ec2-user/ --recursive
      ansible-playbook /home/ec2-user/install_tomcat.yaml
      ansible-playbook /home/ec2-user/install_tomcat_admin.yaml
      EOT
    }
  ]

  tags = {
    for instance in local.instances :
    instance.name => {
      Name    = instance.name
      Project = local.name
    }
  }
}

################################################################################
# EC2 Module
################################################################################
module "ec2_instances" {
  source                      = "terraform-aws-modules/ec2-instance/aws"
  count                       = length(local.instances)
  name                        = local.instances[count.index].name
  ami                         = "ami-0b2d89eba83fd3ed9"
  instance_type               = "t2.micro"
  subnet_id                   = tolist(toset(data.aws_subnet_ids.public_subnets.ids))[0]
  vpc_security_group_ids      = [module.security_group.security_group_id]
  associate_public_ip_address = true
  key_name                    = "terraform"
  user_data_base64            = base64encode(local.instances[count.index].user_data)
  user_data_replace_on_change = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_s3_access.name
  tags                        = local.tags[local.instances[count.index].name]
}

################################################################################
# EC2 S3 Access IAM Role
################################################################################
resource "aws_iam_role" "ec2_s3_access" {
  name = "ec2-s3-access-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "ec2_s3_access" {
  role       = aws_iam_role.ec2_s3_access.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_instance_profile" "ec2_s3_access" {
  name = "ec2-s3-access-instance-profile"
  role = aws_iam_role.ec2_s3_access.name
}

################################################################################
# SG GROUP
################################################################################
module "security_group" {
  source              = "terraform-aws-modules/security-group/aws"
  version             = "~> 4.0"
  name                = local.name
  description         = "Security group for example usage with EC2 instance"
  vpc_id              = data.aws_vpc.default.id
  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["https-443-tcp", "http-80-tcp", "ssh-tcp", "all-icmp", "http-8080-tcp"]
  egress_rules        = ["all-all"]
}


################################################################################
# S3 BUCKET
################################################################################
module "s3_bucket" {
  source                   = "terraform-aws-modules/s3-bucket/aws"
  bucket                   = var.bucket_name
  acl                      = "private"
  control_object_ownership = true
  object_ownership         = "ObjectWriter"
  versioning = {
    enabled = true
  }
}

resource "aws_s3_bucket_object" "ansible_files" {
  for_each   = fileset("../ansible", "**/*")
  bucket     = module.s3_bucket.s3_bucket_id
  key        = each.value
  source     = "../ansible/${each.value}"
  etag       = filemd5("../ansible/${each.value}")
  depends_on = [module.s3_bucket]
}
