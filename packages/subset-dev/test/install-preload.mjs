// Loaded with `node --import` before src/cli.mjs in the interruption and concurrency tests, which run the real command
// in its own process so it receives real signals. Test-only: it makes the process report darwin, runs the tool
// stand-ins of $STUB_TOOL_MAP ({ "/usr/bin/hdiutil": "<stand-in>", ... }) in place of the real tools, and answers
// every fetch with the bytes of $FAKE_IMAGE in two chunks. With STUB_SIGNAL_AT=download it sends STUB_SIGNAL (default
// SIGTERM) to this process (with STUB_SIGNAL_GROUP=1, to its process group) between the two chunks.
import { readFileSync } from 'node:fs';
import { createRequire, syncBuiltinESMExports } from 'node:module';
import process from 'node:process';
import { promisify } from 'node:util';

const require = createRequire(import.meta.url);
const childProcess = require('node:child_process');
const map = JSON.parse(process.env.STUB_TOOL_MAP);
const original = { execFile: childProcess.execFile, spawn: childProcess.spawn };
const redirected = (file) => (Object.hasOwn(map, file) ? map[file] : file);
const execFile = function (file, ...rest) {
  return original.execFile.call(this, redirected(file), ...rest);
};
execFile[promisify.custom] = (file, ...rest) => original.execFile[promisify.custom](redirected(file), ...rest);
childProcess.execFile = execFile;
childProcess.spawn = function (file, ...rest) {
  return original.spawn.call(this, redirected(file), ...rest);
};
syncBuiltinESMExports();

Object.defineProperty(process, 'platform', { value: 'darwin' });

globalThis.fetch = async (url, init) => {
  const bytes = readFileSync(process.env.FAKE_IMAGE);
  const half = Math.floor(bytes.length / 2);
  let sent = 0;
  const body = new ReadableStream({
    async pull(controller) {
      if (sent === 0) {
        controller.enqueue(bytes.subarray(0, half));
      } else if (sent === 1) {
        if (process.env.STUB_SIGNAL_AT === 'download') {
          process.kill(process.env.STUB_SIGNAL_GROUP ? -process.pid : process.pid, process.env.STUB_SIGNAL || 'SIGTERM');
          await new Promise((resolve) => setTimeout(resolve, 200));
        }
        if (init?.signal?.aborted) return controller.error(init.signal.reason);
        controller.enqueue(bytes.subarray(half));
      } else {
        controller.close();
      }
      sent += 1;
    }
  });
  return new Response(body, { status: 200 });
};
