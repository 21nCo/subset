// Writes src/styles/schemes.css from the built scheme module. `npm run schemes` runs it after a build; the
// package test fails when the checked-in file differs.
import { writeFileSync } from 'node:fs';
import { schemesCss } from '../dist/index.js';

writeFileSync(new URL('../src/styles/schemes.css', import.meta.url), schemesCss());
