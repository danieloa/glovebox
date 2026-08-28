---
name: aws-eks-triage
description: Diagnose EKS and the AWS layer beneath a Kubernetes cluster. Use when a cluster runs on EKS and the fault may be in AWS rather than Kubernetes - IRSA and IAM role assumption failures, ImagePullBackOff from ECR, pods stuck in ContainerCreating from subnet IP exhaustion, kubectl logs/exec timing out from security group rules, nodegroup version skew, or nodes that will not join the cluster.
---

# When the Kubernetes problem is actually an AWS problem

Roughly a third of EKS faults are invisible from `kubectl`, because they are in
the layer underneath it. The tell is a symptom that makes no sense in Kubernetes
terms: a pod that cannot pull an image the registry definitely has, a node that
is healthy in EC2 and absent in `get nodes`, `kubectl logs` timing out while
`kubectl get` is instant.

## Always start here

```bash
aw-who      # WHICH ACCOUNT. AWS_PROFILE tells you what you asked for, not what you got.
aw-eks <cluster>
```

## The five faults worth knowing by shape

**`kubectl logs` and `kubectl exec` time out, everything else works.**
The control plane cannot reach the kubelet on port 10250. That is a security
group rule, not a Kubernetes problem — no amount of CNI debugging will find it.
`aw-sg <cluster-sg>`. EKS needs control-plane → node on 10250, node →
control-plane on 443, and node → node on everything.

**Pods stuck in `ContainerCreating` with `FailedCreatePodSandBox`.**
With the VPC CNI every pod gets a real VPC IP, so a `/24` subnet holds far fewer
pods than people expect. `aw-vpc <vpc-id>` and read `AvailableIpAddressCount`.
Zero free IPs looks exactly like a broken CNI and is not one.

**Every IRSA pod fails to assume its role.**
Two causes, and they are distinguishable. Either the cluster's OIDC provider was
never registered in IAM (`aw-eks` reports this explicitly), or the role's trust
policy names a different namespace or ServiceAccount than the pod actually uses.
`aw-irsa <ns> <sa>` prints the annotation and the trust policy adjacently so the
mismatch is visible rather than inferred. If the ServiceAccount carries no
annotation at all, the pod silently gets the *node's* role instead, which usually
has different permissions and produces a confusing partial failure.

**ImagePullBackOff on an ECR image.**
Three causes look identical from inside the cluster: the repository does not
exist, the tag does not exist, or the node's role cannot pull it. `aw-ecr <repo>
<tag>` answers the first two. For the third, check the node role's policies —
`AmazonEC2ContainerRegistryReadOnly` is the one people forget. On a private
cluster with no NAT gateway, also check for `ecr.api`, `ecr.dkr` and `s3` VPC
endpoints: without them the node has no route to the registry at all.

**Nodes will not join, or a nodegroup is a version behind.**
`aw-eks <cluster>` shows control plane and nodegroup versions together. EKS
upgrades the control plane on a schedule and does not touch nodegroups, so skew
accumulates silently; more than one minor is unsupported and produces symptoms
scattered across the whole cluster. For a node that boots but never registers,
`aw-node <instance-id>` — a failed SYSTEM status check is AWS hardware (replace
it), a failed INSTANCE check is the OS (fix it), and neither is a Kubernetes bug.

## Working the boundary

When a symptom appears in Kubernetes, decide which side it lives on before
investigating either:

- Does the object exist in Kubernetes but not behave? → Kubernetes.
- Does Kubernetes look correct but the underlying resource is absent, unreachable
  or unauthorised? → AWS.
- Does it work for some nodes and not others? → almost always AWS: an AZ, a
  subnet, a nodegroup, or a security group applied unevenly.

`aw-triage <cluster>` runs identity → cluster → VPC → security groups in one
pass, which is the right opening move when you do not yet know which side you
are on.
