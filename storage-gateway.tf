# Terraform module to create an S3 File Gateway

# - Creates an EC2 based Storage Gateway that will allow resources in
#   a private subnet to write to an NFS mount for uploading files to
#   an S3 bucket

# - Uses a VPC endpoint to make sure that S3 uploads DO NOT occur over
#   internet

# - Creates a CloudWatch rule with an SNS target

# - Creates an SNS topic to receive CloudWatch event notifications of
#   a file upload

# - TBD: Create subscriptions to topic if you want to do something on
#   an object upload

# +------------------+
# | INPUTS TO MODULE |
# +------------------+

# ssh key for EC2
variable "ssh_key"                 { }

# +--------------+
# | Network info |
# +--------------+

# region:
variable "region"                  { }

# vpc_id:
variable "vpc_id"                  { }

# private_subnet_id:
variable "private_subnet_id"       { }

# availability_zone:
variable "availability_zone"       { }

# subnet_cidr:
# - only resources in this CIDR range will be able to
#   write to NFS mount
variable "subnet_cidr"             { }

# s3_bucket_arn:
# - S3 bucket where files will be uploaded
variable "s3_bucket_arn"           { }

# volume_size:
# - size of volume (min 150GB)
variable "volume_size"             { }

# instance_type:
# - typically at least xlarge - See https://docs.aws.amazon.com/storagegateway/latest/userguide/Requirements.html
variable "instance_type"           { }

# gateway_name:
variable "gateway_name"            { }

# timezone:
# - tz of gateway (ex: GMT-4:00)
variable "timezone"                { }

# role_name:
# - role name for gateway (leave blank if you want TF to create name)
variable "role_name"               { }

# policy_name:
# policy name for gateway (leave blank if you want TF to create name)
variable "policy_name"             { }

# ami id of the AWS Marketplace Storage Gateway appliance
data "aws_ami" "storage_gateway_ami_id" {
  owners = ["amazon"]
  most_recent = true
  
  filter {
    name = "name"
    values = ["aws-storage-gateway-1621970089"]
  }
}

# ami_id:
variable "ami_id"                  { }


# +-------------------+
# | RESOURCES CREATED |
# +-------------------+

# --> VPC endpoint <--
# aws_security_group
# aws_vpc_endpoint

# --> Storage Gateway Instance <--
# aws_instance
# aws_ebs_volume
# aws_volume_attachment
# aws_security_group

# --> Storage Gateway <--
# aws_storagegateway_gateway
# aws_storagegateway_cache

# --> IAM role for Storage Gateway <--
# aws_iam_policy
# aws_iam_role
# aws_iam_role_policy_attachment

# --> NFS share on Storage Gateway instance <--
# aws_storagegateway_nfs_file_share

# --> CloudWatch Event <--
# aws_cloudwatch_event_rule
# aws_cloudwatch_event_target

# --> SNS Topic <--
# aws_sns_topic
# aws_sns_topic_policy
# aws_sns_topic

# +--------------+
# | VPC ENDPOINT |
# +--------------+

resource "aws_security_group" "sg_vpce" {
  vpc_id = var.vpc_id
  name = "vpcendpoint-for-storage-gateway"

  # technically we only need port 80, 443 and 2049 (I think)
  ingress {
    from_port = 0
    to_port = 0
    protocol = -1
    cidr_blocks = [var.subnet_cidr]
  }
  
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  
}


# vpc endpoint (so we are not traversing interweb, also traffic is free)
resource "aws_vpc_endpoint" "vpce_storage_gateway" {
  vpc_id = var.vpc_id
  service_name = "com.amazonaws.us-east-1.storagegateway"
  subnet_ids = [var.private_subnet_id]
  security_group_ids = [aws_security_group.sg_vpce.id]
  vpc_endpoint_type = "Interface"
}


# +--------------------------+
# | STORAGE GATEWAY INSTANCE |
# +--------------------------+

# ec2 (storage gateway appliance)
resource "aws_instance" "storage_gateway" {
  ami = var.ami_id != "" ? var.ami_id : data.aws_ami.storage_gateway_ami_id.id
  instance_type = var.instance_type
  subnet_id = var.private_subnet_id
  
  vpc_security_group_ids = [aws_security_group.sg_storage_gateway.id]
  key_name               = var.ssh_key
  
  associate_public_ip_address = false

  root_block_device {
    volume_type           = "gp2"
    volume_size           = 80
    delete_on_termination = true
  }

}

data "aws_instance" "storage_gateway" {
  instance_id = aws_instance.storage_gateway.id
}

# ebs volume
resource "aws_ebs_volume" "storage_gateway_volume" {
  availability_zone = var.availability_zone
  size              = var.volume_size

  tags = {
    Name = "storage gateway"
  }
}

resource "aws_volume_attachment" "ebs_att" {
  device_name = "/dev/sdb"
  volume_id = aws_ebs_volume.storage_gateway_volume.id
  instance_id = aws_instance.storage_gateway.id
}

# security group
resource "aws_security_group" "sg_storage_gateway" {
  vpc_id = var.vpc_id
  name = "security-group-for-storage-gateway"

  # ...just in case you want to poke around on the box
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = [var.subnet_cidr]
  }

  # HTTP for getting activation key
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = [var.subnet_cidr]
  }
  
  # NFS
  ingress {
    from_port = 2049
    to_port = 2049
    protocol = "tcp"
    cidr_blocks = [var.subnet_cidr]
  }
  
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  
}


# +-----------------+
# | STORAGE GATEWAY |
# +-----------------+

data "aws_storagegateway_local_disk" "storage-gateway-data" {
  disk_node = aws_volume_attachment.ebs_att.device_name
  gateway_arn = aws_storagegateway_gateway.storage_gateway_example.arn
}

resource "aws_storagegateway_cache" "cache" {
  disk_id     = data.aws_storagegateway_local_disk.storage-gateway-data.id
  gateway_arn = aws_storagegateway_gateway.storage_gateway_example.arn
}

output "storage-gateway-ip" {
  value = data.aws_instance.storage_gateway.private_ip
}

output "nfs_file_share" {
  value = "mount -t nfs -o nolock,hard ${data.aws_instance.storage_gateway.private_ip}:/${aws_storagegateway_nfs_file_share.example.path}"
}

# storage gateway
resource "aws_storagegateway_gateway" "storage_gateway_example" {
  gateway_ip_address  = data.aws_instance.storage_gateway.private_ip
  gateway_name        = var.gateway_name
  gateway_timezone    = var.timezone
  gateway_type        = "FILE_S3"
  gateway_vpc_endpoint = aws_vpc_endpoint.vpce_storage_gateway.dns_entry[0].dns_name
}


# +----------+
# | IAM ROLE |
# +----------+

# iam policy
resource "aws_iam_policy" "policy_for_sg_s3_access" {
  name = var.policy_name != "" ? var.policy_name : ""
  # "AllowStorageGatewayAssumeBucketAccessRole16246294646260.2742595540183297"
  
  policy = jsonencode(
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "s3:GetAccelerateConfiguration",
                "s3:GetBucketLocation",
                "s3:GetBucketVersioning",
                "s3:ListBucket",
                "s3:ListBucketVersions",
                "s3:ListBucketMultipartUploads"
            ],
            "Resource": var.s3_bucket_arn
            "Effect": "Allow"
        },
        {
            "Action": [
                "s3:AbortMultipartUpload",
                "s3:DeleteObject",
                "s3:DeleteObjectVersion",
                "s3:GetObject",
                "s3:GetObjectAcl",
                "s3:GetObjectVersion",
                "s3:ListMultipartUploadParts",
                "s3:PutObject",
                "s3:PutObjectAcl"
            ],
            "Resource": "${var.s3_bucket_arn}/*",
            "Effect": "Allow"
        }
    ]
})
}


# iam role
resource "aws_iam_role" "storage_gateway_role" {
  
  name = var.role_name != "" ? var.role_name : ""
  # "StorageGatewayBucketAccessRole16246294646260.5299790342267423"
  path = "/service-role/"
  assume_role_policy = jsonencode(
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "storagegateway.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
})
}

resource "aws_iam_role_policy_attachment" "storage_gateway_policy_attachment" {
  role = aws_iam_role.storage_gateway_role.name
  policy_arn = aws_iam_policy.policy_for_sg_s3_access.arn
}


# +-----------+
# | NFS SHARE |
# +-----------+

# nfs share
resource "aws_storagegateway_nfs_file_share" "example" {
  client_list  = [var.subnet_cidr]
  gateway_arn  = aws_storagegateway_gateway.storage_gateway_example.arn
  location_arn = var.s3_bucket_arn
  role_arn     = aws_iam_role.storage_gateway_role.arn
  notification_policy = "{\"Upload\": {\"SettlingTimeInSeconds\": 60}}"
}

output "nfs_file_share_path" {
  value = aws_storagegateway_nfs_file_share.example.path
}

# cloudwatch event
resource "aws_cloudwatch_event_rule" "storage_gateway_cwe" {
  name = "storage-gateway"
  event_pattern = <<EOT
{
  "source": [
    "aws.storagegateway"
  ],
  "detail-type": [
    "Storage Gateway Object Upload Event"
  ]
}
EOT
}

resource "aws_cloudwatch_event_target" "sns" {
  rule      = aws_cloudwatch_event_rule.storage_gateway_cwe.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.storage_gateway_topic.arn
}

resource "aws_sns_topic" "storage_gateway_topic" {
  name = "storage-gateway"
}

resource "aws_sns_topic_policy" "default" {
  arn    = aws_sns_topic.storage_gateway_topic.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [aws_sns_topic.storage_gateway_topic.arn]
  }
}
