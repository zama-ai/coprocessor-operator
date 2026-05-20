# Zama Coprocessor Operator Tooling

This repo contains Helm charts and scripts to deploy a Zama Coprocessor node on EKS, including:

* RDS PostgreSQL user provisioning
* EKS secret provisioning
* Coprocessor Helm releases
* Coprocessor infrastructure checks

## Requirements

* EKS cluster following base requirements
* [Zama Coprocessor Terraform Modules](https://github.com/zama-ai/terraform-coprocessor-modules)

## Charts

* [coprocessor-operator-check](charts/coprocessor-operator-check/)
* [coprocessor-rds-postgres-jobs](charts/coprocessor-rds-postgres-jobs/)

## License

This software is distributed under the **BSD-3-Clause-Clear** license. Read [this](LICENSE) for more details.
