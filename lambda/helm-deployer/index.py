"""
CloudFormation Custom Resource: Deploy Kubernetes manifests to EKS.

Deploys device plugin DaemonSets (NVIDIA, EFA, Neuron) to the EKS cluster
using the Kubernetes API via the EKS access endpoint.

Note: For production use, consider using EKS managed add-ons or Helm charts
via a dedicated CI/CD pipeline instead of Lambda-based deployment.
"""

import json
import logging
import base64
import re
import boto3
import urllib3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

eks = boto3.client("eks")
sts = boto3.client("sts")
http = urllib3.PoolManager()


def get_eks_token(cluster_name):
    """Generate a bearer token for EKS API access using STS."""
    token = sts.generate_presigned_url(
        "get_caller_identity",
        Params={"ClusterName": cluster_name},
        ExpiresIn=60,
        HttpMethod="GET",
    )
    # EKS expects the token in a specific format
    token_prefix = "k8s-aws-v1."
    return token_prefix + base64.urlsafe_b64encode(
        token.encode("utf-8")
    ).decode("utf-8").rstrip("=")


def get_cluster_info(cluster_name):
    """Get EKS cluster endpoint and CA certificate."""
    resp = eks.describe_cluster(name=cluster_name)
    cluster = resp["cluster"]
    return {
        "endpoint": cluster["endpoint"],
        "ca_data": cluster["certificateAuthority"]["data"],
    }


def apply_manifest(endpoint, token, ca_data, manifest):
    """Apply a Kubernetes manifest via the API server."""
    kind = manifest.get("kind", "")
    metadata = manifest.get("metadata", {})
    name = metadata.get("name", "unknown")
    namespace = metadata.get("namespace", "default")

    # Map kind to API path
    api_paths = {
        "DaemonSet": f"/apis/apps/v1/namespaces/{namespace}/daemonsets",
        "Deployment": f"/apis/apps/v1/namespaces/{namespace}/deployments",
        "Service": f"/api/v1/namespaces/{namespace}/services",
        "ServiceAccount": f"/api/v1/namespaces/{namespace}/serviceaccounts",
        "ClusterRole": "/apis/rbac.authorization.k8s.io/v1/clusterroles",
        "ClusterRoleBinding": "/apis/rbac.authorization.k8s.io/v1/clusterrolebindings",
        "Namespace": "/api/v1/namespaces",
    }

    path = api_paths.get(kind)
    if not path:
        logger.warning(f"Unsupported kind: {kind}, skipping {name}")
        return False

    url = f"{endpoint}{path}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    # Try to create; if exists, update via PUT
    body = json.dumps(manifest).encode("utf-8")
    resp = http.request("POST", url, headers=headers, body=body)

    if resp.status == 201:
        logger.info(f"Created {kind}/{name}")
        return True
    elif resp.status == 409:
        # Already exists, try update
        update_url = f"{url}/{name}"
        resp = http.request("PUT", update_url, headers=headers, body=body)
        if resp.status == 200:
            logger.info(f"Updated {kind}/{name}")
            return True
        else:
            logger.warning(f"Failed to update {kind}/{name}: {resp.status}")
            return False
    else:
        logger.warning(f"Failed to create {kind}/{name}: {resp.status} {resp.data.decode()}")
        return False


def handler(event, context):
    """CloudFormation custom resource handler."""
    logger.info(f"Event: {json.dumps(event)}")

    # Import cfnresponse here to handle both Lambda and local testing
    try:
        import cfnresponse
    except ImportError:
        # Fallback for local testing
        cfnresponse = None

    def send_response(status, data=None):
        if cfnresponse:
            cfn_status = cfnresponse.SUCCESS if status == "SUCCESS" else cfnresponse.FAILED
            cfnresponse.send(event, context, cfn_status, data or {})

    try:
        request_type = event["RequestType"]
        props = event.get("ResourceProperties", {})

        if request_type == "Delete":
            send_response("SUCCESS")
            return

        cluster_name = props.get("ClusterName", "")
        compute_type = props.get("ComputeType", "gpu")

        if not cluster_name:
            send_response("FAILED", {"Error": "ClusterName is required"})
            return

        cluster_info = get_cluster_info(cluster_name)
        token = get_eks_token(cluster_name)

        manifests = props.get("Manifests", [])
        if isinstance(manifests, str):
            manifests = json.loads(manifests)

        applied = 0
        for manifest in manifests:
            if apply_manifest(
                cluster_info["endpoint"], token, cluster_info["ca_data"], manifest
            ):
                applied += 1

        send_response("SUCCESS", {
            "AppliedCount": str(applied),
            "ComputeType": compute_type,
        })

    except Exception as e:
        logger.error(f"Error: {e}", exc_info=True)
        send_response("FAILED", {"Error": str(e)})
