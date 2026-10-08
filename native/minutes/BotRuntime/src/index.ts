#!/usr/bin/env node
/**
 * CLI entry point.
 *
 * Usage:
 *   npx tsx src/index.ts <meeting-url> [options]
 *
 * Options:
 *   --name=<str>            Display name shown in the meeting  (default: "Recording Bot")
 *   --platform=<str>        google-meet | zoom | auto          (default: auto)
 *   --recording-dir=<path>  Directory to write .webm audio     (default: ./recordings)
 *   --headless              Run browser in headless mode
 */

import { runBot, type BotOptions } from './bot-runner.js';
import { error } from './status.js';

function parseArgs(argv: string[]): BotOptions {
  const positional = argv.filter((a) => !a.startsWith('--'));
  const flags = new Map(
    argv
      .filter((a) => a.startsWith('--'))
      .map((a) => {
        const [k, ...rest] = a.slice(2).split('=');
        return [k, rest.join('=')] as [string, string];
      })
  );

  const url = positional[0];
  if (!url) {
    console.error(
      'Usage: npx tsx src/index.ts <meeting-url> [--name=...] [--platform=...] [--recording-dir=...] [--headless]'
    );
    process.exit(1);
  }

  return {
    url,
    displayName: flags.get('name') ?? 'Recording Bot',
    platform: (flags.get('platform') as BotOptions['platform']) ?? 'auto',
    recordingDir: flags.get('recording-dir'),
    headless: flags.has('headless'),
  };
}

const opts = parseArgs(process.argv.slice(2));

runBot(opts).catch((err_: unknown) => {
  const message = err_ instanceof Error ? err_.message : String(err_);
  error(message);
  process.exit(1);
});
