#!/bin/bash

# Cleanup
rm -rf lambda_layer
rm -f lambda_layer_payload.zip

# Create folder structure
mkdir -p lambda_layer/python

# Use Docker to build in Amazon Linux-compatible environment
docker run --rm -v "$PWD":/var/task public.ecr.aws/sam/build-python3.11 \
  pip install -r lambda/requirements.txt -t lambda_layer/python

# Zip the layer
cd lambda_layer
zip -r ../lambda_layer_payload.zip .
cd ..

echo "✅ Layer built and zipped as lambda_layer_payload.zip"

