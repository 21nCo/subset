// Runs the real CLI entry with a driver that never starts Chrome, for signal and stdin tests.
import { writeFile } from 'node:fs/promises';
import { runCli } from '../../src/main.mjs';

const fakeDriver = {
  async open({ log }) {
    log('fake chrome');
    return {
      async startCapture(file) { await writeFile(file, 'fake-webm'); },
      async join() {},
      waitForEnd: (signal) => new Promise((resolve) => {
        if (signal.aborted) resolve('aborted');
        signal.addEventListener('abort', () => resolve('aborted'), { once: true });
      }),
      async stopCapture() { return 9; },
      async leave() {},
      async close() {},
    };
  },
};

await runCli({ createDriver: async () => fakeDriver });
