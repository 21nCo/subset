// A JSON Schema (2020-12) validator for exactly the keywords the closed subset.catalog@1 and subset.receipt@1 schemas
// use (packages/catalog/feed, copied to src/schemas so the published launcher needs no dependency). Compiling a schema
// that uses any other keyword, a $ref outside its own $defs, or a pattern that is not a valid `u`-flag regular
// expression throws, so a schema change the validator does not understand fails the tests instead of being ignored.
// test/feed.test.mjs checks that the copies equal packages/catalog/feed and that this validator agrees with Ajv.

const ANNOTATIONS = new Set(['$schema', 'title', 'description', '$defs']);
const KEYWORDS = new Set([
  'type', 'const', 'enum', 'pattern', 'minLength', 'maxLength', 'minimum', 'maximum',
  'properties', 'required', 'additionalProperties', 'minProperties', 'items', '$ref', 'if', 'then', 'else'
]);
const TYPES = {
  object: (value) => typeof value === 'object' && value !== null && !Array.isArray(value),
  array: Array.isArray,
  string: (value) => typeof value === 'string',
  integer: Number.isInteger,
  boolean: (value) => typeof value === 'boolean'
};

// JSON equality for const and enum: the schemas only compare strings, so this is strict equality.
const equal = (a, b) => a === b;
// JSON Schema counts string length in code points, not UTF-16 units.
const length = (text) => [...text].length;

/**
 * Compiles a schema to a function that returns the problems of a parsed JSON value ([] when it is valid), each as
 * `<JSON pointer>: <what is wrong>`.
 */
export function compileSchema(root) {
  const patterns = new Map();
  const resolve = (ref) => {
    const match = /^#\/\$defs\/([^/~]+)$/.exec(ref);
    const target = match && Object.hasOwn(root.$defs ?? {}, match[1]) ? root.$defs[match[1]] : undefined;
    if (target === undefined) throw new Error(`unsupported $ref ${ref}`);
    return target;
  };

  // Checks every keyword and pattern once, up front.
  const seen = new Set();
  const check = (schema) => {
    if (typeof schema === 'boolean' || seen.has(schema)) return;
    if (typeof schema !== 'object' || schema === null) throw new Error('a schema must be an object or a boolean');
    seen.add(schema);
    for (const [keyword, value] of Object.entries(schema)) {
      if (ANNOTATIONS.has(keyword)) continue;
      if (!KEYWORDS.has(keyword)) throw new Error(`unsupported schema keyword ${keyword}`);
      if (keyword === 'type' && !Object.hasOwn(TYPES, value)) throw new Error(`unsupported type ${JSON.stringify(value)}`);
      if (keyword === 'additionalProperties' && value !== false) throw new Error('only additionalProperties: false is supported');
      if (keyword === 'pattern') patterns.set(value, new RegExp(value, 'u'));
      if (keyword === '$ref') check(resolve(value));
      if (keyword === 'properties') Object.values(value).forEach(check);
      if (keyword === 'items' || keyword === 'if' || keyword === 'then' || keyword === 'else') check(value);
    }
  };
  check(root);
  Object.values(root.$defs ?? {}).forEach(check);

  const validate = (schema, value, pointer, problems) => {
    if (schema === true) return;
    if (schema === false) {
      problems.push(`${pointer || '/'}: is not allowed`);
      return;
    }
    if (schema.$ref !== undefined) validate(resolve(schema.$ref), value, pointer, problems);
    const at = pointer || '/';
    if (schema.type !== undefined && !TYPES[schema.type](value)) {
      problems.push(`${at}: must be ${schema.type === 'integer' ? 'an' : 'a'} ${schema.type}`);
      return;
    }
    if (Object.hasOwn(schema, 'const') && !equal(value, schema.const)) problems.push(`${at}: must be ${JSON.stringify(schema.const)}`);
    if (schema.enum !== undefined && !schema.enum.some((option) => equal(value, option))) {
      problems.push(`${at}: must be one of ${schema.enum.map((option) => JSON.stringify(option)).join(', ')}`);
    }
    if (typeof value === 'string') {
      if (schema.minLength !== undefined && length(value) < schema.minLength) problems.push(`${at}: must have at least ${schema.minLength} characters`);
      if (schema.maxLength !== undefined && length(value) > schema.maxLength) problems.push(`${at}: must have at most ${schema.maxLength} characters`);
      if (schema.pattern !== undefined && !patterns.get(schema.pattern).test(value)) problems.push(`${at}: does not match ${schema.pattern}`);
    }
    if (typeof value === 'number') {
      if (schema.minimum !== undefined && value < schema.minimum) problems.push(`${at}: must be at least ${schema.minimum}`);
      if (schema.maximum !== undefined && value > schema.maximum) problems.push(`${at}: must be at most ${schema.maximum}`);
    }
    if (Array.isArray(value) && schema.items !== undefined) {
      value.forEach((item, index) => validate(schema.items, item, `${pointer}/${index}`, problems));
    }
    if (TYPES.object(value)) {
      const properties = schema.properties ?? {};
      for (const name of schema.required ?? []) {
        if (!Object.hasOwn(value, name)) problems.push(`${at}: must have ${name}`);
      }
      for (const [name, item] of Object.entries(value)) {
        const child = `${pointer}/${name.replaceAll('~', '~0').replaceAll('/', '~1')}`;
        if (Object.hasOwn(properties, name)) validate(properties[name], item, child, problems);
        else if (schema.additionalProperties === false) problems.push(`${child}: is not allowed`);
      }
      if (schema.minProperties !== undefined && Object.keys(value).length < schema.minProperties) {
        problems.push(`${at}: must have at least ${schema.minProperties} ${schema.minProperties === 1 ? 'property' : 'properties'}`);
      }
    }
    if (schema.if !== undefined) {
      const branch = errorsOf(schema.if, value, pointer).length === 0 ? schema.then : schema.else;
      if (branch !== undefined) validate(branch, value, pointer, problems);
    }
  };
  const errorsOf = (schema, value, pointer) => {
    const problems = [];
    validate(schema, value, pointer, problems);
    return problems;
  };
  return (value) => errorsOf(root, value, '');
}
