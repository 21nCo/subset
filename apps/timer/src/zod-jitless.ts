// Hosts may forbid eval in the MCP App iframe; zod then validates without compiling its checks. zod reads
// the setting as each schema is built, and skips its `new Function` probe (which a strict CSP reports
// even when caught), so this module must run before anything that builds one: mcp-app.ts imports it first.
import { config } from 'zod';

config({ jitless: true });
