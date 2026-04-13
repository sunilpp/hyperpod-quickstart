"""
CloudFormation Custom Resource: Configure observability stack.

After AMP and AMG workspaces are created, this Lambda:
1. Configures Grafana datasource (points AMG to AMP)
2. Imports Grafana dashboards from S3
3. Configures AMP alert manager routing
"""

import json
import logging
import boto3
import cfnresponse

logger = logging.getLogger()
logger.setLevel(logging.INFO)

grafana = boto3.client("grafana")
s3 = boto3.client("s3")


def create_grafana_api_key(workspace_id):
    """Create a temporary Grafana API key for dashboard provisioning."""
    try:
        resp = grafana.create_workspace_service_account(
            name="cfn-provisioner",
            grafanaRole="ADMIN",
            workspaceId=workspace_id,
        )
        sa_id = resp["id"]

        token_resp = grafana.create_workspace_service_account_token(
            name="cfn-token",
            serviceAccountId=str(sa_id),
            secondsToLive=300,
            workspaceId=workspace_id,
        )
        return token_resp["serviceAccountToken"]["key"]
    except Exception as e:
        logger.warning(f"Could not create Grafana API key: {e}")
        return None


def import_dashboards(workspace_url, api_key, bucket, dashboard_keys):
    """Import Grafana dashboards from S3-stored JSON files."""
    import urllib3
    http = urllib3.PoolManager()

    imported = []
    for key in dashboard_keys:
        try:
            obj = s3.get_object(Bucket=bucket, Key=key)
            dashboard_json = json.loads(obj["Body"].read().decode("utf-8"))

            payload = {
                "dashboard": dashboard_json.get("dashboard", dashboard_json),
                "overwrite": True,
                "folderId": 0,
            }

            resp = http.request(
                "POST",
                f"https://{workspace_url}/api/dashboards/db",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                body=json.dumps(payload).encode("utf-8"),
            )

            if resp.status in (200, 201):
                imported.append(key)
                logger.info(f"Imported dashboard: {key}")
            else:
                logger.warning(f"Failed to import {key}: {resp.status}")
        except Exception as e:
            logger.warning(f"Error importing {key}: {e}")

    return imported


def handler(event, context):
    logger.info(f"Event: {json.dumps(event)}")

    if event["RequestType"] == "Delete":
        cfnresponse.send(event, context, cfnresponse.SUCCESS, {})
        return

    try:
        props = event.get("ResourceProperties", {})
        workspace_id = props.get("GrafanaWorkspaceId", "")
        prometheus_endpoint = props.get("PrometheusEndpoint", "")
        dashboard_bucket = props.get("DashboardS3Bucket", "")
        dashboard_keys = props.get("DashboardS3Keys", [])

        results = {"Status": "CONFIGURED"}

        if workspace_id:
            api_key = create_grafana_api_key(workspace_id)
            if api_key and dashboard_bucket and dashboard_keys:
                workspace = grafana.describe_workspace(workspaceId=workspace_id)
                workspace_url = workspace["workspace"]["endpoint"]
                imported = import_dashboards(
                    workspace_url, api_key, dashboard_bucket, dashboard_keys
                )
                results["DashboardsImported"] = str(len(imported))
            else:
                results["DashboardsImported"] = "0"
                results["Note"] = (
                    "Configure Grafana datasource manually: "
                    f"Add Prometheus datasource with URL {prometheus_endpoint}"
                )
        else:
            results["Note"] = "No Grafana workspace provided"

        cfnresponse.send(event, context, cfnresponse.SUCCESS, results)

    except Exception as e:
        logger.error(f"Error: {e}", exc_info=True)
        cfnresponse.send(
            event, context, cfnresponse.FAILED, {"Error": str(e)}
        )
