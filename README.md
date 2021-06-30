# README

Terraform module to create an S3 File Gateway

* Creates an EC2 based Storage Gateway that will allow resources in
  a private subnet to write to an NFS mount for uploading files to
  an S3 bucket

* Uses a VPC endpoint to make sure that S3 uploads DO NOT occur over
  internet
  
* Restricts access to gateway to specifice subnet

* Creates a CloudWatch rule with an SNS target

* Creates an SNS topic to receive CloudWatch event notifications of
  a file upload

* Creates an NFS share that can be written to in specified subnet only

* YOUR TBD: Create subscriptions to topic if you want to do something on
  an object upload


# Example Usage:

```
module "storage-gateway" {
  source = "./modules/storage-gateway"
  
  private_subnet_id       = var.private_subnet_id
  ssh_key                 = "my-ssh-keyname"
  s3_bucket_arn           = "arn:aws:s3:::some-bucket"
  vpc_id                  = var.vpc_id
  region                  = var.region
  volume_size             = 150
  instance_type           = "t3.xlarge"
  availability_zone       = "us-east-1a"
  subnet_cidr             = "10.0.0.0/8"
  gateway_name            = "example"
  timezone                = "GMT-4:00"
  
  # use defaults...
  role_name               = ""
  policy_name             = ""
  ami_id                  = ""
}
```

# NFS Mount Command

To get the command to mount your NFS share...

```
terraform output nfs_file_share
nfs_file_share = mount -t nfs -o nolock,hard 10.1.4.128://some-bucket
```

# Storage Gateway IP

To get the IP address of the Storage Gateway...
```
terraform output storage-gateway-ip
storage-gateway-ip = 10.1.4.128
```

