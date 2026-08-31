#!/usr/bin/env bash
set -euo pipefail
. "${GB_RANGE_LIB:?}"
rk create namespace "$NS" --dry-run=client -o yaml | rk apply -f - >/dev/null
rk label namespace "$NS" gb-range/g6=yes --overwrite >/dev/null
rk apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: ledger, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: ledger}}
  template:
    metadata: {labels: {app: ledger}}
    spec:
      containers: [{name: app, image: $GB_IMG_NGINX}]
YAML
rk -n "$NS" rollout status deploy/ledger --timeout=120s >/dev/null 2>&1 || true
# A policy webhook whose backing deployment was removed months ago. The
# configuration outlived it, and failurePolicy: Fail means the API server
# refuses every write it cannot get an opinion on.
#
# namespaceSelector scopes the blast radius to this scenario's namespace. On a
# real cluster this is exactly the outage that takes the whole platform down;
# here, scoping it is the difference between a lesson and an unrecoverable range.
rk apply -f - >/dev/null <<YAML
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata: {name: gb-range-policy-guard}
webhooks:
- name: guard.gb-range.local
  admissionReviewVersions: [v1]
  sideEffects: None
  failurePolicy: Fail
  timeoutSeconds: 5
  namespaceSelector:
    matchLabels: {gb-range/g6: "yes"}
  clientConfig:
    service: {name: policy-guard, namespace: $NS, path: /validate, port: 443}
  rules:
  - operations: ["CREATE","UPDATE"]
    apiGroups: ["","apps"]
    apiVersions: ["v1"]
    resources: ["pods","configmaps","deployments"]
YAML
