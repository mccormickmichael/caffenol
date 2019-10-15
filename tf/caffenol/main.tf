terraform {
  backend "s3" {
    bucket         = "thousandleaves-terraform"
    key            = "caffenol/caffenol.tfstate"
    region         = "us-west-2"
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = "us-west-2"
}

data "terraform_remote_state" "lindome_domain" {
  backend = "s3"
  config = {
    bucket = "thousandleaves-terraform"
    key    = "lindome/domain.tfstate"
    region = "us-west-2"
  }
}

data "aws_iam_policy_document" "caffenol_s3_bucket_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.bucket.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["${aws_cloudfront_origin_access_identity.oai.iam_arn}"]
    }
  }
  statement {
    actions   =["s3:ListBucket"]
    resources = ["${aws_s3_bucket.bucket.arn}"]
    principals {
      type        = "AWS"
      identifiers = ["${aws_cloudfront_origin_access_identity.oai.iam_arn}"]
    }
  }
}

locals {
  origin_id = "caffenolS3Origin"
  domain_name = "pic.${data.terraform_remote_state.lindome_domain.outputs.treepotato_domain_name}"
}

resource "aws_s3_bucket" "bucket" {
  bucket = "thousandleaves-caffenol"
  region = "us-west-2"
}

resource "aws_s3_bucket_public_access_block" "bucket_block" {
  bucket = "${aws_s3_bucket.bucket.id}"
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = "${aws_s3_bucket.bucket.id}"
  policy = "${data.aws_iam_policy_document.caffenol_s3_bucket_policy.json}"
}

resource "aws_cloudfront_origin_access_identity" "oai" {
}

resource "aws_cloudfront_distribution" "caffenol_s3" {
  origin {
    domain_name = "${aws_s3_bucket.bucket.bucket_regional_domain_name}"
    origin_id   = "${local.origin_id}"

    s3_origin_config {
      origin_access_identity = "${aws_cloudfront_origin_access_identity.oai.cloudfront_access_identity_path}"
    }
  }
  aliases = [ "pic.treepotato.com" ]  # !! Can this be locals.domain_name?


  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "${local.origin_id}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn = data.terraform_remote_state.lindome_domain.outputs.treepotato_acm_arn
    ssl_support_method  = "sni-only"
  }
}

resource "aws_route53_record" "pic_treepotato" {
  zone_id = data.terraform_remote_state.lindome_domain.outputs.treepotato_zone_id
  name    = local.domain_name
  type    = "A"

  alias {
    evaluate_target_health = true
    zone_id                = aws_cloudfront_distribution.caffenol_s3.hosted_zone_id
    name                   = aws_cloudfront_distribution.caffenol_s3.domain_name
  }
}

output "cloudfront_dns_name" {
  value = "${aws_cloudfront_distribution.caffenol_s3.domain_name}"
}

output "cloudfront_hosted_zone" {
  value = "${aws_cloudfront_distribution.caffenol_s3.hosted_zone_id}"
}
