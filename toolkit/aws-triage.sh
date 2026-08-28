# ==============================================================================
# aws-triage.sh — AWS-side verbs, aimed at the layer under an EKS cluster.
#
#     aw-who                  which account and identity am I actually using
#     aw-eks                  clusters, versions, nodegroups, and the OIDC link
#     aw-triage <cluster>     the full EKS-and-below sweep
#
# Scoped deliberately narrow: this is not a general AWS toolkit, it is the set
# of AWS questions that come up while a Kubernetes cluster is broken. In an
# EKS assessment the fault is below the API server about a third of the time —
# a security group that does not allow the control plane to reach the kubelet,
# a node IAM role missing a policy, a subnet with no free IPs — and none of
# those are visible from kubectl at all.
#
# Every verb is read-only and passes through the aws guard (see
# image/guard-aws.sh); nothing here can modify an account.
# ==============================================================================

: "${AW_REGION:=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"

_aw_hr()   { printf '\n\033[1;33m==== %s ====\033[0m\n' "$*"; }
_aw_note() { printf '\033[2m    %s\033[0m\n' "$*"; }

# _aw <args...> — single choke point, same reasoning as _kt_k. Injects --region
# when one is set so you do not have to repeat it, and --output table for
# readability (JSON is for jq, tables are for eyes).
_aw() {
  local r=()
  [ -n "$AW_REGION" ] && r=(--region "$AW_REGION")
  aws "${r[@]}" "$@"
}

# ------------------------------------------------------------------------------
# aw-who — which identity, which account, which region.
#
# Always the first command. The expensive AWS mistake is not a wrong command, it
# is a right command against the wrong account, and `get-caller-identity` is the
# only thing that actually answers "which account am I in" — AWS_PROFILE tells
# you what you asked for, not what you got.
# ------------------------------------------------------------------------------
aw-who() {
  _aw_hr "caller identity"
  _aw sts get-caller-identity --output table 2>&1
  _aw_hr "environment"
  printf '    AWS_PROFILE  %s\n' "${AWS_PROFILE:-(unset)}"
  printf '    region       %s\n' "${AW_REGION:-(unset — most commands will fail)}"
  printf '    creds file   %s\n' "${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
  _aw_hr "configured profiles"
  _aw configure list-profiles 2>/dev/null || _aw_note "none"
}

# ------------------------------------------------------------------------------
# aw-region [region] — set the region every other verb uses.
# ------------------------------------------------------------------------------
aw-region() {
  [ -n "$1" ] && export AW_REGION="$1" AWS_REGION="$1" AWS_DEFAULT_REGION="$1"
  echo "AW_REGION=${AW_REGION:-(unset)}"
}

# ------------------------------------------------------------------------------
# aw-eks [cluster] — EKS control plane facts that kubectl cannot tell you.
#
# The version is here because EKS control planes get upgraded on a schedule and
# nodegroups do not: a two-minor skew between control plane and kubelet is a
# supported-but-broken state that produces symptoms all over the cluster.
#
# The OIDC provider line matters more than it looks. Without it, IRSA does not
# work, and every pod that assumes a role fails with an authentication error
# that reads like a credentials problem rather than a cluster configuration one.
# ------------------------------------------------------------------------------
aw-eks() {
  local c="$1"
  if [ -z "$c" ]; then
    _aw_hr "EKS clusters in ${AW_REGION:-default region}"
    _aw eks list-clusters --output table 2>&1
    _aw_note "then: aw-eks <cluster>"
    return 0
  fi
  _aw_hr "cluster/$c"
  _aw eks describe-cluster --name "$c" \
    --query 'cluster.{name:name,status:status,version:version,platform:platformVersion,endpoint:endpoint,public:resourcesVpcConfig.endpointPublicAccess,private:resourcesVpcConfig.endpointPrivateAccess,vpc:resourcesVpcConfig.vpcId}' \
    --output table 2>&1
  _aw_hr "OIDC provider (required for IRSA)"
  local oidc
  oidc="$(_aw eks describe-cluster --name "$c" --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null)"
  printf '    issuer: %s\n' "${oidc:-(none)}"
  if [ -n "$oidc" ] && [ "$oidc" != None ]; then
    _aw iam list-open-id-connect-providers --output text 2>/dev/null | grep -q "${oidc##*/}" \
      && _aw_note "provider IS registered in IAM — IRSA can work" \
      || _aw_note "provider NOT registered in IAM — every IRSA pod will fail to assume its role"
  fi
  _aw_hr "nodegroups (watch for a version behind the control plane)"
  local ng
  for ng in $(_aw eks list-nodegroups --cluster-name "$c" --query 'nodegroups[]' --output text 2>/dev/null); do
    _aw eks describe-nodegroup --cluster-name "$c" --nodegroup-name "$ng" \
      --query 'nodegroup.{name:nodegroupName,status:status,version:version,ami:amiType,type:instanceTypes[0],desired:scalingConfig.desiredSize,min:scalingConfig.minSize,max:scalingConfig.maxSize,health:health.issues[0].code}' \
      --output table 2>&1
  done
  _aw_hr "fargate profiles"
  _aw eks list-fargate-profiles --cluster-name "$c" --output text 2>/dev/null || _aw_note "none"
  _aw_hr "cluster addons (vpc-cni / coredns / kube-proxy version drift lives here)"
  _aw eks list-addons --cluster-name "$c" --output text 2>/dev/null || _aw_note "none"
}

# ------------------------------------------------------------------------------
# aw-vpc <vpc-id> — the network under the cluster.
#
# Subnet free-IP counts are the reason this exists. The vpc-cni plugin assigns a
# real VPC IP to every pod, so a /24 subnet supports far fewer pods than people
# expect; when it runs out, pods sit in ContainerCreating with a FailedCreate-
# PodSandBox event and the cluster looks like it has a CNI bug. The number in
# AvailableIpAddressCount settles it in one line.
# ------------------------------------------------------------------------------
aw-vpc() {
  local v="$1"; [ -z "$v" ] && { echo "usage: aw-vpc <vpc-id>"; return 1; }
  _aw_hr "subnets in $v — AVAILABLE IPs is the field that matters"
  _aw ec2 describe-subnets --filters "Name=vpc-id,Values=$v" \
    --query 'Subnets[].{id:SubnetId,az:AvailabilityZone,cidr:CidrBlock,free:AvailableIpAddressCount,public:MapPublicIpOnLaunch}' \
    --output table 2>&1
  _aw_hr "route tables"
  _aw ec2 describe-route-tables --filters "Name=vpc-id,Values=$v" \
    --query 'RouteTables[].{id:RouteTableId,assoc:Associations[0].SubnetId,routes:Routes[].DestinationCidrBlock|join(`,`,@)}' \
    --output table 2>&1
  _aw_hr "NAT gateways (private nodes with no NAT cannot pull images)"
  _aw ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$v" \
    --query 'NatGateways[].{id:NatGatewayId,state:State,subnet:SubnetId}' --output table 2>&1
  _aw_hr "VPC endpoints (a private cluster needs ecr.api, ecr.dkr, s3, sts, logs)"
  _aw ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$v" \
    --query 'VpcEndpoints[].{svc:ServiceName,state:State,type:VpcEndpointType}' --output table 2>&1
}

# ------------------------------------------------------------------------------
# aw-sg <sg-id> — security group rules, both directions.
#
# The EKS-specific failure this catches: the control plane must reach the kubelet
# on 10250 and the nodes must reach the API on 443. If either rule is missing,
# `kubectl logs` and `kubectl exec` fail with a timeout while everything else
# works perfectly — a symptom that sends people looking at the CNI for an hour.
# ------------------------------------------------------------------------------
aw-sg() {
  local sg="$1"; [ -z "$sg" ] && { echo "usage: aw-sg <sg-id>"; return 1; }
  _aw_hr "$sg — inbound"
  _aw ec2 describe-security-groups --group-ids "$sg" \
    --query 'SecurityGroups[].IpPermissions[].{proto:IpProtocol,from:FromPort,to:ToPort,cidr:IpRanges[].CidrIp|join(`,`,@),sgs:UserIdGroupPairs[].GroupId|join(`,`,@)}' \
    --output table 2>&1
  _aw_hr "$sg — outbound"
  _aw ec2 describe-security-groups --group-ids "$sg" \
    --query 'SecurityGroups[].IpPermissionsEgress[].{proto:IpProtocol,from:FromPort,to:ToPort,cidr:IpRanges[].CidrIp|join(`,`,@)}' \
    --output table 2>&1
  _aw_note "EKS needs: control-plane -> node 10250, node -> control-plane 443, node -> node all"
}

# ------------------------------------------------------------------------------
# aw-node <instance-id|private-dns> — the EC2 instance behind a Kubernetes node.
#
# Where you go when a node is NotReady and you want to know whether the machine
# itself is unhealthy. The instance status checks are the discriminator: a
# failed SYSTEM check is AWS's hardware and you cannot fix it (replace the node);
# a failed INSTANCE check is the OS and you can.
# ------------------------------------------------------------------------------
aw-node() {
  local i="$1"; [ -z "$i" ] && { echo "usage: aw-node <instance-id|private-dns-name>"; return 1; }
  local filter=(--instance-ids "$i")
  case "$i" in i-*) ;; *) filter=(--filters "Name=private-dns-name,Values=$i") ;; esac
  _aw_hr "instance"
  _aw ec2 describe-instances "${filter[@]}" \
    --query 'Reservations[].Instances[].{id:InstanceId,type:InstanceType,state:State.Name,az:Placement.AvailabilityZone,private:PrivateIpAddress,public:PublicIpAddress,launched:LaunchTime,sgs:SecurityGroups[].GroupId|join(`,`,@)}' \
    --output table 2>&1
  local id
  id="$(_aw ec2 describe-instances "${filter[@]}" --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)"
  _aw_hr "status checks (SYSTEM failed = AWS hardware; INSTANCE failed = the OS)"
  _aw ec2 describe-instance-status --instance-ids "$id" --include-all-instances \
    --query 'InstanceStatuses[].{instance:InstanceStatus.Status,system:SystemStatus.Status,events:Events[0].Description}' \
    --output table 2>&1
}

# ------------------------------------------------------------------------------
# aw-ecr <repo> [tag] — does the image the pod wants actually exist.
#
# The half of an ImagePullBackOff that kubectl cannot answer. Three distinct
# causes look identical from inside the cluster: the repository does not exist,
# the tag does not exist, or it exists and the node's role cannot pull it. The
# first two are answered here; the third is aw-irsa.
# ------------------------------------------------------------------------------
aw-ecr() {
  local repo="$1" tag="$2"
  if [ -z "$repo" ]; then
    _aw_hr "repositories"
    _aw ecr describe-repositories --query 'repositories[].{name:repositoryName,uri:repositoryUri}' --output table 2>&1
    return 0
  fi
  _aw_hr "$repo — most recent 20 tags"
  _aw ecr describe-images --repository-name "$repo" \
    --query 'sort_by(imageDetails,&imagePushedAt)[-20:].{pushed:imagePushedAt,tags:imageTags|join(`,`,@),size:imageSizeInBytes}' \
    --output table 2>&1
  if [ -n "$tag" ]; then
    _aw_hr "does tag '$tag' exist"
    _aw ecr describe-images --repository-name "$repo" --image-ids "imageTag=$tag" \
      --query 'imageDetails[].{digest:imageDigest,pushed:imagePushedAt}' --output table 2>&1 \
      || _aw_note "NOT FOUND — this is your ImagePullBackOff"
  fi
  _aw_hr "repository policy (who may pull)"
  _aw ecr get-repository-policy --repository-name "$repo" --query 'policyText' --output text 2>/dev/null \
    || _aw_note "no repository policy — access is governed by the caller's IAM policy alone"
}

# ------------------------------------------------------------------------------
# aw-irsa <namespace> <serviceaccount> — trace a pod's identity into IAM.
#
# IRSA fails in exactly one place most of the time: the role's trust policy names
# a different namespace or ServiceAccount than the pod actually uses, so the
# annotation looks right, the role looks right, and the assume-role still fails.
# This prints the annotation and the trust policy next to each other so the
# mismatch is visible rather than inferred.
# ------------------------------------------------------------------------------
aw-irsa() {
  local ns="$1" sa="$2"
  [ -z "$sa" ] && { echo "usage: aw-irsa <namespace> <serviceaccount>"; return 1; }
  _aw_hr "ServiceAccount $ns/$sa annotation"
  local arn
  arn="$(kubectl -n "$ns" get sa "$sa" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null)"
  printf '    role-arn: %s\n' "${arn:-(NOT ANNOTATED — the pod gets the node role instead)}"
  [ -z "$arn" ] && return 0
  local role="${arn##*/}"
  _aw_hr "IAM role $role — trust policy (must name $ns:$sa)"
  _aw iam get-role --role-name "$role" --query 'Role.AssumeRolePolicyDocument' --output json 2>&1
  _aw_hr "attached policies"
  _aw iam list-attached-role-policies --role-name "$role" --output table 2>&1
  _aw iam list-role-policies --role-name "$role" --output table 2>&1
}

# ------------------------------------------------------------------------------
# aw-triage <cluster> — the whole AWS side of an EKS cluster in one pass.
# ------------------------------------------------------------------------------
aw-triage() {
  local c="$1"; [ -z "$c" ] && { echo "usage: aw-triage <eks-cluster-name>"; return 1; }
  aw-who
  aw-eks "$c"
  local vpc
  vpc="$(_aw eks describe-cluster --name "$c" --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null)"
  [ -n "$vpc" ] && [ "$vpc" != None ] && aw-vpc "$vpc"
  local sg
  sg="$(_aw eks describe-cluster --name "$c" --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null)"
  [ -n "$sg" ] && [ "$sg" != None ] && aw-sg "$sg"
}

aw-help() {
  cat <<'HELP'

  aws-triage — the AWS layer under a Kubernetes cluster. All read-only.

    aw-who                     identity + account + region  (ALWAYS FIRST)
    aw-region <region>         set the region for every other verb
    aw-eks [cluster]           control plane, version skew, OIDC/IRSA, nodegroups
    aw-triage <cluster>        the full sweep: identity -> eks -> vpc -> sg
    aw-vpc <vpc-id>            subnets + FREE IPs, routes, NAT, endpoints
    aw-sg <sg-id>              security group rules, both directions
    aw-node <instance|dns>     the EC2 instance behind a k8s node + health checks
    aw-ecr [repo] [tag]        does the image the pod is asking for exist
    aw-irsa <ns> <sa>          trace a pod's identity into an IAM trust policy

  Getting a kubeconfig for an EKS cluster:
    aws eks update-kubeconfig --name <cluster> --region <region>

HELP
}
