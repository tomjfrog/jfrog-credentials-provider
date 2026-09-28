# Azure WI isolation test pods

Apply base resources first:

```bash
kubectl apply -f 00-namespaces.yaml -f 01-serviceaccounts.yaml
```

Each pod uses `JFrogExchange` on SA `artifactory-pull` only — no `azure.workload.identity/*` annotations.

| File | Matrix |
|------|--------|
| test-pod-team-a-own.yaml | T1 |
| test-pod-team-a-cross.yaml | T2 |
| test-pod-team-b-own.yaml | T3 + |
| test-pod-team-b-cross.yaml | T3 − |
| test-pod-default-sa.yaml | T4 |
| test-pod-team-c-unmapped.yaml | T5 |
| test-pod-cache-bypass-ifnotpresent.yaml | T7 |

Bump `jfrog-credential-provider-lab/pull-snapshot` annotation or delete pods to force re-pull.

For T6, pin `nodeName` on team-a own + team-b cross pods to the same node.
