# AWS Provider Configuration
# Sets up the AWS provider with default profile and Singapore region (ap-southeast-1)
provider "aws" {
  profile = "default"
  region = "ap-southeast-1"
}

# S3 Bucket for storing images
# Creates a bucket to store original and compressed images
# force_destroy allows the bucket to be deleted even if it contains objects
resource "aws_s3_bucket" "image_bucket" {
  bucket = "image-compressor-demo-bucket-997" # replace with unique name
  force_destroy = true
}

# S3 Bucket Public Access Configuration
# Configures the bucket to allow public access (needed for the optimized images)
resource "aws_s3_bucket_public_access_block" "allow_public_policy" {
  bucket = aws_s3_bucket.image_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SQS Queue for image processing
# Creates a queue to receive notifications when new images are uploaded
# Messages stay visible for 300 seconds (5 min) and are retained for 1 day
resource "aws_sqs_queue" "image_queue" {
  name                      = "image-compression-queue"
  visibility_timeout_seconds = 300  # Time a message is invisible after being picked up
  message_retention_seconds  = 86400 # How long messages stay in queue (1 day)
}

# IAM Role for Lambda Function
# Creates an execution role that the Lambda function will assume
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

# SQS Queue Policy
# Allows the S3 bucket to send messages to the SQS queue
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

# S3 Bucket Policy for Optimized Folder
# Makes the optimized/ folder publicly readable so images can be served via CDN
resource "aws_s3_bucket_policy" "optimized_folder_policy" {
  bucket = aws_s3_bucket.image_bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "cloudfront.amazonaws.com"
        },
        Action = "s3:GetObject",
        Resource = "${aws_s3_bucket.image_bucket.arn}/optimized/*",
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.image_distribution.arn
          }
        }
      }
    ]
  })
}

# IAM Policy for Lambda Function
# Grants the Lambda function permissions to:
# - Read from SQS queue
# - Read/write from S3 bucket
# - Write CloudWatch logs
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

# Lambda Layer for Dependencies
# Creates a layer containing the Pillow library for image processing
resource "aws_lambda_layer_version" "pillow_layer" {
  filename         = "lambda_layer_payload.zip"
  layer_name       = "pillow-dependencies"
  compatible_runtimes = ["python3.11"]
  source_code_hash = filebase64sha256("lambda_layer_payload.zip")
}

# Lambda Function for Image Compression
# Creates the function that will process images from the queue
resource "aws_lambda_function" "compress_image" {
  function_name = "image-compressor"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "lambda_function.lambda_handler" # Entry point in code
  runtime       = "python3.11"
  filename      = "lambda_function_payload.zip"
  source_code_hash = filebase64sha256("lambda_function_payload.zip")
  timeout       = 60      # Maximum execution time (seconds)
  memory_size   = 512     # Memory allocation (MB)

  layers = [aws_lambda_layer_version.pillow_layer.arn] # Attach Pillow layer
}

# S3 Bucket Notification
# Configures the bucket to send events to SQS when objects are created
resource "aws_s3_bucket_notification" "s3_to_sqs" {
  bucket = aws_s3_bucket.image_bucket.id

  queue {
    events    = ["s3:ObjectCreated:*"] # Trigger on any object creation
    queue_arn = aws_sqs_queue.image_queue.arn
  }

  depends_on = [aws_sqs_queue_policy.s3_to_sqs_policy]
}

# Lambda Event Source Mapping
# Connects the SQS queue to the Lambda function (triggers Lambda when messages arrive)
resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.image_queue.arn
  function_name    = aws_lambda_function.compress_image.arn
  batch_size       = 1      # Process one message at a time
  enabled          = true   # Enable the mapping
}

# CloudFront Distribution
# Creates a CDN to serve optimized images with better performance
resource "aws_cloudfront_distribution" "image_distribution" {
  origin {
    domain_name = aws_s3_bucket.image_bucket.bucket_regional_domain_name
    origin_id   = "s3-origin-optimized"

    origin_path = "/optimized"  # Only serve files from the optimized folder
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CDN for optimized images"
  default_root_object = ""

  # Cache behavior configuration
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]  # Only allow read operations
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3-origin-optimized"

    viewer_protocol_policy = "redirect-to-https"  # Force HTTPS

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    # Cache TTL settings
    min_ttl     = 0
    default_ttl = 3600     # 1 hour
    max_ttl     = 86400    # 1 day
  }

  # No geographic restrictions
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Use default CloudFront certificate (free)
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  # Use the cheapest pricing tier (US, Canada, Europe)
  price_class = "PriceClass_100"
}