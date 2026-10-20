# coprocessor-operator-check

A Helm chart to execute Coprocessor Operator pre-flight check Jobs before install or upgrade.

## Overview

This chart runs a single Kubernetes Job as a `pre-install,pre-upgrade` Helm hook. The job executes sequential checks via init containers, then the main container:

1. **k8s-check**: asserts that required namespaces, secrets, configmap, and ExternalName services exist in the cluster
2. **aws-check**: verifies the coprocessor S3 bucket is reachable via its Cloudflare custom hostname
3. **kms-check**: prints the Ethereum address of the coprocessor KMS keypair, and fails when its public key cannot be read
4. **rds-iam-token**: generates an RDS IAM authentication token for the `operator_check` database role into a shared in-memory volume
5. **db-check** (main container): logs in as `operator_check` and prints the roles, memberships, schema and table ownership, and default privileges. Fails on a connection, authentication or query error

The check never reads the RDS master credentials: `operator_check` logs in through IAM database authentication and holds no privilege beyond `CONNECT`, as every query only reads catalogs readable by any role.

### Failures

Any failing check exits non-zero, which fails the hook Job (`backoffLimit: 0`) and blocks the Helm release from proceeding:

* Init containers run in order, so the checks after a failing one do not run.
* `k8s-check` reports every missing object before failing, each with the kubectl error: `NotFound` means the object does not exist, `Forbidden` means the ServiceAccount is not allowed to read it.
* The failing container logs `<container> exited with error (exit code <n>)`.

A customised check script blocks the release by exiting non-zero. `set -e` works in it.

## Prerequisites

* `coprocessor-operator-check` ServiceAccount in the release namespace (`coproc-admin`), created with its IRSA role and RBAC by the [terraform-coprocessor-modules](https://github.com/zama-ai/terraform-coprocessor-modules) `k8s-coprocessor-deps` module (`service_accounts.operator_check`, enabled by default). The chart itself does not create any RBAC.
* Terraform provisioned infrastructure (namespaces, RDS with IAM database authentication enabled, S3 bucket, Cloudflare hostname)
* `coprocessor-operator-check` ConfigMap in the release namespace, published by the same Terraform module: `AWS_REGION`, `AWS_KMS_KEY_ID`, `DATABASE_ADDRESS`, `DATABASE_PORT` and `DATABASE_USER`
* `operator_check` database role created by the `coprocessor-db-user-setup` job ([rds-user-creation.yaml](../../helm-values/utils/rds-user-creation.yaml)): login through IAM only, no password, no privilege beyond `CONNECT`
* `secrets-bootstrap.sh` executed (populates `coprocessor-user-rds-credentials`, `registry-credentials`, etc.)

### Permissions

| Container | Kubernetes API | AWS |
| --------- | -------------- | --- |
| `k8s-check` | `get` on the checked namespaces and, in each, on the named Secrets, ConfigMaps and Services it looks up. No `list` | none |
| `aws-check` | none | none (public HTTPS request) |
| `kms-check` | none | `kms:GetPublicKey` on the coprocessor keypair |
| `rds-iam-token` | none | `rds-db:connect` as `operator_check` on the coprocessor RDS instance |
| `db-check` | none | none (database login with the token) |

When the check script is customised to look up other objects, add them to `service_accounts.operator_check.resources` in Terraform: an object the ServiceAccount cannot read is reported as MISSING with a `Forbidden` error.

> **Cross-account KMS key**
>
> When the coprocessor keypair lives in another AWS account, its key policy must also allow `kms:GetPublicKey` for the check IRSA role (`operator-check-<partner_name>-<environment>`), otherwise `kms-check` fails.

## Usage

Each run creates a Job suffixed with the release revision (for example `coprocessor-operator-check-infra-config-3`), so a check can be rerun right away. The Job and its logs are kept for `job.ttlSecondsAfterFinished` seconds (300 by default), whether it succeeds or fails:

```bash
kubectl logs -n coproc-admin -l app.kubernetes.io/instance=<release>,coprocessor-operator-check/revision=<revision> --all-containers --tail=-1
```

## Upgrading from 0.2.x

0.3.0 runs the checks as `coprocessor-operator-check` instead of `db-admin`, and logs in to the database as `operator_check` through IAM authentication instead of the master user. Before upgrading, apply the Terraform module version creating the ServiceAccount and the `coprocessor-operator-check` ConfigMap, then rerun the `coprocessor-db-user-setup` job to create the `operator_check` role.

Up to 0.2.x, a failing check only logged `<container> exited with error` and the Job still succeeded. From 0.3.0 it fails the release: check the logs of the last run for errors before upgrading.

0.2.x bound a cluster-wide `coprocessor-operator-check-reader` ClusterRole (`get`/`list` on every Secret, ConfigMap, Service and Namespace) to `db-admin` for the duration of the check. It is left behind when a check fails under Helm 3, or when a run is interrupted. Remove any leftover:

```bash
kubectl delete clusterrolebinding coprocessor-operator-check-reader --ignore-not-found
kubectl delete clusterrole coprocessor-operator-check-reader --ignore-not-found
```

## Verify permissions

```bash
SA=system:serviceaccount:coproc-admin:coprocessor-operator-check
kubectl auth can-i get secrets/coprocessor-user-rds-credentials -n coproc --as=$SA   # yes
kubectl auth can-i get secrets/any-other-secret -n coproc --as=$SA                   # no
kubectl auth can-i list secrets -n coproc --as=$SA                                   # no
kubectl auth can-i get secrets -n kube-system --as=$SA                               # no
kubectl auth can-i get namespaces/coproc --as=$SA                                    # yes
kubectl auth can-i list namespaces --as=$SA                                          # no
kubectl auth can-i list secrets -A --as=system:serviceaccount:coproc-admin:db-admin  # no
kubectl get clusterrolebinding coprocessor-operator-check-reader                     # NotFound
aws iam simulate-principal-policy --policy-source-arn <operator-check role ARN> \
  --action-names secretsmanager:GetSecretValue --resource-arns <RDS master secret ARN>   # implicitDeny
```

## Configuration

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `checks.aws.storageHostname` | Cloudflare custom hostname fronting the coprocessor S3 bucket |

Must be set in your values file (e.g. `helm-values/utils/coprocessor-operator-check.yaml`).


### Key Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `job.ttlSecondsAfterFinished` | Seconds before the completed Job is deleted | `300` |
| `serviceAccount.name` | ServiceAccount to run the job as | `coprocessor-operator-check` |
| `securityContext` | Container-level security context applied to all containers | `capabilities.drop: [ALL]` |
| `podSecurityContext` | Pod-level security context | `{}` |
| `imagePullSecrets` | Secrets for pulling images from the private registry | `[registry-credentials]` |

### Check Scripts

The shell scripts executed by each check are fully configurable in values:

```yaml
checks:
  k8s:
    script: |
      # ...
  aws:
    storageHostname: "my-bucket.example.com"
    script: |
      # ...
  db:
    script: |
      # ...
```

## Security Considerations

* The Job runs with `capabilities.drop: [ALL]` on all containers by default
* The RDS master credentials are never read: the database login uses a 15 minute IAM token for a role holding no privilege beyond `CONNECT`, written to an `emptyDir` volume backed by memory (`medium: Memory`), never touching disk
* The chart creates no RBAC: the dedicated ServiceAccount and its permissions are managed by Terraform, so a failed or interrupted check cannot leave access behind, and no production ServiceAccount (`db-admin`) is granted anything for the checks
* The ServiceAccount can only `get` the named objects the checks look up, in the checked namespaces: it cannot list or read any other Secret

## Values

See [values.yaml](values.yaml) for the complete list of configurable parameters.
