## 1
Pending with idle nodes and tiny requests is not a compute problem. Look at what
else the pod needs before it can be placed — it mounts something.

## 2
    kubectl -n p12-pvc-pending get pvc
    kubectl -n p12-pvc-pending describe pvc db-data

The claim is Pending too, and its events say why. Then ask what classes this
cluster actually offers, and which is the default:

    kubectl get sc

## 3
The PVC asks for `storageClassName: fast-ssd`, which does not exist here; kind
provides `standard` and marks it default. A named-but-missing class never falls
back — only an omitted field does.

A PVC's `storageClassName` is immutable, so recreate the claim:

    kubectl -n p12-pvc-pending delete pvc db-data
    kubectl -n p12-pvc-pending apply -f - <<'Y'
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata: {name: db-data}
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: standard
      resources: {requests: {storage: 1Gi}}
    Y
    kubectl -n p12-pvc-pending rollout restart deploy/db

Verify: `kubectl get pvc` shows Bound and the pod schedules. Note the class here
is `WaitForFirstConsumer`, so the claim stays Pending until a pod actually needs
it — that is correct behaviour, not the fault.
