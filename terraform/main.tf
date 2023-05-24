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
      name      = "jenkins-server"
      user_data = <<-EOT
      #!/bin/bash
      sudo yum update –y
      sudo amazon-linux-extras install epel -y
      sudo amazon-linux-extras install java-openjdk11 -y
      sudo wget -O /etc/yum.repos.d/jenkins.repo \
        https://pkg.jenkins.io/redhat-stable/jenkins.repo
      sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
      sudo yum upgrade -y 
      sudo yum install git -y
      sudo yum install jenkins -y
      sudo sudo service jenkins start
      echo "jenkins-server" > /etc/hostname && hostnamectl set-hostname "jenkins-server"
      sudo sudo service jenkins restart
      sudo yum install git -y
      sudo mkdir /opt/maven
      sudo wget -O /opt/maven/apache-maven-3.9.2-bin.tar.gz https://dlcdn.apache.org/maven/maven-3/3.9.2/binaries/apache-maven-3.9.2-bin.tar.gz
      sudo tar -xvzf /opt/maven/apache-maven-3.9.2-bin.tar.gz -C /opt/maven
      sudo mv /opt/maven/apache-maven-3.9.2 /opt/maven/apache-maven      
      sudo rm /opt/maven/apache-maven-3.9.2-bin.tar.gz
      existing_path=$(grep -oP '(?<=^PATH=).+' ~/.bash_profile)
      echo "M2_HOME=/opt/maven/apache-maven" | sudo tee -a ~/.bash_profile >/dev/null
      echo "M2=\$M2_HOME/bin" | sudo tee -a ~/.bash_profile >/dev/null
      echo "JAVA_HOME=/usr/lib/jvm/java-11-openjdk-11.0.18.0.10-1.amzn2.0.1.x86_64" | sudo tee -a ~/.bash_profile >/dev/null
      new_path="PATH=$PATH:$HOME/.local/bin:$HOME/bin:\$M2_HOME:\$M2:\$JAVA_HOME"
      updated_path="\$PATH:$HOME/bin:$new_path"
      sed -i "s#^PATH=.*#PATH=$updated_path#" ~/.bash_profile
      sudo shutdown -r now
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
