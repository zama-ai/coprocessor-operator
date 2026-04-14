# Zama Coprocessor Operator Kubernetes Deployment

This repo contains Helm charts and helmfile configuration to deploy a Zama Coprocessor node on EKS, including:

* RDS PostgreSQL user provisioning
* Coprocessor infrastructure pre-flight checks

## Requirements

* EKS cluster following base requirements
* [Zama Coprocessor Terraform Modules](https://github.com/zama-ai/terraform-coprocessor-modules)


## Charts

* [coprocessor-operator-check](charts/coprocessor-operator-check/)
* [coprocessor-rds-postgres-jobs](charts/coprocessor-rds-postgres-jobs/)

## License

This software is distributed under the **BSD-3-Clause-Clear** license. Read [this](LICENSE) for more details.
