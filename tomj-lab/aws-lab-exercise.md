# Lab exercise: JFrog Kubelet Credential Provider on AWS EKS (IRSA + projected SA tokens)

This runbook mirrors [azure-lab-exercise.md](./azure-lab-exercise.md) (AKS) but uses **Amazon EKS** and **IAM Roles for Service Accounts (IRSA)** with **projected service account tokens** (KEP 4412), as described in [AWS.md](../AWS.md) (Option A, Sub-Option A2).

**Not Terraform:** Steps use **AWS CLI**, **kubectl**, and **Helm** only. You can swap in CloudFormation/CDK/Terraform later if you prefer.

**Environment file:** Edit [aws-env-secrets.sh](./aws-env-secrets.sh), then:

```bash
source tomj-lab/aws-env-secrets.sh
```

That file can set **`AWS_PROFILE`** for **IAM Identity Center (SSO)** so every command uses your SSO-based principal (e.g. `AdministratorAccess-925310216015` on account `925310216015`) instead of legacy access keys.

**JFrog:** You configure **IAM role → Artifactory user** bindings (for this path). No Artifactory OIDC provider is required for IRSA + `assume_role` / `web_identity` ([AWS.md](../AWS.md) Step 2, IAM Role Assumption).

**Component:** Helm chart **`jfrog/jfrog-credential-provider`** ([helm/Chart.yaml](./helm/Chart.yaml)).

---

## Azure vs AWS (mental model)

| Topic | Azure (your Workload Identity lab) | AWS (this lab) |
|--------|-------------------------------------|----------------|
| Workload identity | Entra app + federated credential + K8s SA JWT → JFrog OIDC exchange | IRSA: K8s SA → `AssumeRoleWithWebIdentity` → AWS creds → **signed `GetCallerIdentity`** → JFrog **AWS IAM** endpoint |
| JFrog config | OIDC provider + identity mappings on JWT `iss` / `aud` / `sub` | **REST:** `PUT .../access/api/v1/aws/iam_role` maps **`iam_role` ARN** → Artifactory **user** |
| Per-workload isolation | Different `sub` + mappings | Different **IAM role ARN** per ServiceAccount + **one binding per ARN** |
| Helm values | [examples/azure-projected-sa-values.yaml](../examples/azure-projected-sa-values.yaml) | [examples/aws-projected-sa-values.yaml](../examples/aws-projected-sa-values.yaml) |

---

## 0. Prerequisites

- **AWS CLI** v2, authenticated (`aws sts get-caller-identity`).
- **kubectl** and **Helm 3**.
- **eksctl** (recommended for OIDC association and quick clusters), or equivalent steps in the console.
- JFrog admin token for Access API (IAM role bindings).

### 0.1 IAM Identity Center (SSO)

If you use **`aws configure sso`**, keep a **named profile** and export it so CLI and tools agree:

```bash
source tomj-lab/aws-env-secrets.sh   # sets AWS_PROFILE, AWS_REGION, AWS_ACCOUNT_ID

aws sso login --profile "$AWS_PROFILE"   # when the token expires

aws sts get-caller-identity
# Expect Account = 925310216015 and an assumed-role ARN for your SSO permission set
```

**Region:** Your SSO wizard may set a **default client region** (e.g. `us-east-2`). **`AWS_REGION` must match the region where the EKS cluster lives**—if the cluster is in `us-east-1`, set `AWS_REGION=us-east-1` in `tomj-lab/aws-env-secrets.sh` after creation.

**eksctl** picks up **`AWS_PROFILE`** from the environment; if it does not, pass **`--profile "$AWS_PROFILE"`** on each command.

### 0.2 Quick checks

```bash
aws --version
aws sts get-caller-identity
```

If you do **not** use SSO, omit `AWS_PROFILE` or unset it and rely on `~/.aws/credentials`.

---

## 1. Network and EKS cluster

### 1.1 Create a cluster (pick one approach)

**A) eksctl with a **new** VPC (hits default VPC / IGW limits easily)**

```bash
eksctl create cluster \
  --name "$EKS_CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --nodes 2 \
  --managed
```

If CloudFormation fails with **“maximum number of VPCs”** or **“maximum number of internet gateways”**, your account is at EC2 networking limits. Use **B** instead of requesting a quota increase.

**B) eksctl with an **existing** VPC and subnets (recommended when limits are tight)**

You reuse the VPC that already has an **internet gateway** and **routing**; eksctl only creates the EKS control plane, node group, and IAM bits—not another VPC.

1. **Pick subnets** in **`$AWS_REGION`** (must span **at least two AZs**):
   - **Public subnets (simplest lab):** route table has `0.0.0.0/0` → existing IGW, and subnets are OK for EC2 with public IPs (default public IP on launch, or managed node group in public subnet with `privateNetworking: false`).
   - **Private subnets:** need a **NAT gateway** (usually in a public subnet) and private route tables sending `0.0.0.0/0` → NAT; node group uses `privateNetworking: true`.

2. **Copy and edit** [examples/eksctl-cluster-existing-vpc.yaml](./examples/eksctl-cluster-existing-vpc.yaml):
   - Set **`metadata.name`** / **`region`** to match **`$EKS_CLUSTER_NAME`** / **`$AWS_REGION`**.
   - Set **`vpc.id`** and **two subnet IDs** under **`vpc.subnets.public`** (or **`private`**).
   - Match **`privateNetworking`** on the node group to public vs private subnets (see comments in the file).

3. **Create** (and **associate OIDC** for IRSA — required before the JFrog credential provider):

```bash
eksctl create cluster -f tomj-lab/examples/eksctl-cluster-existing-vpc.yaml

eksctl utils associate-iam-oidc-provider \
  --cluster "$EKS_CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --approve

aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
```

Or run the bundled script after `source tomj-lab/aws-env-secrets.sh`:

```bash
./scripts/eks-create-existing-vpc.sh
```

**Discover IDs (console or CLI):**

```bash
aws ec2 describe-vpcs --region "$AWS_REGION" --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output table

aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=vpc-xxxxxxxx" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch]' \
  --output table
```

**eksctl error: subnet “mismatch between local and remote VPC config”:** Under `vpc.subnets.public` (or `private`), each **`us-east-2a` / `us-east-2b` key must name the subnet that actually lives in that AZ**. If you assign subnet A under `us-east-2a` but `describe-subnets` shows A in `us-east-2b`, eksctl fails. Fix by **moving each subnet ID under the correct AZ** (often that means **swapping the two lines**). Confirm with:

```bash
aws ec2 describe-subnets \
  --subnet-ids subnet-xxxxxxxx subnet-yyyyyyyy \
  --region "$AWS_REGION" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,VpcId]' \
  --output table
```

**EKS / ELB tags (if load balancers or auto-discovery issues appear):** AWS recommends tagging subnets used by the cluster; see [EKS subnet requirements](https://docs.aws.amazon.com/eks/latest/userguide/network_reqs.html). With explicit subnet IDs in eksctl, cluster creation often succeeds; add tags if Services of type LoadBalancer misbehave.

**Failed create cleanup:** If a previous attempt rolled back but left messages about `tomj-credential-provider-cluster`, run:

```bash
eksctl delete cluster --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME" --disable-nodegroup-eviction
```

(Only if the cluster or stacks exist; otherwise delete stuck CloudFormation stacks in the console.)

**`AlreadyExistsException: Stack [eksctl-<cluster>-cluster] already exists`:** A prior `eksctl create` left the **control-plane CloudFormation stack** (even if the stack ended in `ROLLBACK_COMPLETE`). You cannot create the same cluster name until it is removed.

1. **Preferred:** delete the whole cluster (cleans EKS + eksctl stacks):

   ```bash
   eksctl delete cluster --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME" --disable-nodegroup-eviction
   ```

2. If there is **no** EKS cluster but the stack remains, delete stack **`eksctl-<name>-cluster`** (and any **`eksctl-<name>-nodegroup-*`**) in the **CloudFormation** console, or:

   ```bash
   aws cloudformation delete-stack --stack-name "eksctl-${EKS_CLUSTER_NAME}-cluster" --region "$AWS_REGION"
   ```

   Wait until `DELETE_COMPLETE`, then run `eksctl create cluster -f ...` again.

3. **AZ label vs real zone:** When eksctl logs `us-east-2b:{subnet-... us-east-2c ...}`, the subnet’s **true AZ is the third field** (`us-east-2c`). Your YAML key must be **`us-east-2c`**, not `us-east-2b`, or the cluster can mis-schedule or fail later.

**C) Existing cluster** — ensure node groups can run the DaemonSet (Linux nodes, outbound access to Artifactory). Continue from §2 with **`eksctl utils associate-iam-oidc-provider`** if IRSA was never enabled.

### 1.2 kubeconfig

```bash
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
kubectl get nodes
```

---

## 2. EKS OIDC provider (required for IRSA)

The cluster’s **OIDC issuer** must be linked in IAM so roles can use `sts:AssumeRoleWithWebIdentity`.

**Issuer URL** (save as `OIDC_ISSUER_URL` in [aws-env-secrets.sh](./aws-env-secrets.sh)):

```bash
aws eks describe-cluster \
  --name "$EKS_CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query "cluster.identity.oidc.issuer" \
  --output text
```

**Associate provider** (eksctl):

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster "$EKS_CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --approve
```

If you skip this, `aws iam create-role` with a federated principal will fail or IRSA will not mint tokens.

---

## 3. IAM role for the workload ServiceAccount

### 3.1 Variables

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ISSUER_URL=$(aws eks describe-cluster \
  --name "$EKS_CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query "cluster.identity.oidc.issuer" \
  --output text)

# Hostname only (no https://) — used in trust policy keys
OIDC_PROVIDER_ID="${OIDC_ISSUER_URL#https://}"
```

Use your real **`NAMESPACE`** and **`SERVICE_ACCOUNT_NAME`** (from `tomj-lab/aws-env-secrets.sh`).

### 3.2 Trust policy (single ServiceAccount — most specific)

```bash
cat > aws-jfrog-irsa-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER_ID}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}",
          "${OIDC_PROVIDER_ID}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
```

Create the role:

```bash
JFROG_PULL_ROLE_NAME="jfrog-pull-${NAMESPACE}-${SERVICE_ACCOUNT_NAME}"

aws iam create-role \
  --role-name "$JFROG_PULL_ROLE_NAME" \
  --assume-role-policy-document file://jfrog-irsa-trust.json \
  --description "IRSA role for JFrog image pulls (${NAMESPACE}/${SERVICE_ACCOUNT_NAME})"

JFROG_PULL_ROLE_ARN=$(aws iam get-role --role-name "$JFROG_PULL_ROLE_NAME" --query Role.Arn --output text)
echo "$JFROG_PULL_ROLE_ARN"
```

Record **`JFROG_PULL_ROLE_ARN`** in `tomj-lab/aws-env-secrets.sh`.

### 3.3 Permissions policy (STS GetCallerIdentity)

Artifactory validates a **signed `GetCallerIdentity`** request; the role must allow that call:

```bash
cat > aws-jfrog-irsa-permissions.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowGetCallerIdentityForJFrog",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$JFROG_PULL_ROLE_NAME" \
  --policy-name "jfrog-get-caller-identity" \
  --policy-document file://aws-tmp/jfrog-irsa-permissions.json
```

### 3.4 More workloads

Repeat §3 with a **new role name** and trust `sub` for each `(namespace, serviceAccount)` pair. Map each **`JFROG_PULL_ROLE_ARN`** to the right Artifactory user in §5.

**Namespace-wide trust** (less strict): see “Option B” trust policy in [AWS.md](../AWS.md) (`StringLike` on `sub`).

---

## 4. Kubernetes ServiceAccount and pods

### 4.1 Namespace + ServiceAccount

```bash
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
```

### 4.2 Annotations (required by provider)

The provider switches to **web identity** when both annotations are present ([internal/provider/provider.go](./internal/provider/provider.go)):

```bash
kubectl annotate serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$NAMESPACE" \
  eks.amazonaws.com/role-arn="$JFROG_PULL_ROLE_ARN" \
  JFrogExchange="true" \
  --overwrite
```

### 4.3 Pods that pull Artifactory images

**What this section is asking:** §4.1–4.2 only created a **Kubernetes ServiceAccount** object and put **IRSA + JFrog** annotations on it. That does **nothing** by itself. A **Pod** (usually via a Deployment, StatefulSet, Job, CronJob, etc.) must **opt in** to that identity by setting **`spec.serviceAccountName`** to **`$SERVICE_ACCOUNT_NAME`**.

**Why it matters for the credential provider:** When the kubelet pulls an image, the JFrog plugin can use a **projected token** for the **pod’s** ServiceAccount. If the pod still uses the default `serviceAccountName: default`, that default SA does **not** have `eks.amazonaws.com/role-arn` or `JFrogExchange=true`, so the provider will not use the **web identity / IRSA** path you configured—and pulls to Artifactory can fail or fall back to the wrong role.

**What you do in practice:** In every workload manifest that references an image from your Artifactory registry, set:

```yaml
spec:
  serviceAccountName: jfrog-pull-sa   # same as $SERVICE_ACCOUNT_NAME
  containers:
    - name: app
      image: tomjfrog.jfrog.io/docker-local/myapp:1.0   # must match Helm matchImages
```

You do **not** need an Azure-style `azure.workload.identity/use` label on EKS for IRSA; the link between the SA and the IAM role is the **`eks.amazonaws.com/role-arn`** annotation on that ServiceAccount (plus EKS’s OIDC/IRSA wiring).

**`matchImages`:** The image reference (registry host / pattern) must match the **`matchImages`** list in your Helm values for the JFrog provider. Otherwise the kubelet may not invoke the plugin for that pull.

---

## 5. JFrog: map IAM role ARN → Artifactory user

For each **`JFROG_PULL_ROLE_ARN`**, create (or update) a binding ([AWS.md](../AWS.md)):

```bash
export ARTIFACTORY_ADMIN_TOKEN   # admin access token (from UI or CI; never commit)

curl -X PUT "https://${ARTIFACTORY_URL}/access/api/v1/aws/iam_role" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ARTIFACTORY_ADMIN_TOKEN}" \
  -d "{
    \"username\": \"${ARTIFACTORY_USER}\",
    \"iam_role\": \"${JFROG_PULL_ROLE_ARN}\"
  }"
```

Verify:

```bash
curl -sS "https://${ARTIFACTORY_URL}/access/api/v1/aws/iam_role/${ARTIFACTORY_USER}" \
  -H "Authorization: Bearer ${ARTIFACTORY_ADMIN_TOKEN}"
```

Use a **different Artifactory user per role** if you want isolation matching each workload role.

### 5.1 Why image pulls work after this step

The **`PUT /access/api/v1/aws/iam_role`** call is the **Artifactory-side link** that makes everything line up:

1. **IRSA:** The pull-time **projected ServiceAccount token** (with audience **`sts.amazonaws.com`**) lets the workload **assume** **`JFROG_PULL_ROLE_ARN`**.
2. **AWS → JFrog:** The kubelet credential provider uses that AWS identity and sends a **signed `sts:GetCallerIdentity`**-style request to JFrog’s AWS endpoint ([§7](./aws-lab-exercise.md#7-what-artifactory-actually-validates-this-path)).
3. **Binding:** Artifactory looks up the **caller’s IAM role ARN** in the **`/aws/iam_role`** configuration. If it finds a row whose **`iam_role`** matches **`JFROG_PULL_ROLE_ARN`**, JFrog treats the request as **username** **`${ARTIFACTORY_USER}`** and issues **registry credentials** for that user.

So pulls succeed when: **(a)** this binding matches the role the pod actually assumes, **(b)** **`${ARTIFACTORY_USER}`** can read the Docker repo, and **(c)** Helm **`matchImages`** covers your registry host. This path does **not** use JFrog **OIDC providers** or **OIDC identity mappings** (those are for **Cognito** or **Azure-style** JWT trust—see [§9](#9-alternate-path-aws-cognito-oidc--jfrog-oidc-mappings)).

---

## 6. Install the JFrog Kubelet Credential Provider (Helm)

### 6.1 Values

Start from [examples/aws-projected-sa-values.yaml](../examples/aws-projected-sa-values.yaml):

- **`artifactoryUrl`**, **`matchImages`**
- **`aws.aws_auth_method`:** `"assume_role"` (the plugin upgrades to **web identity** when the pod SA has `JFrogExchange` + `eks.amazonaws.com/role-arn`)
- **`aws.aws_role_name`:** a **fallback role ARN** if no SA annotation is present; you can set it to the same **`JFROG_PULL_ROLE_ARN`** for a single-SA lab, or a dedicated node-oriented role if you use one
- **`tokenAttributes.enabled: true`**, **`rbac.create: true`**

Chart behavior: audience **`sts.amazonaws.com`**, optional keys **`eks.amazonaws.com/role-arn`** and **`JFrogExchange`** ([helm/templates/configmap-provider.yaml](./helm/templates/configmap-provider.yaml)).

### 6.2 Install

```bash
helm repo add jfrog https://charts.jfrog.io
helm repo update

helm upgrade --install credential-provider jfrog/jfrog-credential-provider \
  --namespace jfrog \
  --create-namespace \
  -f examples/aws-projected-sa-values.yaml
```

**Lab values for `tomjfrog.jfrog.io`:** [examples/aws-projected-sa-values-tomjfrog.yaml](./examples/aws-projected-sa-values-tomjfrog.yaml) is **complete for §6.2** if you use it as the **only** `-f` file—Helm supplies the rest (binary `downloadUrl`, init/pause images, etc.) from chart defaults. You do **not** need to merge it with `aws-projected-sa-values.yaml` unless you want that file’s placeholders to override something (last `-f` wins for duplicate keys; `providerConfig` lists are replaced wholesale by the last file).

```bash
helm upgrade --install credential-provider jfrog/jfrog-credential-provider \
  --namespace jfrog \
  --create-namespace \
  -f tomj-lab/examples/aws-projected-sa-values-tomjfrog.yaml
```

Adjust or remove **`affinity`** in the values file if you do not label nodes `credentialsProviderEnabled=true`.

### 6.3 Cache vs Artifactory token TTL

Set **`aws.secret_ttl_seconds`** (Helm) so the Artifactory-issued token lives **longer** than **`defaultCacheDuration`** (see [AWS.md](../AWS.md) notes on `expires_in` for Cognito — same idea for assumed-role exchange).

---

## 7. What Artifactory actually validates (this path)

The plugin does **not** send a Kubernetes JWT to JFrog for IRSA. It uses the projected token to obtain AWS credentials, then sends a **signed AWS STS `GetCallerIdentity`** request to JFrog’s AWS token endpoint ([internal/handlers/jfrog.go](./internal/handlers/jfrog.go), [internal/provider/provider.go](./internal/provider/provider.go)).

JFrog uses the **IAM principal (role ARN)** from that request and matches it to your **`/access/api/v1/aws/iam_role`** binding. **Workload specificity** = **distinct IAM role per ServiceAccount** + **distinct binding per role**.

---

## 8. Verification

```bash
kubectl get daemonset,pods -n jfrog
```

Run a pod in **`$NAMESPACE`** with **`serviceAccountName: $SERVICE_ACCOUNT_NAME`**, image matching **`matchImages`**.

**Ready-made manifest:** [examples/k8s/jfrog-artifactory-ubuntu-deployment.yaml](./examples/k8s/jfrog-artifactory-ubuntu-deployment.yaml) (plus [examples/k8s/README.md](./examples/k8s/README.md)) deploys `tomjfrog.jfrog.io/jfcredsprov-docker-local/ubuntu:resolute` using the annotated ServiceAccount. Helm **`matchImages`** for that host: [examples/aws-projected-sa-values-tomjfrog.yaml](./examples/aws-projected-sa-values-tomjfrog.yaml).

Node logs: `/var/log/jfrog-credential-provider.log` ([README.md](./README.md)). Details: [debug.md](./debug.md).

**Negative test (permissions):** configure a **real** image in a Docker repo **without** read access for **`${ARTIFACTORY_USER}`** (e.g. `aws-eks-pull-user`), then apply [examples/k8s/jfrog-artifactory-ubuntu-deployment-negative-permission.yaml](./examples/k8s/jfrog-artifactory-ubuntu-deployment-negative-permission.yaml); see [examples/k8s/README.md](./examples/k8s/README.md#negative-test-pull-denied-by-artifactory-permissions).

### 8.1 Validated outcome: permission-denied pull (lab notes)

This lab was validated end-to-end as follows:

1. **Artifactory RBAC:** Ensure **`${ARTIFACTORY_USER}`** can **read** the happy-path Docker repo (e.g. `jfcredsprov-docker-local`) but **cannot** read a second repo used only for the negative test (lab example: **`offlimits-docker-local`** with a real tag such as **`alpine:3.23`**). Broad permission targets (e.g. repo pattern `**` for a group the user belongs to) will **defeat** the negative test until they are narrowed or the user is removed from those groups.

2. **Same Kubernetes identity as the happy path:** The negative manifest uses the **same** `serviceAccountName` and IRSA role as [jfrog-artifactory-ubuntu-deployment.yaml](./examples/k8s/jfrog-artifactory-ubuntu-deployment.yaml); only the **`image:`** registry path changes to the deny repo.

3. **Clean redeploy for a trustworthy retest:** Delete both deployments, optionally bump the **`jfrog-credential-provider-lab/pull-snapshot`** annotation on the negative Deployment (so the pod template changes), then re-apply both manifests:

   ```bash
   kubectl -n demo-namespace delete deployment ubuntu-artifactory-test ubuntu-artifactory-test-deny-perm --ignore-not-found
   kubectl apply -f tomj-lab/examples/k8s/jfrog-artifactory-ubuntu-deployment.yaml \
     -f tomj-lab/examples/k8s/jfrog-artifactory-ubuntu-deployment-negative-permission.yaml
   kubectl -n demo-namespace get pods -l 'app in (ubuntu-artifactory-test,ubuntu-artifactory-test-deny-perm)' -o wide
   kubectl -n demo-namespace describe pod -l app=ubuntu-artifactory-test-deny-perm
   ```

4. **Expected result:** **`ubuntu-artifactory-test`** reaches **`Running`**; **`ubuntu-artifactory-test-deny-perm`** stays in **`ImagePullBackOff`** / **`ErrImagePull`** with **`403 Forbidden`** on the registry manifest request (e.g. HEAD to `.../v2/<deny-repo>/<image>/manifests/<tag>`). That confirms **IRSA + IAM role binding + credential provider** are active—the failure is **Artifactory read permission** on that repository, not a missing image or anonymous registry access.

---

## 9. Alternate path: AWS Cognito OIDC + JFrog OIDC mappings

This path is **not** "EKS IR token in, Cognito user out." The plugin still runs on the **node**, reads **EC2 instance metadata** for AWS credentials, loads **Cognito app credentials** from **Secrets Manager**, calls Cognito's **`/oauth2/token`** with **`client_credentials`** and a **resource-server scope**, then exchanges that **access token** with Artifactory's OIDC token endpoint ([`internal/handlers/aws.go`](./internal/handlers/aws.go) `GetAwsOidcToken`, [`internal/handlers/jfrog.go`](./internal/handlers/jfrog.go) `ExchangeOidcArtifactoryToken`).

Detailed API snippets copy-paste live in [AWS.md](../AWS.md) (**Option B: Cognito OIDC** and **Step 2 — For Cognito OIDC Method**). This section is the **ordered lab workflow**.

**How it differs from §2–§7 (IRSA + `assume_role`):**

| | **IRSA + `assume_role` (§2–§7)** | **`cognito_oidc`** |
|--|-----------------------------------|-------------------|
| **Proof JFrog validates** | Signed **`GetCallerIdentity`** + IAM role ARN | **Cognito JWT** (`iss`, `client_id`, ...) |
| **Artifactory config** | **`PUT .../aws/iam_role`** | **`POST .../access/api/v1/oidc`** + **`.../identity_mappings`** |
| **Where Cognito / IRSA shows up** | IRSA proves **which IAM role** the pod may assume | **No IRSA for Cognito token**: node role + Secrets Manager + Cognito |
| **Helm** | `aws_auth_method: assume_role` + optional `tokenAttributes` for IRSA | `aws_auth_method: cognito_oidc` + pool / resource server / scope / `jfrog_oidc_provider_name`; keep **`tokenAttributes.enabled: false`** unless you deliberately also use IRSA (see §9.7) |

You **must pick one** `aws_auth_method` per Helm provider config ([AWS.md](../AWS.md)). To try Cognito after the IRSA lab, **upgrade or reinstall** the chart with [examples/aws-cognito-oidc-values.yaml](./examples/aws-cognito-oidc-values.yaml)—do not assume both behaviors from one mixed values file.

### 9.1 Prerequisites

- EKS nodes can reach **Secrets Manager**, **Cognito**, and **`https://<artifactory-host>`**.
- **JFrog admin token** for Access API (same idea as §5).
- **Artifactory user for OIDC only** — use a **different** user than **`${ARTIFACTORY_USER}`** from §5 (the one bound with **`PUT .../aws/iam_role`** to your IRSA role). Example: IRSA path → `aws-eks-pull-user`; Cognito path → `aws-cognito-pull-user`. That splits **RBAC** (each user can have different repo access) and makes **audits** unambiguous about which integration issued a token.

From the **repository root**, align AWS CLI region with Cognito and your cluster (see §0):

```bash
source tomj-lab/aws-env-secrets.sh   # or: export AWS_REGION=us-east-2
```

The blocks below mirror [AWS.md](../AWS.md) **Option B** and **Step 2 — For Cognito OIDC Method**, condensed into one lab order.

### 9.2 AWS: Cognito user pool, hosted domain, resource server, app client

**Why this order:** The credential provider needs a **user pool domain** (token endpoint), a **resource server** + scope, then an app client that allows **`client_credentials`** and that scope. The plugin resolves the pool by **`user_pool_name`**, reads **`DescribeUserPool.Domain`**, and builds `https://<domain>.auth.<region>.amazoncognito.com/oauth2/token` ([`internal/handlers/aws.go`](../internal/handlers/aws.go)).

Set names you will copy into [examples/aws-cognito-oidc-values.yaml](./examples/aws-cognito-oidc-values.yaml) (`aws_cognito_user_pool_name` = **`USER_POOL_NAME`**, `aws_cognito_resource_server_name` = **`RESOURCE_SERVER_NAME`**, scope = **`RESOURCE_SCOPE`**).

```bash
USER_POOL_NAME="jfrog-credentials-provider-pool"
CLIENT_NAME="jfrog-credentials-provider-client"
RESOURCE_SERVER_NAME="jfrog-resource-server"
RESOURCE_SCOPE="read"
SECRET_NAME="jfrog-cognito-credentials"

# 1) User pool
USER_POOL_ID=$(aws cognito-idp create-user-pool \
  --pool-name "$USER_POOL_NAME" \
  --query 'UserPool.Id' --output text)
echo "USER_POOL_ID=$USER_POOL_ID"

# 2) Hosted domain (prefix must be unique in this account/region; retry with another prefix if necessary)
DOMAIN_PREFIX="jfrog-lab-$(openssl rand -hex 4)"
aws cognito-idp create-user-pool-domain \
  --domain "$DOMAIN_PREFIX" \
  --user-pool-id "$USER_POOL_ID"
echo "DOMAIN_PREFIX=$DOMAIN_PREFIX"

# 3) Resource server (identifier + scope; plugin sends scope as <identifier>/<scope> to Cognito)
aws cognito-idp create-resource-server \
  --user-pool-id "$USER_POOL_ID" \
  --identifier "$RESOURCE_SERVER_NAME" \
  --name "$RESOURCE_SERVER_NAME" \
  --scopes "[{\"ScopeName\":\"${RESOURCE_SCOPE}\",\"ScopeDescription\":\"JFrog credential provider\"}]"

# 4) App client with secret
CLIENT_ID=$(aws cognito-idp create-user-pool-client \
  --user-pool-id "$USER_POOL_ID" \
  --client-name "$CLIENT_NAME" \
  --generate-secret \
  --query 'UserPoolClient.ClientId' --output text)

CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client \
  --user-pool-id "$USER_POOL_ID" \
  --client-id "$CLIENT_ID" \
  --query 'UserPoolClient.ClientSecret' --output text)

echo "CLIENT_ID=$CLIENT_ID"

# 5) Enable client_credentials + scope (required after resource server exists)
aws cognito-idp update-user-pool-client \
  --user-pool-id "$USER_POOL_ID" \
  --client-id "$CLIENT_ID" \
  --allowed-o-auth-flows client_credentials \
  --allowed-o-auth-scopes "${RESOURCE_SERVER_NAME}/${RESOURCE_SCOPE}" \
  --allowed-o-auth-flows-user-pool-client
```

**Save for Artifactory + Helm:** `USER_POOL_ID`, `DOMAIN_PREFIX`, `CLIENT_ID`, `CLIENT_SECRET`, `COGNITO_ISSUER="https://cognito-idp.${AWS_REGION}.amazonaws.com/${USER_POOL_ID}"`, and matching **`USER_POOL_NAME`**, **`RESOURCE_SERVER_NAME`**, **`RESOURCE_SCOPE`**, **`SECRET_NAME`**.

**Optional — verify token endpoint before Helm** (confirms Cognito + client + domain; expect JSON with `access_token`):

```bash
curl -sS -X POST "https://${DOMAIN_PREFIX}.auth.${AWS_REGION}.amazoncognito.com/oauth2/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_secret=${CLIENT_SECRET}" \
  --data-urlencode "scope=${RESOURCE_SERVER_NAME}/${RESOURCE_SCOPE}" | jq .
```

### 9.3 AWS: Secrets Manager (JSON shape required by the provider)

The binary expects **`client-id`** and **`client-secret`** keys ([`SecretResult`](../internal/handlers/aws.go)). Create the secret in the **same region** as `$AWS_REGION` (the node plugin uses instance metadata region when calling Secrets Manager).

```bash
aws secretsmanager create-secret \
  --name "$SECRET_NAME" \
  --secret-string "{\"client-id\":\"${CLIENT_ID}\",\"client-secret\":\"${CLIENT_SECRET}\"}"

# Optional: read back (requires same IAM principal you will grant the node role)
aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text
```

Use **`SECRET_NAME`** as Helm **`aws_cognito_user_pool_secret_name`**.

### 9.4 AWS: IAM policy on the EKS **node** role

The credential provider on each node uses the **EC2 instance profile / node IAM role**, not the pod IRSA role, for **`GetSecretValue`** and **`cognito-idp`** discovery APIs.

**Find `NODE_ROLE_NAME` (examples):**

```bash
# Managed node group → IAM role name
aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" \
  --nodegroup-name "<your-nodegroup-name>" \
  --query 'nodegroup.nodeRole' --output text
# Returns an ARN; the role *name* is the last path segment after "/role/"
```

Or from the AWS console: **EKS → cluster → Compute → Node groups → IAM role**.

Attach a least-privilege policy (new name each attempt, or reuse an existing policy ARN). **`Resource`** for Secrets Manager uses the account’s randomized suffix pattern:

```bash
NODE_ROLE_NAME="your-eks-node-role-name"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_NAME="jfrog-credential-provider-cognito-policy"

POLICY_ARN=$(aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Sid\": \"SecretsManagerRead\",
        \"Effect\": \"Allow\",
        \"Action\": \"secretsmanager:GetSecretValue\",
        \"Resource\": \"arn:aws:secretsmanager:*:${AWS_ACCOUNT_ID:-$ACCOUNT_ID}:secret:${SECRET_NAME}-*\"
      },
      {
        \"Sid\": \"CognitoRead\",
        \"Effect\": \"Allow\",
        \"Action\": [
          \"cognito-idp:ListUserPools\",
          \"cognito-idp:DescribeUserPool\",
          \"cognito-idp:ListResourceServers\"
        ],
        \"Resource\": \"*\"
      }
    ]
  }" \
  --query 'Policy.Arn' --output text)

aws iam attach-role-policy \
  --role-name "$NODE_ROLE_NAME" \
  --policy-arn "$POLICY_ARN"
```

If **`create-policy`** fails with **EntityAlreadyExists**, attach the existing policy ARN instead of creating a new one.

### 9.5 JFrog: OIDC provider + identity mapping + verify

Use admin **`ARTIFACTORY_ADMIN_TOKEN`** and host **`ARTIFACTORY_URL`** (no `https://`, same as §5). **`ARTIFACTORY_OIDC_USER`** must exist in Artifactory and have Docker read on repos under test.

```bash
export ARTIFACTORY_URL="your-instance.jfrog.io"
export ARTIFACTORY_ADMIN_TOKEN="your-admin-access-token"
export ARTIFACTORY_OIDC_USER="aws-cognito-pull-user"

OIDC_PROVIDER_NAME="aws-cognito-oidc-provider"
COGNITO_ISSUER="https://cognito-idp.${AWS_REGION}.amazonaws.com/${USER_POOL_ID}"

curl -sS -X POST "https://${ARTIFACTORY_URL}/access/api/v1/oidc" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ARTIFACTORY_ADMIN_TOKEN}" \
  -d "{
    \"name\": \"${OIDC_PROVIDER_NAME}\",
    \"issuer_url\": \"${COGNITO_ISSUER}\",
    \"description\": \"OIDC provider for AWS Cognito (lab)\",
    \"provider_type\": \"Generic OpenID Connect\",
    \"token_issuer\": \"${COGNITO_ISSUER}\",
    \"use_default_proxy\": false
  }"
```

> **⚠️ Cache vs expiry:** Set **`expires_in`** (seconds) **greater** than Helm **`defaultCacheDuration`** (e.g. `5h` → at least `18000`). See [AWS.md](../AWS.md) warning under identity mapping.

```bash
curl -sS -X POST "https://${ARTIFACTORY_URL}/access/api/v1/oidc/${OIDC_PROVIDER_NAME}/identity_mappings" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ARTIFACTORY_ADMIN_TOKEN}" \
  -d "{
    \"name\": \"${OIDC_PROVIDER_NAME}\",
    \"description\": \"AWS Cognito OIDC identity mapping (lab)\",
    \"claims\": {
      \"iss\": \"${COGNITO_ISSUER}\",
      \"client_id\": \"${CLIENT_ID}\"
    },
    \"token_spec\": {
      \"username\": \"${ARTIFACTORY_OIDC_USER}\",
      \"scope\": \"applied-permissions/user\",
      \"audience\": \"*@*\",
      \"expires_in\": 18000
    },
    \"priority\": 1
  }"

curl -sS "https://${ARTIFACTORY_URL}/access/api/v1/oidc/${OIDC_PROVIDER_NAME}" \
  -H "Authorization: Bearer ${ARTIFACTORY_ADMIN_TOKEN}" | jq .
```

No **`PUT .../aws/iam_role`** is required for this Cognito-only lab. If you still run IRSA workloads elsewhere, keep their **`/aws/iam_role`** binding on **`${ARTIFACTORY_USER}`**; do **not** reuse that username in **`token_spec.username`** unless you intend one Artifactory identity for both flows.

### 9.6 Helm: install Cognito-backed provider

Edit [examples/aws-cognito-oidc-values.yaml](./examples/aws-cognito-oidc-values.yaml). Each key below comes directly from earlier steps (same spelling you used in AWS / Artifactory).

| Helm value (under `providerConfig[0]`) | Set it from (§9.x) | What it must match |
|----------------------------------------|-------------------|---------------------|
| **`artifactoryUrl`** | **`$ARTIFACTORY_URL`** (§9.5; same as §5 / `aws-env-secrets.sh`) | Registry **hostname only** — no `https://` (e.g. `tomjfrog.jfrog.io`). |
| **`matchImages`** | Your test **image** host(s) | Each entry is a kubelet **pattern**; the image reference must match or pulls skip the plugin. Use your registry host (e.g. `tomjfrog.jfrog.io`) and/or `*.jfrog.io` like the IRSA lab — not a full repo path. |
| **`defaultCacheDuration`** | §9.5 **`expires_in`** in the identity mapping | Must be **shorter** than Artifactory’s minted token lifetime (e.g. `5h` cache vs `expires_in: 18000`). |
| **`aws.aws_cognito_user_pool_secret_name`** | **`$SECRET_NAME`** (§9.3) | Secrets Manager secret that holds `{"client-id":"...","client-secret":"..."}`. |
| **`aws.aws_cognito_user_pool_name`** | **`$USER_POOL_NAME`** (§9.2) | The **pool name** string passed to `create-user-pool --pool-name` — **not** `USER_POOL_ID`. The plugin lists pools by name. |
| **`aws.aws_cognito_resource_server_name`** | **`$RESOURCE_SERVER_NAME`** (§9.2) | The **`--name`** (and your lab’s **`--identifier`**) from `create-resource-server`. The code finds the server by **name** (case-insensitive) and uses its **identifier** in the OAuth scope. |
| **`aws.aws_cognito_user_pool_resource_scope`** | **`$RESOURCE_SCOPE`** (§9.2) | Scope **name only** (e.g. `read`), not the full `identifier/scope` string. |
| **`aws.jfrog_oidc_provider_name`** | **`$OIDC_PROVIDER_NAME`** (§9.5) | Exact **`name`** in the Artifactory **`POST .../access/api/v1/oidc`** body — the plugin sends this to **`/access/api/v1/oidc/token`**. |

**Example** — if you used the §9.2 defaults and §9.5 `OIDC_PROVIDER_NAME="aws-cognito-oidc-provider"`:

```yaml
providerConfig:
  - name: jfrog-credentials-provider
    artifactoryUrl: "tomjfrog.jfrog.io"
    matchImages:
      - "tomjfrog.jfrog.io"
      - "*.jfrog.io"
    defaultCacheDuration: 5h
    tokenAttributes:
      enabled: false
    aws:
      enabled: true
      aws_auth_method: "cognito_oidc"
      aws_cognito_user_pool_secret_name: "jfrog-cognito-credentials"
      aws_cognito_user_pool_name: "jfrog-credentials-provider-pool"
      aws_cognito_resource_server_name: "jfrog-resource-server"
      aws_cognito_user_pool_resource_scope: "read"
      jfrog_oidc_provider_name: "aws-cognito-oidc-provider"
```

Then install (from **repository root**):

```bash
helm repo add jfrog https://charts.jfrog.io && helm repo update
helm upgrade --install credential-provider jfrog/jfrog-credential-provider \
  --namespace jfrog --create-namespace \
  -f tomj-lab/examples/aws-cognito-oidc-values.yaml
```

### 9.7 Verification and pitfalls

**Workload ServiceAccount:** If the pulling pod's ServiceAccount has **`JFrogExchange: "true"`** and **`eks.amazonaws.com/role-arn`**, the provider **forces** **`web_identity`** and **`GetCallerIdentity`**, **not** Cognito ([`handleAWSAuth`](./internal/provider/provider.go)). For a pure Cognito demo, use a ServiceAccount **without** those annotations.

**Test pod:** Image host must match **`matchImages`**. Reuse [examples/k8s/jfrog-artifactory-ubuntu-deployment.yaml](./examples/k8s/jfrog-artifactory-ubuntu-deployment.yaml) only after switching to a **plain** SA or stripping IRSA annotations from `jfrog-pull-sa`; grant Docker read on your test repo to the **OIDC user** from §9.5 (not necessarily the same user as §8’s IRSA tests).

**Logs:** `/var/log/jfrog-credential-provider.log` ([debug.md](../debug.md)).

**Mental model:** **Kubernetes SA JWT to JFrog OIDC** is the **Azure** story ([azure-lab-exercise.md](./azure-lab-exercise.md)). **Cognito** here is **node to Secrets Manager to Cognito `client_credentials` to JFrog OIDC**.

### 9.8 Test cases (positive + negative)

Use a **dedicated Artifactory user** (`ARTIFACTORY_OIDC_USER` / identity mapping) and **repos you control** so results are unambiguous. Match **linux/amd64** images to **amd64** nodes (or use Graviton + arm64).

| # | Goal | Artifactory setup | Kubernetes | Expect |
|---|------|---------------------|--------------|--------|
| **P1 — Happy path** | Prove Cognito → Artifactory OIDC → pull works | Checked-in image: **`offlimits-docker-local/alpine:3.23`** (same repo name as §8 IRSA negative test). Grant **READ** on that repo to **`ARTIFACTORY_OIDC_USER`** even if **`${ARTIFACTORY_USER}`** (IRSA) is denied there — so Cognito happy path and IRSA deny test can coexist. Avoid accidental broad `**` targets. | [jfrog-artifactory-cognito-deployment.yaml](./examples/k8s/jfrog-artifactory-cognito-deployment.yaml): **plain** `cognito-plain-sa` (no IRSA annotations). | Pod **Running**; events show **Successfully pulled**. |
| **N1 — RBAC denial** | Same auth path, repo forbidden | Local Docker repo **`cognito-offlimits-docker-local`** with a real tag; **do not** grant READ to **`ARTIFACTORY_OIDC_USER`** (same caveats as §8.1 about global permission targets). | [jfrog-artifactory-cognito-deployment-negative-permission.yaml](./examples/k8s/jfrog-artifactory-cognito-deployment-negative-permission.yaml) (same namespace + SA). | **ImagePullBackOff** / **403** on manifest request in **`kubectl describe pod`**. |
| **N2 — Wrong SA (sanity)** | Confirm IRSA overrides Cognito | Any repo the OIDC user can read. | Same Deployment as P1 but use **`jfrog-pull-sa`** from the IRSA manifest (annotations **`JFrogExchange`** + **`eks.amazonaws.com/role-arn`**). | Pull may still ** succeed** using **GetCallerIdentity** / IAM-bound user — proves you left the **Cognito** path. Use **N2** only to demonstrate the pitfall; for a **Cognito** sign-off, use **P1** with **`cognito-plain-sa`**. |
| **N3 — Infra (optional)** | Cognito or secret broken | N/A | Temporarily break **Secrets Manager** secret JSON or Cognito **client_credentials** / scope (lab only). | Plugin / pull errors in **`/var/log/jfrog-credential-provider.log`** and **ErrImagePull** (not necessarily 403). Revert immediately after. |

**Commands (repository root):**

```bash
kubectl apply -f tomj-lab/examples/k8s/jfrog-artifactory-cognito-deployment.yaml
kubectl -n demo-namespace-cognito get pods -o wide
kubectl -n demo-namespace-cognito describe pod -l app=ubuntu-cognito-pull-ok

kubectl apply -f tomj-lab/examples/k8s/jfrog-artifactory-cognito-deployment-negative-permission.yaml
kubectl -n demo-namespace-cognito describe pod -l app=ubuntu-cognito-pull-deny
```

**Cleanup:**

```bash
kubectl delete -f tomj-lab/examples/k8s/jfrog-artifactory-cognito-deployment-negative-permission.yaml
kubectl delete -f tomj-lab/examples/k8s/jfrog-artifactory-cognito-deployment.yaml
```

**Notes**

- **`matchImages`** on the Helm release must still include your registry host (e.g. `tomjfrog.jfrog.io`).
- **Registry-level cache** in the provider can make order-sensitive debugging confusing; **`imagePullPolicy: Always`** plus bumping **`jfrog-credential-provider-lab/pull-snapshot`** (as in the manifests) helps force meaningful retests.
- **P1** and **N1** together mirror the IRSA permission lab (§8 / §8.1): positive and denied pulls differ only by **Artifactory RBAC**, not by Kubernetes identity shape.

---

## Reference

- [AWS.md](../AWS.md) — full EKS guide (EC2 metadata, IRSA, Cognito)
- [EKS IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Kubelet credential provider](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/)
- [aws-env-secrets.sh](./aws-env-secrets.sh) — shell variables for this lab
