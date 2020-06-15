//----------------------------------- Provider------------------------------------------
provider "aws" {
	region = "ap-south-1"
	profile = "tf-user1"
}

//---------------------------------Key pair Generation --------------------------------------
variable "key_name" {
	default = "Generated key"
}
resource "tls_private_key" "Private_key" {
	algorithm = "RSA"
	rsa_bits  = 4096
}
resource "aws_key_pair" "Generated_keypair" {
	depends_on = [
		tls_private_key.Private_key
	]
	key_name   = "${var.key_name}"
	public_key = "${tls_private_key.Private_key.public_key_openssh}"
}
	
//----------------------------- Creating Security Group------------------------------
resource "aws_security_group" "Proj1_SG" {
  name        = "Proj1_SG"
  description = "Allow http-ssh inbound traffic"
  vpc_id      = "vpc-0379666b"

  ingress {
    from_port  = 22
    to_port      = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
	}
  ingress {
    from_port = 80
    to_port     = 80
    protocol   = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
	}
  egress {
    from_port  = 0
    to_port      = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
	}

  tags = {
    Name = "Project1_SG"
  }
}

// ----------------------------Creating aws Instance-----------------------------
resource "aws_instance" "Proj1_EC2" {
	ami = "ami-0447a12f28fddb066"
	instance_type = "t2.micro"
	key_name = aws_key_pair.Generated_keypair.key_name
	security_groups =  [ "${aws_security_group.Proj1_SG.name}" ] 	
	tags = {
		Name = "Infra_As_code" 
	}

//--------------------------- Login into instance using ssh--------------------
	connection {
		type     = "ssh"
		user     = "ec2-user"
		private_key = tls_private_key.Private_key.private_key_pem
		host     = "${aws_instance.Proj1_EC2.public_ip}"
	}
//----------------------- Setting Up the httpd services in the webserver--------------
	provisioner "remote-exec" {
		inline = [
			"sudo yum install httpd php git -y -q",
			"sudo systemctl restart httpd",
			"sudo systemctl enable httpd"
		]
	}
}

//-----------------------------------------Creating EBS-------------------------------------------
resource "aws_ebs_volume" "Proj1_EBS" {
  availability_zone = aws_instance.Proj1_EC2.availability_zone
  size              = 1
  tags = {
    Name = "Proj1_EBS"
  }
}

// ----------------------------------Attaching the EBS--------------------------------------------
resource "aws_volume_attachment" "Proj1_EBS_att" {
  device_name = "/dev/sdh"
  volume_id   = "${aws_ebs_volume.Proj1_EBS.id}"
  instance_id = "${aws_instance.Proj1_EC2.id}"
  force_detach = true
}

// ----------Mounting, And downloading the github code into the working directory---------
resource "null_resource" "mounting" {

	depends_on = [
		aws_volume_attachment.Proj1_EBS_att
	]
		
	connection {
		type     = "ssh"
		user     = "ec2-user"
		private_key = tls_private_key.Private_key.private_key_pem
		host     = aws_instance.Proj1_EC2.public_ip
	}
	
	provisioner "remote-exec" {
		inline = [
			"sudo mkfs.ext4 /dev/xvdh",
			"sudo mount /dev/xvdh  /var/www/html",
			"sudo rm -rf /var/www/html/*",
			"sudo git clone https://github.com/sunny7898/devopsal5.git /var/www/html/"
		]
	}
}

//-----------Creating an S3 bucket -one image transfer possible ---------------------------------
resource "aws_s3_bucket" "bucket1" {
	bucket = "proj1-s3"
	region = "ap-south-1"
	tags = {
		Name        = "My bucket"
	}
}
resource "aws_s3_bucket_object" "home_folder" {
	depends_on = [
		aws_s3_bucket.bucket1,
	]
	bucket  = aws_s3_bucket.bucket1.bucket
	key     = "sobj.png"
	source = "/Project_aws/Images/image.jpg"
	acl    = "public-read"
}

// -----------------Creating a Cloudfront - origin s3 --------------------------------------------

variable "oid" {
  type    = string
  default = "S3-"
}

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "creating-oai-1"
}

locals {
  s3_origin_id = "${var.oid}${aws_s3_bucket.bucket1.id}"
}

resource "aws_cloudfront_distribution" "s3_distribution" {
	depends_on = [
		aws_s3_bucket_object.home_folder,
	]
	origin {
		domain_name = "${aws_s3_bucket.bucket1.bucket_regional_domain_name}"
		origin_id   = "${local.s3_origin_id}"
	
    s3_origin_config {
		origin_access_identity = "${aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path}"
		}
	}

  enabled             = true
  is_ipv6_enabled     = true

	default_cache_behavior {
		allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
		cached_methods   = ["GET", "HEAD"]
		target_origin_id = "${local.s3_origin_id}"

		forwarded_values {
			query_string = false
		
		cookies {
        forward = "none"
		}
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }  

  price_class = "PriceClass_All"
  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations       = ["IN"]
    }
  
  }
  
  tags = {
    Environment = "production"
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
  connection {
		type     = "ssh"
		user     = "ec2-user"
		private_key = tls_private_key.Private_key.private_key_pem
		host     = "${aws_instance.Proj1_EC2.public_ip}"
	}
	provisioner "remote-exec" {
		inline = [
		"sudo su <<END",
		"echo \"<img src='http://${aws_cloudfront_distribution.s3_distribution.domain_name}/${aws_s3_bucket_object.home_folder.key}' height='200' width='200'>\" >> /var/www/html/index.php",
		"END",
		]
  }
}

data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.bucket1.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["${aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn}"]
    }
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = ["${aws_s3_bucket.bucket1.arn}"]

    principals {
      type        = "AWS"
      identifiers = ["${aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn}"]
    }
  }
}

resource "aws_s3_bucket_policy" "example" {
  bucket = "${aws_s3_bucket.bucket1.id}"
  policy = "${data.aws_iam_policy_document.s3_policy.json}"
}

resource "null_resource" "openwebsite"  {
depends_on = [
    aws_cloudfront_distribution.s3_distribution, aws_volume_attachment.Proj1_EBS_att
  ]
	/*
	provisioner "local-exec" {
	    command = "nohup firefox & http://${aws_instance.Proj1_EC2.public_ip}/"
	*/
  	}
}

