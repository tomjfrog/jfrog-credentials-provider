# Sample workload: pull from Artifactory with the kubelet credential provider

The JFrog **kubelet credential provider** runs on **each node** (DaemonSet from Helm). It does not ship application Deployments: **you** create Pods/Deployments that:

1. **IRSA path:** Use an **annotated** ServiceAccount (`eks.amazonaws.com/role-arn`, `JFrogExchange=true`).
2. **Cognito OIDC path:** Use a **plain** ServiceAccount **without** those annotations (see [`jfrog-artifactory-cognito-deployment.yaml`](./jfrog-artifactory-cognito-deployment.yaml)).
3. Reference an image whose registry matches Helm **`matchImages`**.
4. (If your Helm values use node affinity) schedule on nodes labeled for the provider.

See [`jfrog-artifactory-ubuntu-deployment.yaml`](./jfrog-artifactory-ubuntu-deployment.yaml) (IRSA) and [`jfrog-artifactory-cognito-deployment.yaml`](./jfrog-artifactory-cognito-deployment.yaml) (Cognito).

## Cognito / OIDC (Helm `aws_auth_method: cognito_oidc`)

Full matrix: [aws-lab-exercise.md §9.8](../../aws-lab-exercise.md#98-test-cases-positive--negative).

```bash
kubectl apply -f tomj-lab/examples/k8s/jfrog-artifactory-cognito-deployment.yaml
kubectl apply -f tomj-lab/examples/k8s/jfrog-artifactory-cognito-deployment-negative-permission.yaml
```

## Apply (after IRSA role + JFrog IAM binding + Helm install)

1. Edit the ServiceAccount **`eks.amazonaws.com/role-arn`** if yours differs from the example.
2. Ensure Helm **`matchImages`** includes your registry host, e.g. `tomjfrog.jfrog.io` or `*.jfrog.io` (see [`aws-projected-sa-values-tomjfrog.yaml`](../aws-projected-sa-values-tomjfrog.yaml)).
3. Label nodes if required by your Helm chart:

   ```bash
   kubectl label nodes --all credentialsProviderEnabled=true --overwrite
   ```

4. Apply:

   ```bash
   kubectl apply -f tomj-lab/examples/k8s/jfrog-artifactory-ubuntu-deployment.yaml
   kubectl -n demo-namespace rollout status deployment/ubuntu-artifactory-test
   kubectl -n demo-namespace get pods -o wide
   ```

If the image pull fails, describe the pod and check `/var/log/jfrog-credential-provider.log` on the node (see [debug.md](../../../debug.md)).

### `CrashLoopBackOff` with `exec format error` in logs

That means the image’s binaries don’t match the node CPU (often **arm64** image on **amd64** EKS nodes). The pull can still succeed. Fix by pushing a **linux/amd64** or **multi-arch** manifest for your test image, or use nodes that match the image arch (e.g. Graviton).

### Negative test: pull denied by Artifactory permissions

Use the **same** IRSA path (same `jfrog-pull-sa`, same IAM binding to **`aws-eks-pull-user`** or whatever **`ARTIFACTORY_USER`** is in [aws-env-secrets.sh](../../aws-env-secrets.sh)), but point the container at a **real** image in a **different Docker repository** where that user has **no Read** (or is excluded by permission targets).

That fails for the right reason: **identity and credential provider worked**, but **`aws-eks-pull-user`** cannot pull that repo—typically **401/403** / **pull access denied**, not “manifest unknown.”

**Artifactory (outline):**

1. Create a local Docker repo **without** Read for `aws-eks-pull-user` (lab example on tomjfrog: **`offlimits-docker-local`** with **`alpine:3.23`**).
2. Push a small image there (match node **linux/amd64**).
3. Confirm the user can still pull the happy-path repo (e.g. `jfcredsprov-docker-local`) but **not** this repo.

The checked-in manifest uses **`tomjfrog.jfrog.io/offlimits-docker-local/alpine:3.23`** with **`imagePullPolicy: Always`** and a **`jfrog-credential-provider-lab/pull-snapshot`** annotation—**bump that annotation’s timestamp** (or run **`kubectl rollout restart`**) after you tighten Artifactory permissions so new Pods actually run the pull again.

```bash
kubectl apply -f tomj-lab/examples/k8s/jfrog-artifactory-ubuntu-deployment-negative-permission.yaml
kubectl -n demo-namespace rollout restart deployment/ubuntu-artifactory-test-deny-perm   # optional if you already bumped the annotation
kubectl -n demo-namespace describe pod -l app=ubuntu-artifactory-test-deny-perm
```

Clean up:

```bash
kubectl delete -f tomj-lab/examples/k8s/jfrog-artifactory-ubuntu-deployment-negative-permission.yaml
```

**Note:** Helm **`matchImages`** must still cover your host (e.g. `tomjfrog.jfrog.io`); only the **repository path** under that host changes.

**IRSA-only isolation:** Proving “this pull used **web_identity** vs node role” is still separate from repo permission tests—see earlier discussion of `serviceAccountName: default` and **`cacheKeyType: "Registry"`** in the provider.
