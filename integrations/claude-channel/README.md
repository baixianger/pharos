# Pharos Claude Channel

This is the supported Claude integration. It uses the public Claude Code MCP
Channel contract and does not write Claude's private inbox-socket protocol.

```sh
cd integrations/claude-channel
npm install
claude --dangerously-load-development-channels server:pharos
```

Add the `pharos` MCP server from `mcp.example.json` to the applicable MCP
configuration first. Custom channels require the development flag while
Claude Channels remains a research preview. Sessions without the channel are
registered by hooks for lifecycle visibility but advertise no direct-delivery
capability.
