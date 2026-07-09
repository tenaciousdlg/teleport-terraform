# EKS Control Plane — Layer 2: Teleport

Installs Teleport onto the EKS cluster via Helm. Configures cert-manager for TLS, the Teleport auth and proxy services, Route 53 DNS, and an NLB. Enables Access Graph via `var.access_graph_enabled` (**live value for presales is `true`** — deploy `5-access-graph` first; flipping this restarts the auth pods). Also enforces Pod Security Standards `baseline` on the `teleport-cluster` namespace.

Reads cluster outputs from layer 1 via `terraform_remote_state` (S3). Live presales values: `env=dev`, `teleport_version` = the cluster version (18.10.0 as of 2026-07).

See [../README.md](../README.md) for the full EKS control plane deployment guide and layer sequence.
