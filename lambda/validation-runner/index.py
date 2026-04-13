"""
Standalone validation Lambda function.

Same code as the inline Lambda in modules/validation/template.yaml,
extracted here for testing and reference.

Usage:
  python -c "from index import handler; handler({'RequestType': 'Create', ...}, None)"
"""

import json
import logging
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sm = boto3.client("sagemaker")
ec2 = boto3.client("ec2")


def check_cluster_status(cluster_name):
    """Verify cluster is InService."""
    try:
        resp = sm.describe_cluster(ClusterName=cluster_name)
        status = resp.get("ClusterStatus", "Unknown")
        logger.info(f"Cluster status: {status}")
        return status == "InService", status
    except Exception as e:
        logger.error(f"DescribeCluster failed: {e}")
        return False, str(e)


def check_cluster_nodes(cluster_name, expected_count):
    """Verify all nodes are Running and count matches expected."""
    try:
        resp = sm.list_cluster_nodes(ClusterName=cluster_name)
        nodes = resp.get("ClusterNodeSummaries", [])
        total = len(nodes)
        running = sum(
            1
            for n in nodes
            if n.get("InstanceStatus", {}).get("Status") == "Running"
        )
        logger.info(f"Nodes: {running}/{total} running, expected {expected_count}")
        return running >= expected_count, f"{running}/{total}"
    except Exception as e:
        logger.error(f"ListClusterNodes failed: {e}")
        return False, str(e)


def check_subnet_private(subnet_id):
    """Verify subnet does not assign public IPs."""
    try:
        resp = ec2.describe_subnets(SubnetIds=[subnet_id])
        is_public = resp["Subnets"][0].get("MapPublicIpOnLaunch", False)
        result = not is_public
        logger.info(f"Subnet {subnet_id} private: {result}")
        return result, "Private" if result else "PUBLIC (not recommended)"
    except Exception as e:
        logger.error(f"DescribeSubnets failed: {e}")
        return False, str(e)


def check_security_group(sg_id):
    """Verify self-referencing ingress rule exists (required for EFA)."""
    try:
        resp = ec2.describe_security_groups(GroupIds=[sg_id])
        sg = resp["SecurityGroups"][0]
        for rule in sg.get("IpPermissions", []):
            for pair in rule.get("UserIdGroupPairs", []):
                if pair.get("GroupId") == sg_id:
                    logger.info(f"SG {sg_id} has self-referencing ingress")
                    return True, "Self-ref ingress found"
        logger.warning(f"SG {sg_id} missing self-referencing ingress")
        return False, "Missing self-referencing ingress (EFA may fail)"
    except Exception as e:
        logger.error(f"DescribeSecurityGroups failed: {e}")
        return False, str(e)


def handler(event, context):
    """CloudFormation custom resource handler."""
    logger.info(f"Event: {json.dumps(event)}")

    try:
        import cfnresponse
    except ImportError:
        cfnresponse = None

    def send_response(status, data):
        if cfnresponse and context:
            cfn_status = (
                cfnresponse.SUCCESS if status == "SUCCESS" else cfnresponse.FAILED
            )
            cfnresponse.send(event, context, cfn_status, data)
        else:
            print(f"Response: {status} {json.dumps(data)}")

    if event.get("RequestType") == "Delete":
        send_response("SUCCESS", {})
        return

    props = event.get("ResourceProperties", {})
    cluster_name = props.get("ClusterName", "")
    subnet_id = props.get("SubnetId", "")
    sg_id = props.get("SecurityGroupId", "")
    expected_count = int(props.get("ExpectedWorkerCount", 2))

    results = {}
    all_critical_pass = True

    passed, detail = check_cluster_status(cluster_name)
    results["ClusterStatus"] = detail
    if not passed:
        all_critical_pass = False

    passed, detail = check_cluster_nodes(cluster_name, expected_count)
    results["NodeCount"] = detail
    if not passed:
        all_critical_pass = False

    passed, detail = check_subnet_private(subnet_id)
    results["SubnetCheck"] = detail
    if not passed:
        all_critical_pass = False

    passed, detail = check_security_group(sg_id)
    results["SecurityGroupCheck"] = detail

    results["Result"] = "PASS" if all_critical_pass else "FAIL"
    logger.info(f"Validation results: {json.dumps(results)}")

    send_response("SUCCESS" if all_critical_pass else "FAILED", results)
