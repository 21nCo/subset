import { defineSchema } from '@datafn/core';
import type { TableSchemaMap } from '@superfunctions/db';

/** The datafn resource version of every Bookmarks resource. A breaking change gets a new version and a migration. */
export const BOOKMARKS_RESOURCE_VERSION = 1;

/** datafn's row-level namespace column: every row belongs to one user, so multi-user needs no migration. */
export const NAMESPACE_COLUMN = '__ns';

export const DETAILS_STATES = ['pending', 'ready', 'failed'] as const;
export type DetailsState = (typeof DETAILS_STATES)[number];

/**
 * The datafn schema. `createdAt` and `updatedAt` come from the `timestamps` capability (epoch milliseconds set by
 * the server). `bookmark_sequences` holds the `apiId` high-water mark, so an id is never handed out twice, even
 * after the newest bookmark is deleted. datafn does not enforce `unique`; the migrations' unique indexes do.
 */
export const bookmarksSchema = defineSchema({
  resources: [
    {
      name: 'bookmarks',
      version: BOOKMARKS_RESOURCE_VERSION,
      capabilities: ['timestamps'],
      fields: [
        { name: 'apiId', type: 'number', required: true, nullable: false },
        { name: 'url', type: 'string', required: true, nullable: false },
        { name: 'canonicalUrl', type: 'string', required: true, nullable: false },
        { name: 'userTitle', type: 'string', required: false, nullable: true },
        { name: 'notes', type: 'string', required: false, nullable: true },
        { name: 'unread', type: 'boolean', required: true, nullable: false },
        { name: 'archived', type: 'boolean', required: true, nullable: false },
        { name: 'details', type: 'json', required: false, nullable: true },
        { name: 'detailsState', type: 'string', required: true, nullable: false, enum: [...DETAILS_STATES] },
        { name: 'detailsError', type: 'string', required: false, nullable: true },
        { name: 'detailsFetchedAt', type: 'date', required: false, nullable: true },
        { name: 'faviconKey', type: 'string', required: false, nullable: true }
      ]
    },
    {
      name: 'tags',
      version: BOOKMARKS_RESOURCE_VERSION,
      fields: [
        { name: 'name', type: 'string', required: true, nullable: false },
        { name: 'nameKey', type: 'string', required: true, nullable: false }
      ]
    },
    {
      name: 'bookmark_sequences',
      version: BOOKMARKS_RESOURCE_VERSION,
      fields: [{ name: 'value', type: 'number', required: true, nullable: false }]
    }
  ],
  relations: [{ from: 'bookmarks', to: 'tags', type: 'many-many', relation: 'tags', inverse: 'bookmarks', joinTable: 'bookmark_tags' }]
});

const epochMs = { type: 'date', dateValueType: 'epoch-ms', dateStorageType: 'epoch-ms-bigint' } as const;
const owner = { type: 'string', required: true } as const;

/**
 * The physical tables behind `bookmarksSchema`, in `@superfunctions/db` form: the source of the checked-in
 * migrations (`scripts/generate-migrations.mjs`) and the schema a host may pass to `wrapWithSchema`. Each table's
 * primary key is (`__ns`, `id`), and unique indexes include the namespace, so uniqueness is per user.
 */
export const bookmarksTables = {
  bookmarks: {
    modelName: 'bookmarks',
    fields: {
      id: { type: 'string', required: true },
      [NAMESPACE_COLUMN]: owner,
      apiId: { type: 'number', required: true },
      url: { type: 'string', required: true },
      canonicalUrl: { type: 'string', required: true },
      userTitle: { type: 'string' },
      notes: { type: 'string' },
      unread: { type: 'boolean', required: true },
      archived: { type: 'boolean', required: true },
      details: { type: 'json' },
      detailsState: { type: 'string', required: true },
      detailsError: { type: 'string' },
      detailsFetchedAt: epochMs,
      faviconKey: { type: 'string' },
      createdAt: { ...epochMs, required: true },
      updatedAt: { ...epochMs, required: true }
    },
    indexes: [
      { name: 'bookmarks_ns_canonical_url', fields: [NAMESPACE_COLUMN, 'canonicalUrl'], unique: true },
      { name: 'bookmarks_ns_api_id', fields: [NAMESPACE_COLUMN, 'apiId'], unique: true }
    ],
    constraints: [
      {
        name: 'bookmarks_details_state',
        type: 'check',
        fields: ['detailsState'],
        check: `"detailsState" IN ('pending', 'ready', 'failed')`
      }
    ]
  },
  tags: {
    modelName: 'tags',
    fields: {
      id: { type: 'string', required: true },
      [NAMESPACE_COLUMN]: owner,
      name: { type: 'string', required: true },
      nameKey: { type: 'string', required: true }
    },
    indexes: [{ name: 'tags_ns_name_key', fields: [NAMESPACE_COLUMN, 'nameKey'], unique: true }]
  },
  // datafn's many-to-many join rows: id is `<bookmark id>:<tag id>`.
  bookmark_tags: {
    modelName: 'bookmark_tags',
    fields: {
      id: { type: 'string', required: true },
      [NAMESPACE_COLUMN]: owner,
      from: { type: 'string', required: true },
      to: { type: 'string', required: true }
    },
    indexes: [
      { name: 'bookmark_tags_ns_from', fields: [NAMESPACE_COLUMN, 'from'] },
      { name: 'bookmark_tags_ns_to', fields: [NAMESPACE_COLUMN, 'to'] }
    ]
  },
  bookmark_sequences: {
    modelName: 'bookmark_sequences',
    fields: {
      id: { type: 'string', required: true },
      [NAMESPACE_COLUMN]: owner,
      value: { type: 'number', required: true }
    }
  }
} satisfies TableSchemaMap;
