"""
Standalone benchmark runner Lambda function.

Same code as the inline Lambda in modules/benchmarking/template.yaml,
extracted here for testing and reference.
"""

import json
import logging
import os
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sm = boto3.client("sagemaker")
s3 = boto3.client("s3")


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

    try:
        props = event.get("ResourceProperties", {})
        cluster_name = props.get("ClusterName", "")
        compute_type = os.environ.get("COMPUTE_TYPE", "gpu")
        orchestrator = os.environ.get("ORCHESTRATOR", "slurm")
        results_bucket = os.environ.get("RESULTS_BUCKET", "")

        if compute_type == "gpu":
            benchmark_name = "NCCL AllReduce"
            manual_cmd = (
                "srun --mpi=pmix -N 2 --ntasks-per-node=8 "
                "/opt/nccl-tests/build/all_reduce_perf -b 8 -e 4G -f 2 -g 1"
                if orchestrator == "slurm"
                else "kubectl apply -f examples/nccl-benchmark-job.yaml"
            )
            expected_bw = "~900 Gbps bus bandwidth per GPU (p5.48xlarge)"
        else:
            benchmark_name = "NCCOM AllReduce"
            manual_cmd = (
                "srun -N 2 --ntasks-per-node=1 nccom-test all_reduce "
                "--data-type fp32 --size 4G"
                if orchestrator == "slurm"
                else "kubectl apply -f examples/nccom-benchmark-job.yaml"
            )
            expected_bw = "~800 Gbps (trn1.32xlarge via EFA)"

        instructions = {
            "benchmark": benchmark_name,
            "manual_command": manual_cmd,
            "expected_performance": expected_bw,
            "results_location": f"s3://{results_bucket}/benchmark-results/",
            "note": (
                "Automated benchmark execution requires SSM access to "
                "cluster nodes. Run the manual command from the cluster "
                "head node or via kubectl."
            ),
        }

        if results_bucket:
            try:
                s3.put_object(
                    Bucket=results_bucket,
                    Key="benchmark-results/instructions.json",
                    Body=json.dumps(instructions, indent=2),
                    ContentType="application/json",
                )
                logger.info("Benchmark instructions uploaded to S3")
            except Exception as e:
                logger.warning(f"Could not upload to S3: {e}")

        results = {
            "BenchmarkStatus": "INSTRUCTIONS_GENERATED",
            "ResultsS3Path": f"s3://{results_bucket}/benchmark-results/",
            "ManualRunInstructions": manual_cmd,
        }

        send_response("SUCCESS", results)

    except Exception as e:
        logger.error(f"Error: {e}", exc_info=True)
        send_response("FAILED", {"Error": str(e)})
