# Design tradeoffs

This document records decisions where multiple reasonable options existed. The goal is to make it easy to revisit these choices if requirements change.

## Privilege dropping: `runuser` vs `gosu`

The container entrypoint runs as root so it can create the target user/group and write `/etc/gitconfig`. Before exec-ing Claude Code, it must drop to the target user so that files created inside the container are owned by the host user.

### `gosu` (not chosen)

[gosu](https://github.com/tianon/gosu) is the most widely recommended Docker pattern for privilege dropping. It is a minimal C binary that calls `setuid`/`setgid`/`initgroups` then exec-s the target command — no PAM, no shell overhead.

**Why not used:** It is not present in the base `node:22-bookworm` image and must either be installed at image build time (requires a custom `Dockerfile`) or at entrypoint startup (`apt-get install gosu` on every cold start). Neither is attractive for a project that intentionally avoids a custom image.

### `runuser` (chosen)

`runuser` is part of `util-linux`, which is a mandatory base package on Debian and is therefore always present in `node:22-bookworm`. It is purpose-built for running commands as another user without authentication, automatically initialises supplementary groups from `/etc/group`, and does not require PAM authentication (unlike `su`).

**Trade-off:** `runuser` requires the username to exist in `/etc/passwd`. This is guaranteed here because `useradd` always runs before `runuser` in the entrypoint.

### `setpriv` (considered but not chosen)

`setpriv` (also in `util-linux`) operates at a lower level: it sets Linux UIDs/GIDs and adjusts capabilities, then exec-s the command. It takes numeric IDs rather than a username, which works but is less readable. `--init-groups` must be passed explicitly to initialise supplementary groups. It is the right tool when fine-grained capability manipulation is needed; for simply "run as this user" `runuser` expresses intent more directly.

---

## Network isolation: host mode vs bridge

### Current status: `network_mode: host`

The container shares the host's network namespace. This means it has unrestricted outbound access and can reach host-local services (e.g. a proxy at `127.0.0.1:7890`) without any extra configuration.

**Why chosen:** Simplicity. Getting Claude Code's MCP servers, npm installs, and user proxies to work through a custom network configuration adds friction that was not worth addressing before filesystem sandboxing was settled.

### Future options

If network isolation becomes a goal, the main approaches are:

**Custom bridge network with egress rules**
Create a named Docker network and add `iptables`/`nftables` rules on the host to restrict what the container can reach. Allows precise whitelisting (e.g. Anthropic's API endpoints only). Requires host-level firewall management, which makes the tool harder to install and less portable.

**No network (`network_mode: none`)**
Completely disables networking. Claude Code itself would not function (it needs to reach the Anthropic API), so this is only viable if an HTTP proxy sidecar is added to the compose stack.

**Internal network + proxy sidecar**
Run a filtering HTTP proxy (e.g. Squid, mitmproxy) as a second compose service on a shared internal network. The `ai-agent` container has no direct internet access; all traffic is forced through the proxy, which can enforce allowlists. Most flexible option but significantly more complex to set up and maintain.

**User-namespace remapping**
Not strictly network isolation, but `--userns-remap` at the Docker daemon level limits what a container process can do on the host even if it escapes. Orthogonal to network restrictions; requires daemon configuration and is not per-container.

The current `network_mode: host` approach should be revisited if:
- A requirement emerges to prevent Claude Code from making arbitrary outbound connections.
- A user proxy setup makes host networking problematic (e.g. conflicting port bindings).
- The project moves toward a stricter security model after filesystem sandboxing matures.
