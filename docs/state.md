# Terraform state: where it lives, how to switch it on, how to recover it

**Status: not switched on.** Nothing has been applied, so no state exists anywhere. The pipeline plans
against an empty local state on every run. This page is the procedure for the day that changes. None of
the commands below has been run yet.

## Design

| | Where | Notes |
|---|---|---|
| State | one GCS bucket, created by `bootstrap/state` | versioned (30 old versions kept), no public access, bucket-level IAM only |
| Lock | an object next to each state file (`default.tflock`) | written and removed by Terraform; there is no lock table to create |
| Bucket name | passed at `init` time (`-backend-config`), or the `TF_STATE_BUCKET` CI/CD variable | never committed |

One bucket, one prefix per root:

| Root | State object | Applied by |
|---|---|---|
| `bootstrap/state` | `bootstrap/state/default.tfstate` | a human, once |
| `bootstrap/ci` | `bootstrap/ci/default.tfstate` | a human, once |
| `envs/nonprod` | `envs/nonprod/default.tfstate` | the pipeline |

Who can touch the bucket:

| Identity | Role on the bucket | Why |
|---|---|---|
| plan service account | `roles/storage.objectViewer` | read state; it plans with `-lock=false`, so it never writes |
| apply service account | `roles/storage.objectAdmin` | write state, create and delete the lock |
| project owner (human) | owner | bootstrap, recovery |

The plan service account can be used from any branch, and it can read every state file in the bucket.
That is acceptable only because state holds no secrets here: Terraform does not run Helm and creates no
service-account keys. Keep it that way; a secret in state would be readable from any branch.

## Switching it on

Each root has a `backend.tf.disabled`. Terraform ignores it until it is renamed to `backend.tf`. Do the
steps in this order; each one depends on the one before.

Authenticate as the project owner first. Terraform and the gcs backend both read application-default
credentials:

```bash
gcloud auth application-default login
gcloud auth application-default set-quota-project <project id>
```

These credentials are one file for the whole machine, not per gcloud configuration: every other tool
on this machine that uses application-default credentials will act as this account until you run
`gcloud auth application-default revoke`.

Each root needs its own `terraform.tfvars` (copy `terraform.tfvars.example`). In `bootstrap/ci`,
`tfstate_bucket` must be the bucket that step 1 creates.

Run steps 1 to 4 in one shell; `BUCKET` is set in step 1 and used after it. The renames are committed
in step 5, not before.

### 1. Create the bucket (local state, for a moment)

```bash
cd bootstrap/state
terraform init
terraform apply
BUCKET="$(terraform output -raw tfstate_bucket)"
```

### 2. Move that state into the bucket it just created

```bash
git mv backend.tf.disabled backend.tf
terraform init -migrate-state -backend-config="bucket=$BUCKET"    # answer "yes" to copy the state
terraform plan                                                     # must say: No changes
rm -f terraform.tfstate terraform.tfstate.backup                   # the local copy is now stale
```

### 3. CI identity, with remote state from the start

```bash
cd ../ci
git mv backend.tf.disabled backend.tf
terraform init -backend-config="bucket=$BUCKET"
terraform apply
terraform output          # workload_identity_provider, plan_service_account, apply_service_account
```

Then in GitLab, Settings > CI/CD > Variables (masked, not protected): check `WIF_PROVIDER` and `PLAN_SA`
against the outputs, and add `TF_STATE_BUCKET`.

### 4. The environment

```bash
cd ../../envs/nonprod
git mv backend.tf.disabled backend.tf
terraform init -backend-config="bucket=$BUCKET"     # add -migrate-state if a local state file exists
terraform plan
```

### 5. Commit the three renames in one merge request

The pipeline's init step looks for `envs/nonprod/backend.tf`: when it is there, it passes
`TF_STATE_BUCKET`. So this commit must come after step 3, or the plan job has no bucket to read and no
right to read it.

### 6. Only now: an apply job

Add to `.gitlab-ci.yml`, with an `APPLY_SA` CI/CD variable (protected, so only protected refs get it):

```yaml
apply:
  extends: .wif
  stage: apply
  variables:
    SERVICE_ACCOUNT: $APPLY_SA
  rules:
    - if: '$CI_COMMIT_REF_PROTECTED == "true"'
      changes: *tf_changes
      when: manual
  script:
    - *wif_init
    - terraform -chdir="$TF_DIR" apply -input=false -auto-approve
```

and `apply` to `stages`. Two gates then stand in front of it: Google only lets a protected ref
impersonate the apply service account, and GitLab only hands `APPLY_SA` to protected refs.

### Later: split network and cluster

They share one root and one state today, because a plan-only repository cannot read one layer's outputs
from another layer's (non-existent) state. Once state is real, split `envs/nonprod` into `network` and
`cluster` roots with their own prefixes, the cluster reading the network through
`terraform_remote_state`. A firewall change then no longer refreshes or locks the cluster.

## Operating it

### A lock that will not go away

An apply that was killed leaves its lock object behind; every later run stops with "Error acquiring the
state lock" and prints a lock ID.

1. Make sure nothing is still running: no pipeline, no colleague's terminal.
2. `terraform force-unlock <LOCK_ID>` in that root.

Never delete the `.tflock` object by hand while something might still be writing.

### Going back to an earlier state

The bucket keeps old versions. Run this in the root whose state is wrong, with its backend initialised.

```bash
gcloud storage ls --all-versions "gs://$BUCKET/envs/nonprod/default.tfstate"
gcloud storage cp "gs://$BUCKET/envs/nonprod/default.tfstate#<GENERATION>" restored.tfstate
terraform show restored.tfstate                 # look before you put it back
terraform state push -force restored.tfstate    # see below for why -force
terraform plan                                  # what really differs from that state
```

`state push` refuses to replace a state with one that has a lower serial number, and going back is
exactly that, so `-force` is needed here. It is the only place in this document where it is.

Restoring state does not restore infrastructure. It only changes what Terraform believes exists.

### Things not to do

- Do not edit a state file by hand. Use `terraform state mv / rm / import`.
- Do not `terraform destroy` in `bootstrap/state` while any other state lives in the bucket. The bucket
  has `prevent_destroy`; removing that guard is a deliberate, separate change.
- Do not put a secret where Terraform will store it (a Helm value, a generated key, a password variable).

## Known weaknesses

- **Same project.** The bucket sits in the project it describes, and the apply service account is
  owner-equivalent there (`projectIamAdmin`), so it could delete or rewrite its own state. The usual
  answer is a separate admin project for state; there is only one project here.
- **Bucket-wide grants.** Both CI accounts are granted on the whole bucket, so the apply account can
  also write the two `bootstrap/` states it never needs. An IAM condition on the object prefix would
  narrow that; it is not written because it could not be tested without applying.
- **Plans do not lock.** A plan that runs during an apply reads the state from before that apply
  finished, so it can report differences that are about to disappear. It never reads a half-written
  file (an object is replaced in one step) and it cannot damage anything.
- **Google-managed encryption keys**, not a key of our own.
