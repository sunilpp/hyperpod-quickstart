"""
CloudFormation Custom Resource: Upload lifecycle scripts to S3.

Triggered during stack creation to upload on_create.sh and
provisioning_parameters.json to the S3 lifecycle bucket so HyperPod
can reference them during cluster initialization.
"""

import json
import logging
import base64
import boto3
import cfnresponse

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")


def upload_scripts(bucket, key_prefix, scripts):
    """Upload script files to S3.

    Args:
        bucket: S3 bucket name
        key_prefix: S3 key prefix (e.g., "lifecycle-scripts")
        scripts: dict of {filename: content} pairs
    """
    uploaded = []
    for filename, content in scripts.items():
        key = f"{key_prefix}/{filename}"
        # Decode base64 if encoded
        try:
            body = base64.b64decode(content)
        except Exception:
            body = content.encode("utf-8") if isinstance(content, str) else content

        s3.put_object(Bucket=bucket, Key=key, Body=body)
        uploaded.append(key)
        logger.info(f"Uploaded s3://{bucket}/{key}")
    return uploaded


def delete_scripts(bucket, key_prefix):
    """Delete uploaded scripts from S3."""
    try:
        resp = s3.list_objects_v2(Bucket=bucket, Prefix=key_prefix)
        for obj in resp.get("Contents", []):
            s3.delete_object(Bucket=bucket, Key=obj["Key"])
            logger.info(f"Deleted s3://{bucket}/{obj['Key']}")
    except Exception as e:
        logger.warning(f"Cleanup failed (non-critical): {e}")


def handler(event, context):
    logger.info(f"Event: {json.dumps(event)}")

    try:
        request_type = event["RequestType"]
        props = event.get("ResourceProperties", {})
        bucket = props.get("BucketName", "")
        key_prefix = props.get("KeyPrefix", "lifecycle-scripts")
        scripts = props.get("Scripts", {})

        if request_type in ("Create", "Update"):
            uploaded = upload_scripts(bucket, key_prefix, scripts)
            response_data = {
                "S3Uri": f"s3://{bucket}/{key_prefix}",
                "FileCount": str(len(uploaded)),
            }
            cfnresponse.send(event, context, cfnresponse.SUCCESS, response_data)

        elif request_type == "Delete":
            delete_scripts(bucket, key_prefix)
            cfnresponse.send(event, context, cfnresponse.SUCCESS, {})

    except Exception as e:
        logger.error(f"Error: {e}", exc_info=True)
        cfnresponse.send(
            event, context, cfnresponse.FAILED, {"Error": str(e)}
        )
