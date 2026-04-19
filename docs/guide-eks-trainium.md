# EKS + Trainium — Complete Guide

Best for Kubernetes teams optimizing cost with AWS custom silicon.

## Deploy

```bash
./scripts/deploy.sh eks-trainium YOUR_S3_BUCKET us-west-2
```

Or click the **EKS + Trainium** Launch Stack button on the [main page](../README.md).

## Connect

Same as [EKS + GPU](guide-eks-gpu.md#connect) — configure kubectl and add IAM access entry.

```bash
aws eks update-kubeconfig --name <cluster>-eks-cluster --region us-west-2
```

## Verify

```bash
kubectl get nodes
kubectl describe nodes | grep aws.amazon.com/neuron
kubectl get pods -A
```

The Neuron device plugin should show Neuron resources on each node.

## Test

```bash
kubectl apply -f examples/submit-neuron-job/eks/job.yaml
kubectl logs -f <pod-name>
```

## Key Differences from GPU

- **Neuron device plugin** instead of NVIDIA device plugin
- `aws.amazon.com/neuron` resource type instead of `nvidia.com/gpu`
- Uses `torch-neuronx` for distributed training (handles NCCOM automatically)
- Observability uses Neuron-specific dashboards when enabled

## Troubleshooting

See [EKS + GPU troubleshooting](guide-eks-gpu.md#troubleshooting) — most issues are the same. Additionally:

| Problem | Fix |
|---------|-----|
| No Neuron resources on nodes | Check `neuron-device-plugin-daemonset` is Running |
| Neuron compilation errors | Verify `NEURON_CC_FLAGS` matches your instance type (trn1 vs trn2) |
