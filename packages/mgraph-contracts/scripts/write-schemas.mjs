import { mkdir, writeFile } from 'node:fs/promises';
import { jsonSchemas } from '../dist/index.js';

await mkdir(new URL('../dist/schemas/', import.meta.url), { recursive: true });
for (const [name, schema] of Object.entries(jsonSchemas)) {
  await writeFile(new URL(`../dist/schemas/${name}.json`, import.meta.url), JSON.stringify(schema, null, 2) + '\n');
}
