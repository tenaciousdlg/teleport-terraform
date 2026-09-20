variable "access_graph_version" {
  description = "teleport-access-graph Helm chart version. Pinned deliberately; the chart and the cluster version move together."
  type        = string
  default     = "1.30.3"
}
