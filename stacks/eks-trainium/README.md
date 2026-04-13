# EKS + AWS Trainium

Deploys a SageMaker HyperPod cluster with Amazon EKS orchestrator and AWS Trainium instances.

## What gets deployed

- VPC with public/private subnets, NAT gateway
- Security group with EFA rules
- Amazon EKS cluster with managed add-ons
- FSx for Lustre shared filesystem
- Trainium worker nodes (ml.trn1.32xlarge by default)
- Amazon Managed Prometheus + Grafana with Neuron dashboards (optional)
- Post-deploy validation (optional)
- NCCOM benchmarks (optional)

## Deploy

```bash
aws cloudformation create-stack \
  --stack-name my-hyperpod-eks-trn \
  --template-body file://template.yaml \
  --parameters file://params/small.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

## After deployment

```bash
# Configure kubectl
aws eks update-kubeconfig --name <cluster-name> --region us-west-2

# Check nodes
kubectl get nodes

# Check Neuron resources
kubectl describe nodes | grep aws.amazon.com/neuron

# Submit a test job
kubectl apply -f ../../examples/submit-neuron-job/eks/job.yaml
```

## Cluster sizes

| Size | Workers | NeuronCores | FSx Storage | Estimated cost |
|------|---------|-------------|-------------|----------------|
| small | 2x trn1.32xlarge | 32 | 1.2 TB | ~$50/hr |
| medium | 8x trn1.32xlarge | 128 | 4.8 TB | ~$200/hr |
| large | 32x trn1.32xlarge | 512 | 14.4 TB | ~$797/hr |
