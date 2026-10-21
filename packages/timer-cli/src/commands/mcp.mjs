export const mcpCommands = {
  mcp: {
    options: {},
    positionals: [0, 0],
    // Runs until the host closes stdin, then exits 0; the daemon and its timers keep running.
    async run({ client, packageRoot, serveMcp }) {
      // Loaded only for this command, so other commands do not parse the MCP runtime.
      const serve = serveMcp ?? (await import('../mcp/server.mjs')).serveStdio;
      await serve({ client, packageRoot });
      return null;
    }
  }
};
