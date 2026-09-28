version: v3
teleport:
  nodename: ${nodename}
  data_dir: /var/lib/teleport
  proxy_server: ${proxy_address}:443
  # bound_keypair with a PRE-REGISTERED STATIC KEY.
  #
  # Previously registration_secret_path -- a 48-byte secret on the host AND a
  # copy in Vault. The token names this key's public half
  # (local.agent_public_keys in control-plane/proxmox/3-rbac/agents.tf), so
  # nothing secret lives anywhere but the private key below, and the token is
  # fully described in the repo with nothing in Vault.
  #
  # A pre-registered public key survives both a host rebuild and an operator
  # reconcile, where a consumed registration secret does not. It also means a
  # CLUSTER rebuild needs no new keypair: a bound_keypair binds to cluster
  # name + CA, so the new cluster's token registers this same public key and
  # the agent re-binds on its first join.
  #
  # recovery.mode on the token is "insecure", which `tbot keypair create`
  # requires for static keys -- they keep no mutable join state. The cost is
  # clone-and-replay detection, not key confidentiality. Static keys cannot
  # rotate; never set rotate_after on this token.
  join_params:
    method: bound_keypair
    token_name: ${token_name}
    bound_keypair:
      static_key_path: ${static_key_path}
  log:
    output: stderr
    severity: ${log_severity}

# Agent only. The control plane is CT103 on hollowtree.
auth_service:
  enabled: 'no'
proxy_service:
  enabled: 'no'

ssh_service:
  enabled: 'yes'
  labels:
%{ for k, v in labels ~}
    ${k}: ${v}
%{ endfor ~}
%{ if length(apps) > 0 ~}

app_service:
  enabled: 'yes'
  apps:
%{ for a in apps ~}
%{ if try(a.comment, "") != "" ~}
%{ for line in split("\n", chomp(a.comment)) ~}
    # ${line}
%{ endfor ~}
%{ endif ~}
    - name: ${a.name}
      uri: ${a.uri}
      labels:
%{ for k, v in a.labels ~}
        ${k}: ${v}
%{ endfor ~}
%{ if length(try(a.rewrite_headers, [])) > 0 ~}
      rewrite:
        headers:
          # In a static teleport.yaml these are STRINGS. The name/value map
          # form belongs to the dynamic app resource / operator CR, and using
          # it here fails with "cannot unmarshal !!map into string".
%{ for h in a.rewrite_headers ~}
          - "${h}"
%{ endfor ~}
%{ endif ~}
%{ endfor ~}
%{ else ~}

app_service:
  enabled: 'no'
%{ endif ~}
