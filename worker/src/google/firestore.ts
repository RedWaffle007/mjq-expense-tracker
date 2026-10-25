// Firestore over REST, authed with the service-account access token (which
// bypasses security rules — the Worker is the trusted server). In emulator
// mode it talks to the local Firestore emulator with the "owner" token.
//
// Only the operations the Worker needs: read one doc, and an atomic commit of
// several writes with preconditions and server timestamps.

export interface DocSnapshot {
  data: Record<string, unknown>;
  updateTime: string;
}

export interface DocWrite {
  /** Document path relative to the database root, e.g. "users/abc". */
  path: string;
  data: Record<string, unknown>;
  /** Update only these fields. Omit to replace the whole document. */
  mask?: string[];
  /** Fields to set to the server's commit time. */
  serverTimestamps?: string[];
  precondition?: { exists: boolean } | { updateTime: string };
}

export interface Db {
  getDoc(path: string): Promise<DocSnapshot | null>;
  query(collection: string, options?: {
    where?: { field: string; op: 'EQUAL' | 'LESS_THAN_OR_EQUAL'; value: unknown }[];
    orderBy?: { field: string; direction: 'ASCENDING' | 'DESCENDING' };
    limit?: number;
  }): Promise<(DocSnapshot & { id: string })[]>;
  /** Atomic. Throws PreconditionFailedError if any precondition fails. */
  commit(writes: DocWrite[]): Promise<void>;
}

export class PreconditionFailedError extends Error {}

export function makeFirestoreDb(opts: {
  projectId: string;
  accessToken: string;
  emulatorHost?: string;
}): Db {
  const root = opts.emulatorHost
    ? `http://${opts.emulatorHost}/v1`
    : 'https://firestore.googleapis.com/v1';
  const dbName = `projects/${opts.projectId}/databases/(default)`;
  const docsName = `${dbName}/documents`;
  const headers = {
    Authorization: `Bearer ${opts.emulatorHost ? 'owner' : opts.accessToken}`,
    'Content-Type': 'application/json',
  };
  const encodePath = (path: string) =>
    path.split('/').map(encodeURIComponent).join('/');

  return {
    async getDoc(path) {
      const resp = await fetch(`${root}/${docsName}/${encodePath(path)}`, { headers });
      if (resp.status === 404) return null;
      if (!resp.ok) throw new Error(`Firestore getDoc ${path} → ${resp.status}`);
      const doc = (await resp.json()) as { fields?: FieldMap; updateTime: string };
      return { data: decodeFields(doc.fields), updateTime: doc.updateTime };
    },

    async query(collection, options = {}) {
      const structuredQuery: Record<string, unknown> = {
        from: [{ collectionId: collection }],
        ...(options.limit ? { limit: options.limit } : {}),
      };
      const filters = (options.where ?? []).map((condition) => ({
        fieldFilter: {
          field: { fieldPath: condition.field },
          op: condition.op,
          value: encodeValue(condition.value),
        },
      }));
      if (filters.length === 1) structuredQuery.where = filters[0];
      if (filters.length > 1) {
        structuredQuery.where = { compositeFilter: { op: 'AND', filters } };
      }
      if (options.orderBy) {
        structuredQuery.orderBy = [{
          field: { fieldPath: options.orderBy.field },
          direction: options.orderBy.direction,
        }];
      }
      const resp = await fetch(`${root}/${dbName}/documents:runQuery`, {
        method: 'POST', headers, body: JSON.stringify({ structuredQuery }),
      });
      if (!resp.ok) throw new Error(`Firestore query ${collection} → ${resp.status}`);
      const rows = (await resp.json()) as { document?: {
        name: string; fields?: FieldMap; updateTime: string;
      } }[];
      return rows.flatMap((row) => row.document ? [{
        id: row.document.name.slice(row.document.name.lastIndexOf('/') + 1),
        data: decodeFields(row.document.fields),
        updateTime: row.document.updateTime,
      }] : []);
    },

    async commit(writes) {
      const body = {
        writes: writes.map((w) => ({
          update: { name: `${docsName}/${w.path}`, fields: encodeFields(w.data) },
          ...(w.mask ? { updateMask: { fieldPaths: w.mask } } : {}),
          ...(w.precondition ? { currentDocument: w.precondition } : {}),
          ...(w.serverTimestamps?.length
            ? {
                updateTransforms: w.serverTimestamps.map((fieldPath) => ({
                  fieldPath,
                  setToServerValue: 'REQUEST_TIME',
                })),
              }
            : {}),
        })),
      };
      const resp = await fetch(`${root}/${dbName}/documents:commit`, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
      });
      if (resp.ok) return;
      const text = await resp.text();
      if (isPreconditionFailure(resp.status, text)) {
        throw new PreconditionFailedError(`Firestore commit precondition failed: ${text}`);
      }
      throw new Error(`Firestore commit → ${resp.status}: ${text}`);
    },
  };
}

function isPreconditionFailure(status: number, text: string): boolean {
  if (status === 409 || status === 412) return true;
  return (
    (status === 400 || status === 404) &&
    /FAILED_PRECONDITION|NOT_FOUND|ALREADY_EXISTS/.test(text)
  );
}

// --- Firestore REST value codec -------------------------------------------

type Value = Record<string, unknown>;
type FieldMap = Record<string, Value>;

export function decodeFields(fields: FieldMap | undefined): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (!fields) return out;
  for (const [k, v] of Object.entries(fields)) out[k] = decodeValue(v);
  return out;
}

function decodeValue(v: Value | undefined): unknown {
  if (v == null) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('timestampValue' in v) return v.timestampValue; // ISO string
  if ('nullValue' in v) return null;
  if ('mapValue' in v) return decodeFields((v.mapValue as { fields?: FieldMap }).fields);
  if ('arrayValue' in v) {
    return ((v.arrayValue as { values?: Value[] }).values ?? []).map(decodeValue);
  }
  if ('referenceValue' in v) return v.referenceValue;
  return null;
}

export function encodeFields(obj: Record<string, unknown>): FieldMap {
  const out: FieldMap = {};
  for (const [k, val] of Object.entries(obj)) out[k] = encodeValue(val);
  return out;
}

function encodeValue(val: unknown): Value {
  if (val === null || val === undefined) return { nullValue: null };
  if (val instanceof Date) return { timestampValue: val.toISOString() };
  if (typeof val === 'string') return { stringValue: val };
  if (typeof val === 'boolean') return { booleanValue: val };
  if (typeof val === 'number') {
    return Number.isInteger(val) ? { integerValue: String(val) } : { doubleValue: val };
  }
  if (Array.isArray(val)) return { arrayValue: { values: val.map(encodeValue) } };
  if (typeof val === 'object') {
    return { mapValue: { fields: encodeFields(val as Record<string, unknown>) } };
  }
  throw new Error(`encodeValue: unsupported type ${typeof val}`);
}
