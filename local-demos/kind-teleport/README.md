# kind-teleport-demo

Disposable multi-node local Kubernetes cluster for showing Teleport's
Kubernetes access story with zero cloud dependency and zero standing cost —
useful for a spontaneous call where spinning up EKS/GKE isn't worth the wait.

## Usage

```bash
export TELEPORT_PROXY_ADDR="presales.teleportdemo.com:443"
export TELEPORT_JOIN_TOKEN="$(tctl tokens add --type=kube --format=text)"
./demo-up.sh
tsh kube ls
```

Tear down when done — this is meant to be disposable, not a pet cluster:

```bash
./demo-down.sh
```

## Topology

`kind-teleport-demo.yaml` defines 1 control-plane + 2 worker nodes — enough
to demo node-level labels/RBAC without the overhead of a full cloud cluster.
Edit the node list to match whatever topology a given demo needs.
