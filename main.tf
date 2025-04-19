provider "aws" {
  profile = "default"
  region = "ap-southeast-1"
}

resource "aws_s3_bucket" "image_bucket" {
  bucket = "image-compressor-demo-bucket-997" # replace with unique name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "allow_public_policy" {
  bucket = aws_s3_bucket.image_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_sqs_queue" "image_queue" {
  name                      = "image-compression-queue"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400
}

resource "aws_iam_role" "lambda_exec_role" {
  name = "image-compressor-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_sqs_queue_policy" "s3_to_sqs_policy" {
  queue_url = aws_sqs_queue.image_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = "*"
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.image_queue.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_s3_bucket.image_bucket.arn
          }
        }
      }
    ]
  })
}

# S3 Bucket Policy to allow public read for optimized folder
resource "aws_s3_bucket_policy" "optimized_folder_policy" {
  bucket = aws_s3_bucket.image_bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = "*",
        Action = "s3:GetObject",
        Resource = "${aws_s3_bucket.image_bucket.arn}/optimized/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_sqs_policy" {
  name = "lambda-sqs-access"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.image_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.image_bucket.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# Create Lambda Layer for dependencies
resource "aws_lambda_layer_version" "pillow_layer" {
  filename         = "lambda_layer_payload.zip"
  layer_name       = "pillow-dependencies"
  compatible_runtimes = ["python3.11"]
  source_code_hash = filebase64sha256("lambda_layer_payload.zip")
}

# Lambda Function
resource "aws_lambda_function" "compress_image" {
  function_name = "image-compressor"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.11"
  filename      = "lambda_function_payload.zip"
  source_code_hash = filebase64sha256("lambda_function_payload.zip")
  timeout       = 60
  memory_size   = 512

  layers = [aws_lambda_layer_version.pillow_layer.arn]
}

resource "aws_s3_bucket_notification" "s3_to_sqs" {
  bucket = aws_s3_bucket.image_bucket.id

  queue {
    events    = ["s3:ObjectCreated:*"]
    queue_arn = aws_sqs_queue.image_queue.arn
  }

  depends_on = [aws_sqs_queue_policy.s3_to_sqs_policy]
}


resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.compress_image.arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.image_bucket.arn
}

resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.image_queue.arn
  function_name    = aws_lambda_function.compress_image.arn
  batch_size       = 1
  enabled          = true
}

# CloudFront Distribution for serving optimized images
resource "aws_cloudfront_distribution" "image_distribution" {
  origin {
    domain_name = aws_s3_bucket.image_bucket.bucket_regional_domain_name
    origin_id   = "s3-origin-optimized"

    origin_path = "/optimized"
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CDN for optimized images"
  default_root_object = ""

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3-origin-optimized"

    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  price_class = "PriceClass_100" # Cheapest option (US, Canada, Europe)
}

