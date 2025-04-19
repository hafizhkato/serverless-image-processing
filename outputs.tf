output "bucket_name" {
  value = aws_s3_bucket.image_bucket.bucket
}

output "cdn_id" {
  value = aws_cloudfront_distribution.image_distribution.domain_name
}
