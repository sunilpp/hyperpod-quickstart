# Prerequisites

Before deploying a SageMaker HyperPod cluster with this Quick Start, make sure you have the following in place. This page walks through each requirement and tells you exactly how to verify it.

---

## 1. AWS Account

You need an AWS account with access to Amazon SageMaker HyperPod. If you do not already have an account, create one at [https://aws.amazon.com/](https://aws.amazon.com/).

> **Tip:** If you are working in an organization that uses AWS Organizations, make sure your account has not been restricted from creating the resources listed below. Check with your cloud administrator if you are unsure.

---

## 2. Supported Regions

HyperPod is not available in every AWS Region. You must deploy your stack in one of these regions:

| Region Code | Region Name |
|-------------|-------------|
| `us-east-1` | US East (N. Virginia) |
| `us-east-2` | US East (Ohio) |
| `us-west-2` | US West (Oregon) |
| `eu-west-1` | Europe (Ireland) |
| `eu-central-1` | Europe (Frankfurt) |
| `ap-northeast-1` | Asia Pacific (Tokyo) |
| `ap-southeast-1` | Asia Pacific (Singapore) |
| `ap-southeast-2` | Asia Pacific (Sydney) |

> **Tip:** `us-west-2` (Oregon) tends to have the broadest instance availability and is a good default choice if you have no regional preference.

To verify HyperPod availability in your chosen region, open the [SageMaker console](https://console.aws.amazon.com/sagemaker/) and select the region from the top-right dropdown. If you see "HyperPod" in the left navigation, the service is available.

---

## 3. Service Quotas

Every AWS account has default limits on the number and type of instances you can use. Before launching a cluster, you need to confirm you have enough quota for your chosen instance type.

### How to check your quota

1. Open the [Service Quotas console](https://console.aws.amazon.com/servicequotas/home)
2. In the left sidebar, select **AWS services**, then search for **Amazon SageMaker**
3. Search for quotas that contain "HyperPod" and your instance type (for example, `ml.p5.48xlarge`)
4. Look at the **Applied quota value** column -- this is your current limit

### Default quotas by instance type

| Instance Type | What It Provides | Minimum Needed |
|---------------|------------------|----------------|
| `ml.p5.48xlarge` | 8x NVIDIA H100 GPUs | 2 for "small", 8 for "medium", 32 for "large" |
| `ml.p4d.24xlarge` | 8x NVIDIA A100 GPUs | 2 for "small", 8 for "medium", 32 for "large" |
| `ml.g5.48xlarge` | 8x NVIDIA A10G GPUs | 2 for "small", 8 for "medium", 32 for "large" |
| `ml.trn1.32xlarge` | 16 AWS Trainium NeuronCores | 2 for "small", 8 for "medium", 32 for "large" |
| `ml.trn2.48xlarge` | 32 AWS Trainium v3 NeuronCores | 2 for "small", 8 for "medium", 32 for "large" |
| `ml.m5.2xlarge` | CPU only (Slurm controller) | 1 (Slurm stacks only) |

### How to request a quota increase

1. On the Service Quotas page for the relevant quota, choose **Request increase at account level**
2. Enter the number of instances you need (for example, 2 for a small cluster)
3. Submit the request

> **Warning:** Quota increase requests can take anywhere from a few minutes to several days. Plan ahead and submit your request before you need the capacity.

---

## 4. IAM Permissions

The user or role that creates the CloudFormation stack needs broad permissions because the stack creates resources across multiple AWS services. The simplest approach for getting started is to use an IAM user or role with the **AdministratorAccess** managed policy.

If your organization requires a least-privilege approach, the following IAM permissions cover what the stack needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cloudformation:*",
        "sagemaker:*",
        "ec2:*",
        "iam:*",
        "fsx:*",
        "s3:*",
        "eks:*",
        "aps:*",
        "grafana:*",
        "lambda:*",
        "logs:*",
        "ssm:*"
      ],
      "Resource": "*"
    }
  ]
}
```

### What each permission is used for

| Permission | Why It Is Needed |
|------------|------------------|
| `cloudformation:*` | Create, update, and delete the CloudFormation stack and its nested stacks |
| `sagemaker:*` | Create and manage the HyperPod cluster |
| `ec2:*` | Create the VPC, subnets, NAT gateway, security groups, and VPC endpoints |
| `iam:*` | Create IAM roles for the HyperPod execution role, Lambda functions, Grafana, and VPC Flow Logs |
| `fsx:*` | Create the FSx for Lustre shared filesystem |
| `s3:*` | Create and manage the S3 bucket used for lifecycle scripts and benchmark results |
| `eks:*` | Create and manage the EKS cluster (EKS stacks only) |
| `aps:*` | Create and manage the Amazon Managed Prometheus workspace |
| `grafana:*` | Create and manage the Amazon Managed Grafana workspace |
| `lambda:*` | Create Lambda functions used for validation and benchmarking |
| `logs:*` | Create CloudWatch Log Groups for VPC Flow Logs and Lambda functions |
| `ssm:*` | Create SSM documents for benchmarking; connect to Slurm nodes via Session Manager |

> **Tip:** If you are only deploying a Slurm stack (not EKS), you can remove `eks:*` from the policy. Likewise, if you disable observability, you can remove `aps:*` and `grafana:*`.

---

## 5. IAM Identity Center (AWS SSO)

Amazon Managed Grafana uses **IAM Identity Center** (formerly known as AWS SSO) for user authentication. If you want to access the Grafana dashboards (enabled by default), you must have IAM Identity Center enabled in your account.

### How to enable IAM Identity Center

1. Open the [IAM Identity Center console](https://console.aws.amazon.com/singlesignon/)
2. If prompted, choose **Enable IAM Identity Center**
3. Follow the setup wizard to create your identity source

> **Tip:** You can use the built-in identity store if you do not have an external identity provider. You just need at least one user created in IAM Identity Center to log into Grafana.

### After the stack is deployed

Once your HyperPod stack is created, you will need to assign your IAM Identity Center user to the Grafana workspace:

1. Open the [Amazon Managed Grafana console](https://console.aws.amazon.com/grafana/)
2. Select the workspace created by your stack (named `<ClusterName>-grafana`)
3. Under **Authentication**, choose **Assign new user or group**
4. Select your IAM Identity Center user and assign them the **Admin** role

---

## 6. No CLI Tools Required

For basic deployment, you do not need to install anything on your local machine. You can deploy the entire stack from the **AWS CloudFormation console** by clicking the "Launch Stack" button in the [README](../README.md).

If you prefer to deploy via the command line, or if you want to connect to your cluster after deployment, you will need:

| Tool | What It Is Used For | Install Guide |
|------|---------------------|---------------|
| AWS CLI v2 | Deploying via CLI, connecting to Slurm nodes via SSM | [Install AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| kubectl | Managing EKS clusters (EKS stacks only) | [Install kubectl](https://kubernetes.io/docs/tasks/tools/) |
| Session Manager plugin | Connecting to Slurm head nodes via `aws ssm start-session` | [Install Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) |

> **Tip:** You can always install these tools later. Start by deploying through the console, then set up CLI tools when you are ready to connect to the cluster.

---

## 7. Availability Zone Selection

HyperPod GPU and Trainium instances are not available in every Availability Zone within a region. You must choose an AZ that has capacity for your instance type.

The `AvailabilityZoneId` parameter uses AZ IDs (like `usw2-az2`), not AZ names (like `us-west-2a`). AZ IDs are consistent across accounts, while AZ names can map to different physical locations.

### How to find available AZ IDs

1. Open the [EC2 console](https://console.aws.amazon.com/ec2/)
2. In the left navigation, under **Instances**, choose **Instance Types**
3. Search for your instance type (for example, `p5.48xlarge`)
4. Select it and look at the **Networking** tab to see which AZ IDs support it

Common AZ IDs with good GPU and Trainium capacity:

| Region | Suggested AZ ID |
|--------|-----------------|
| `us-west-2` | `usw2-az2` |
| `us-east-1` | `use1-az6` |
| `us-east-2` | `use2-az2` |

> **Warning:** If you choose an AZ that does not have capacity for your instance type, the stack will fail to create. See the [Troubleshooting guide](troubleshooting/common-errors.md) for how to recover.

---

## Checklist

Before you deploy, confirm the following:

- [ ] Your AWS account is active and in good standing
- [ ] You are working in a [supported region](#2-supported-regions)
- [ ] You have [sufficient quota](#3-service-quotas) for your chosen instance type
- [ ] Your IAM user or role has the [required permissions](#4-iam-permissions)
- [ ] [IAM Identity Center](#5-iam-identity-center-aws-sso) is enabled (if you want Grafana dashboards)
- [ ] You know which [Availability Zone ID](#7-availability-zone-selection) to use

Once everything is in place, proceed to [Choosing Your Stack](02-choosing-your-stack.md).
