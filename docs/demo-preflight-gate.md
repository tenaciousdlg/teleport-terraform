# Demo preflight gate

No analyst- or customer-facing demo without BOTH gates passing the night
before. Resource checks alone are insufficient — the 2026-08-26 KC demo
passed a full resource preflight and still failed on stage five times,
every failure flow-level.

## Gate 1 — environment (30 min, automatable)
- [ ] `demo-doctor` check of the runbook vs the live cluster
- [ ] db_server / app_server health: each resource served by exactly its
      own agent (`tctl get db_server|app_server`)
- [ ] windows desktop registered, bots listed, SVIDs issuable

## Gate 2 — flow rehearsal AS THE PRESENTER (20 min, not automatable)
- [ ] Fresh browser login. Click every UI page the demo touches. If a page
      needs elevation, do the web-UI Assume — web and CLI sessions elevate
      SEPARATELY under ZSP.
- [ ] Run every demo script (setup.sh etc.) end-to-end once. No dry runs.
- [ ] Log in as each persona (tpersona) and walk their exact path.
- [ ] Type commands from the RUNBOOK, not from shell history — history
      recalls last month's paths.

## Traps that have burned us live
| Trap | Reality |
|---|---|
| Admin-MFA taps | SINGLE-USE: one tap = one write. Multi-doc `tctl create` files die on doc 2 with bare "access denied". One resource per invocation. |
| Web vs CLI elevation | JIT grants are per-session. Assume in the web UI too, or the Locks/Bots pages stay hidden. |
| `tlock`/`tss`/`tfenv` | zsh plugin functions — they don't exist on remote hosts or bash subshells. Raw fallback: `tctl lock --user=<u> --ttl=10m`. |
| Operator-owned roles | `tctl edit` gets reverted. Patch the TeleportRole CR or terraform. |
| First-boot NAT race | Fresh-VPC instances raced the NAT gw and died silently in userdata. Fixed 2026-08-26: install curl now retries. Symptom if it recurs: agent absent from `tctl inventory ls`. |
| SCIM access lists | Okta owns their membership; tctl member writes are rejected by design. |
| `terraform -target` | Targeted applies do NOT refresh other modules' cached output values in state — a downstream module can render with a stale upstream output (desktop-service got a dead Windows DNS this way, 2026-08-27). After any targeted replace, finish with a full untargeted apply. |
| Ephemeral join tokens | Retired 2026-08-27: all AWS agent modules now use the iam join method (cloud-attested, no secret, no TTL). If an agent won't join, check the instance profile is attached — not token expiry. |
