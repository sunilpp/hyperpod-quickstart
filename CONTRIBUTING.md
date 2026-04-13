# Contributing to HyperPod Quick Start

Thank you for your interest in contributing! This document provides guidelines for contributing to this project.

## How to Contribute

### Reporting Issues

- Use [GitHub Issues](../../issues) to report bugs or request features
- Include the stack variant you're using (e.g., slurm-gpu, eks-trainium)
- Include the AWS region and instance types
- For deployment failures, include the CloudFormation events (redact account IDs)

### Submitting Changes

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-change`
3. Make your changes
4. Run validation: `cfn-lint stacks/*/template.yaml modules/*/template.yaml modules/*/*.yaml`
5. Submit a pull request

### Development Guidelines

#### CloudFormation Templates

- All templates must pass `cfn-lint` with no errors
- Use nested stacks via `modules/` for shared components
- Include `Description` in every template
- Use `!Sub` for string interpolation (not `!Join` where avoidable)
- Add `Metadata::AWS::CloudFormation::Interface` for console parameter grouping
- Default parameter values should work out of the box
- Tag all resources with `ResourceNamePrefix`

#### Lifecycle Scripts

- Use `#!/bin/bash` with `set -euo pipefail`
- Log every major step to help with debugging
- Test on both Amazon Linux 2 and Ubuntu (HyperPod supports both)
- Handle errors gracefully with meaningful messages

#### Lambda Functions

- Python 3.12, boto3 only (no external dependencies)
- Always send cfnresponse (SUCCESS or FAILED)
- Include structured logging
- Timeout appropriate for the operation

#### Documentation

- Write for someone who has never used HyperPod
- Include code examples that can be copy-pasted
- Keep the main README concise; details go in `docs/`

### Testing

Before submitting a PR, verify:

1. `cfn-lint` passes on all modified templates
2. `yamllint` passes on all YAML files
3. `flake8` passes on all Python files
4. If you modified a stack, test deployment in at least one region

## Code of Conduct

This project follows the [Amazon Open Source Code of Conduct](https://aws.github.io/code-of-conduct). Please report unacceptable behavior to opensource-codeofconduct@amazon.com.

## License

By contributing, you agree that your contributions will be licensed under the Apache-2.0 License.
