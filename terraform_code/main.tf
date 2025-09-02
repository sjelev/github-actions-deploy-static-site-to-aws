### Site Bucket 
resource "aws_s3_bucket" "aws_site_website_bucket" {
  bucket = local.s3_bucket_name
}

resource "aws_s3_bucket_website_configuration" "aws_site_website_bucket" {
  bucket = aws_s3_bucket.aws_site_website_bucket.id
  index_document { suffix = var.aws_site_root_object }
  dynamic "error_document" {
    for_each = var.aws_site_error_document != "" ? [1] : []
    content { key = var.aws_site_error_document }
  }
}

resource "aws_s3_bucket" "aws_site_website_bucket_www" {
  count  = var.aws_site_cdn_enabled ? 0 : var.aws_r53_root_domain_deploy ? 1 : 0
  bucket = "www.${local.s3_bucket_name}"
}
resource "aws_s3_bucket_website_configuration" "aws_site_website_bucket_www" {
  count  = var.aws_site_cdn_enabled ? 0 : var.aws_r53_root_domain_deploy ? 1 : 0
  bucket = aws_s3_bucket.aws_site_website_bucket_www[0].id
  redirect_all_requests_to { host_name = local.s3_bucket_name }
}

resource "aws_s3_bucket_public_access_block" "aws_site_website_bucket" {
  bucket                  = aws_s3_bucket.aws_site_website_bucket.id
  block_public_policy     = var.aws_site_cdn_enabled ? true : false
  restrict_public_buckets = var.aws_site_cdn_enabled ? true : false
  depends_on              = [aws_s3_bucket.aws_site_website_bucket]
}
resource "aws_s3_bucket_public_access_block" "aws_site_website_bucket_www" {
  count                   = var.aws_site_cdn_enabled ? 0 : var.aws_r53_root_domain_deploy ? 1 : 0
  bucket                  = aws_s3_bucket.aws_site_website_bucket_www[0].id
  block_public_policy     = false
  restrict_public_buckets = false
  depends_on              = [aws_s3_bucket.aws_site_website_bucket_www]
}

module "template_files" {
  source   = "hashicorp/dir/template"
  base_dir = var.aws_site_source_folder
}

resource "aws_s3_object" "aws_site_website_bucket" {
  for_each    = module.template_files.files
  bucket      = aws_s3_bucket.aws_site_website_bucket.id
  key         = each.key
  content_type = contains([".ts", "tsx"], substr(each.key, -3, 3)) ? "text/javascript" : each.value.content_type
  source      = each.value.source_path
  content     = each.value.content
  etag        = each.value.digests.md5
}

### Add CloudFront Origin Access Identity (OAI)
resource "aws_cloudfront_origin_access_identity" "cloudfront_oai" {
  comment = "OAI for ${local.s3_bucket_name}"
}

### Bucket policy allowing CloudFront OAI to access S3 objects
data "aws_iam_policy_document" "aws_site_bucket_policy_oai" {
  count = var.aws_site_cdn_enabled ? 1 : 0
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.aws_site_website_bucket.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.cloudfront_oai.iam_arn]
    }
  }
  depends_on = [aws_s3_bucket_public_access_block.aws_site_website_bucket]
}
resource "aws_s3_bucket_policy" "aws_site_website_bucket_policy_oai" {
  count  = var.aws_site_cdn_enabled ? 1 : 0
  bucket = aws_s3_bucket.aws_site_website_bucket.id
  policy = data.aws_iam_policy_document.aws_site_bucket_policy_oai[0].json
  depends_on = [
    aws_s3_bucket_public_access_block.aws_site_website_bucket,
    aws_s3_bucket.aws_site_website_bucket
  ]
}

### CloudFront distribution using OAI
resource "aws_cloudfront_distribution" "cdn_static_site" {
  count               = var.aws_site_cdn_enabled ? 1 : 0
  enabled             = true
  is_ipv6_enabled     = false
  default_root_object = var.aws_site_root_object
  comment             = "CDN for ${local.s3_bucket_name}"

  origin {
    domain_name = aws_s3_bucket.aws_site_website_bucket.bucket_regional_domain_name
    origin_id   = "aws_site_bucket_origin"
    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.cloudfront_oai.cloudfront_access_identity_path
    }
  }

  default_cache_behavior {
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "aws_site_bucket_origin"
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
    response_headers_policy_id = length(local.aws_site_cdn_response_headers_policy_id) > 0 ? local.aws_site_cdn_response_headers_policy_id[0] : null
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations        = []
    }
  }

  aliases = var.aws_site_cdn_aliases != "" ? local.parsed_aliases : [
    var.aws_r53_root_domain_deploy ? var.aws_r53_domain_name : "${var.aws_r53_sub_domain_name}.${var.aws_r53_domain_name}"
  ]

  viewer_certificate {
    iam_certificate_id       = data.aws_iam_server_certificate.issued.id
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_acm_certificate.sub_domain,
    aws_acm_certificate.root_domain,
    data.aws_iam_server_certificate.issued
  ]
}
