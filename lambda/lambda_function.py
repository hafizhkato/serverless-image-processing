import boto3
from PIL import Image
import io
import os
import json

s3 = boto3.client('s3')

def lambda_handler(event, context):
    for record in event['Records']:
        try:
            # Each SQS message body is a JSON string of an S3 event
            message_body = json.loads(record['body'])
            s3_record = message_body['Records'][0]  # You might support multiple S3 records in future

            bucket = s3_record['s3']['bucket']['name']
            key = s3_record['s3']['object']['key']

            # Only process images from the 'uploads/' prefix
            if not key.startswith('uploads/'):
                print(f"Skipping non-upload key: {key}")
                continue

            print(f"Processing file: {key} from bucket: {bucket}")

            # Download image from S3
            image_obj = s3.get_object(Bucket=bucket, Key=key)
            image_data = image_obj['Body'].read()
            image = Image.open(io.BytesIO(image_data))

            # Compress image
            buffer = io.BytesIO()
            image.save(buffer, format='JPEG', quality=30)
            buffer.seek(0)

            # Save to 'optimized/' prefix
            output_key = key.replace('uploads/', 'optimized/')
            s3.put_object(Bucket=bucket, Key=output_key, Body=buffer, ContentType='image/jpeg')

            print(f"Successfully processed and saved to {output_key}")

        except Exception as e:
            print(f"Failed to process message: {record}")
            print(str(e))

    return {'statusCode': 200, 'body': 'Batch processed'}
