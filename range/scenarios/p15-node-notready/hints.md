## 1
NotReady is the control plane saying it has not heard from that node's kubelet
recently. Two questions, in order: what does the node object say about *why*,
and is the kubelet actually running over there.

## 2
    kubectl describe node NODE | sed -n '/Conditions/,/Addresses/p'

`Ready: Unknown`, with a message about the node controller not receiving an
update — a lease that stopped being renewed, not a resource condition. So go
to the node itself. On a kind cluster the node is a container:

    docker exec -it gb-range-worker systemctl status kubelet
    docker exec -it gb-range-worker journalctl -u kubelet -e --no-pager | tail -30

## 3
The kubelet unit is stopped. Start it:

    docker exec gb-range-worker systemctl start kubelet

(On a real node: `ssh NODE` then `sudo systemctl start kubelet` — glovebox's
`kt-ssh` and `kt-kubelet` do exactly this walk for you.)

Verify: `kubectl get nodes` returns Ready within about 40 seconds, and the
workload rebalances. Two things worth saying out loud:

- If you had drained the node to work on it, it stays cordoned after it comes
  back. `kubectl uncordon NODE` is a step people forget, and the node then sits
  Ready and empty while everyone wonders why nothing schedules there.
- Deleting the Node object makes `get nodes` look clean and loses you a node.
