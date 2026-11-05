# Pharos DSH Runtime Plugin

This plugin registers every live DSH `agent.session.id` as an independent
Pharos conversation. It polls the Host-owned `pharos-meshd` delivery queue and
uses `agent.followup()` for durable enqueue and wakeup.

The Web process is only a container. Process IDs, display names, and tmux names
are never used as provider session identity. A delivery acknowledged as
`consumed` means DSH's durable inbox took ownership of the transport message;
it does not claim that an assistant turn completed.

Install this package into the selected DSH profile, then add the row from
`cordis.patch.yml`. The package depends only on the local
`@pharos/runtime-client` package and the DSH `agents` service supplied by the
profile.
