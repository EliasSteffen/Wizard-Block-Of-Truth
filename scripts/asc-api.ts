// Shared helpers for the App Store Connect scripts used by .github/workflows/ios.yml:
// API key + JWT, a small fetch wrapper with pagination, the app lookup, App Store version states,
// reading MARKETING_VERSION / CURRENT_PROJECT_VERSION / bundle id from project.pbxproj, and GitHub Actions output helpers.
// No npm dependencies: Node >= 22.18 runs these files directly (`node scripts/<name>.ts`, type stripping only).
// Nothing in here ever prints the private key or a token.
import { createPrivateKey, sign } from 'node:crypto';
import { appendFileSync, readFileSync } from 'node:fs';
import { relative } from 'node:path';
import { fileURLToPath } from 'node:url';

export const API = 'https://api.appstoreconnect.apple.com';
export const REPO_ROOT = fileURLToPath(new URL('..', import.meta.url));
export const PBXPROJ = fileURLToPath(new URL('../Wizard-Block-Of-Truth.xcodeproj/project.pbxproj', import.meta.url));

// ---------------------------------------------------------------------------------------------------------------------
// GitHub Actions helpers

/** Escapes a message for a workflow command (`::warning::…`), so multi-line text stays in one annotation. */
const escapeData = (s: string): string => s.replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');

export const warn = (msg: string): void => console.log(`::warning::${escapeData(msg)}`);
export const notice = (msg: string): void => console.log(`::notice::${escapeData(msg)}`);
export const error = (msg: string): void => console.log(`::error::${escapeData(msg)}`);

/** Prints an error annotation and exits with status 1. */
export const fail = (msg: string): never => {
  error(msg);
  process.exit(1);
};

/** Sets a step output (`steps.<id>.outputs.<name>`); prints it when run outside GitHub Actions. */
export function setOutput(name: string, value: string): void {
  if (/[\r\n]/.test(value)) throw new Error(`step output ${name} must be a single line`);
  const file = process.env.GITHUB_OUTPUT;
  if (file) appendFileSync(file, `${name}=${value}\n`);
  console.log(`output ${name}=${value}`);
}

/** Appends Markdown to the job summary (no-op outside GitHub Actions). */
export function summary(markdown: string): void {
  const file = process.env.GITHUB_STEP_SUMMARY;
  if (file) appendFileSync(file, markdown.endsWith('\n') ? markdown : `${markdown}\n`);
}

// ---------------------------------------------------------------------------------------------------------------------
// API key and token

export interface AscKey {
  keyId: string;
  /** null = individual key (only used to diagnose a wrongly created key) */
  issuerId: string | null;
  pem: string;
}

/** JWT for the App Store Connect API (ES256, valid 10 minutes). Without issuerId it has the form of an individual key. */
export function ascToken(o: { keyId: string; issuerId: string | null; pem: string; now: number }): string {
  const iat = Math.floor(o.now / 1000);
  const who = o.issuerId ? { iss: o.issuerId } : { sub: 'user' };
  const enc = (x: unknown): string => Buffer.from(JSON.stringify(x)).toString('base64url');
  const data = `${enc({ alg: 'ES256', kid: o.keyId, typ: 'JWT' })}.${enc({ ...who, iat, exp: iat + 600, aud: 'appstoreconnect-v1' })}`;
  const sig = sign('sha256', Buffer.from(data), { key: createPrivateKey(o.pem), dsaEncoding: 'ieee-p1363' });
  return `${data}.${sig.toString('base64url')}`;
}

/**
 * Reads ASC_KEY_ID, ASC_ISSUER_ID and the .p8 file at ASC_KEY_PATH (the workflow writes the ASC_KEY_P8 secret there)
 * and fails with a clear message when one of them is missing or malformed.
 */
export function readKey(): AscKey {
  const keyId = process.env.ASC_KEY_ID ?? '';
  const issuerId = process.env.ASC_ISSUER_ID ?? '';
  const keyPath = process.env.ASC_KEY_PATH ?? '';
  if (!keyId || !issuerId || !keyPath) {
    fail('Missing environment: ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (path to AuthKey_<KEY_ID>.p8) are required. '
      + 'In CI they come from the secrets ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 (README → Release pipeline).');
  }
  if (!/^[A-Z0-9]{10}$/.test(keyId)) {
    fail('ASC_KEY_ID: expected the 10-character key ID (also part of the file name AuthKey_<KEY_ID>.p8), without spaces or newlines.');
  }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(issuerId)) {
    fail('ASC_ISSUER_ID: expected the issuer ID (a UUID) shown at the top of App Store Connect → Users and Access → Integrations → Team Keys.');
  }
  let pem = '';
  try {
    pem = readFileSync(keyPath, 'utf8');
    createPrivateKey(pem);
  } catch {
    fail('ASC_KEY_P8: not a valid private key – store the complete content of the .p8 file including the BEGIN/END lines '
      + '(gh secret set ASC_KEY_P8 < AuthKey_XXXXXXXXXX.p8).');
  }
  return { keyId, issuerId, pem };
}

// ---------------------------------------------------------------------------------------------------------------------
// HTTP

export interface AscErrorItem {
  status?: string;
  code?: string;
  title?: string;
  detail?: string;
  source?: { pointer?: string; parameter?: string };
}

/** A failed API call: HTTP status plus Apple's error list (never contains the token). */
export class AscApiError extends Error {
  readonly status: number;
  readonly errors: AscErrorItem[];
  constructor(message: string, status: number, errors: AscErrorItem[]) {
    super(message);
    this.name = 'AscApiError';
    this.status = status;
    this.errors = errors;
  }
}

export const describeErrors = (errors: AscErrorItem[]): string =>
  errors
    .map((e) => {
      const where = e.source?.pointer ?? e.source?.parameter;
      return `${e.code ?? e.status ?? ''} ${e.detail ?? e.title ?? ''}${where ? ` (${where})` : ''}`.trim();
    })
    .join('; ');

export interface Resource<A> {
  type: string;
  id: string;
  attributes?: A;
}

interface Page<A> {
  data: Array<Resource<A>>;
  links?: { next?: string };
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/**
 * Calls the API. `path` is either relative to the API host (`/v1/apps?…`) or a full `links.next` URL.
 * GET requests are retried on network errors, 429 and 5xx; other methods are not (they may not be idempotent).
 * Throws AscApiError with Apple's error details on any non-2xx response.
 */
export async function ascRequest<T>(key: AscKey, method: string, path: string, body?: unknown): Promise<T> {
  const url = path.startsWith('https://') ? path : `${API}${path}`;
  const label = `${method} ${new URL(url).pathname}`;
  const attempts = method === 'GET' ? 3 : 1;
  for (let attempt = 1; ; attempt++) {
    const init: RequestInit = {
      method,
      headers: { Authorization: `Bearer ${ascToken({ ...key, now: Date.now() })}`, 'Content-Type': 'application/json' },
    };
    if (body !== undefined) init.body = JSON.stringify(body);
    let res: Response;
    try {
      res = await fetch(url, init);
    } catch (e) {
      if (attempt < attempts) {
        await sleep(attempt * 3000);
        continue;
      }
      throw new Error(`${label}: ${e instanceof Error ? e.message : String(e)}`);
    }
    if ((res.status === 429 || res.status >= 500) && attempt < attempts) {
      await sleep(attempt * 3000);
      continue;
    }
    const json = (await res.json().catch(() => ({}))) as T & { errors?: AscErrorItem[] };
    if (!res.ok) {
      const errors = json.errors ?? [];
      throw new AscApiError(`${label}: HTTP ${res.status} ${describeErrors(errors)}`.trim(), res.status, errors);
    }
    return json;
  }
}

/** GETs every page of a collection (follows `links.next`). */
export async function ascGetAll<A>(key: AscKey, path: string): Promise<Array<Resource<A>>> {
  const all: Array<Resource<A>> = [];
  let next: string | undefined = path;
  while (next) {
    const page: Page<A> = await ascRequest<Page<A>>(key, 'GET', next);
    all.push(...(page.data ?? []));
    next = page.links?.next;
  }
  return all;
}

// ---------------------------------------------------------------------------------------------------------------------
// App, versions, builds

export interface App {
  id: string;
  bundleId: string;
  name: string;
}

/** Finds the app by exact bundle id (the API filter alone may also match other bundle ids). */
export async function findApp(key: AscKey, bundleId: string): Promise<App | null> {
  const apps = await ascGetAll<{ bundleId?: string; name?: string }>(
    key, `/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&fields[apps]=bundleId,name&limit=200`);
  const app = apps.find((a) => a.attributes?.bundleId === bundleId);
  return app ? { id: app.id, bundleId, name: app.attributes?.name ?? '' } : null;
}

/**
 * Approved versions: Apple closes their version train, so builds with this CFBundleShortVersionString (or a lower one)
 * are rejected ("The train version is closed for new build submissions" / ITMS-90062).
 * Contains values of both `appVersionState` (current) and the deprecated `appStoreState`.
 */
export const RELEASED_STATES: ReadonlySet<string> = new Set([
  'ACCEPTED',
  'PENDING_APPLE_RELEASE',
  'PENDING_DEVELOPER_RELEASE',
  'PROCESSING_FOR_DISTRIBUTION',
  'PROCESSING_FOR_APP_STORE',
  'READY_FOR_DISTRIBUTION',
  'READY_FOR_SALE',
  'PREORDER_READY_FOR_SALE',
  'REPLACED_WITH_NEW_VERSION',
  'REMOVED_FROM_SALE',
  'DEVELOPER_REMOVED_FROM_SALE',
]);

/** Versions whose metadata and build can still be changed. Everything else (in review, approved, …) is locked. */
export const EDITABLE_STATES: ReadonlySet<string> = new Set([
  'PREPARE_FOR_SUBMISSION',
  'DEVELOPER_REJECTED',
  'REJECTED',
  'METADATA_REJECTED',
  'INVALID_BINARY',
]);

export interface StoreVersion {
  id: string;
  versionString: string;
  state: string;
}

interface StoreVersionAttributes {
  versionString?: string;
  platform?: string;
  appVersionState?: string;
  appStoreState?: string;
}

export const storeVersion = (r: Resource<StoreVersionAttributes>): StoreVersion => ({
  id: r.id,
  versionString: r.attributes?.versionString ?? '',
  state: r.attributes?.appVersionState ?? r.attributes?.appStoreState ?? 'UNKNOWN',
});

/** All iOS App Store versions of the app (no `fields[…]` so both state attributes come back). */
export async function listIosVersions(key: AscKey, appId: string): Promise<StoreVersion[]> {
  const list = await ascGetAll<StoreVersionAttributes>(key, `/v1/apps/${appId}/appStoreVersions?filter[platform]=IOS&limit=200`);
  return list.map(storeVersion);
}

/** Compares dotted numeric versions ("1.2" < "1.10", "1.1" == "1.1.0"). */
export function compareVersions(a: string, b: string): number {
  const pa = a.split('.').map((x) => Number.parseInt(x, 10) || 0);
  const pb = b.split('.').map((x) => Number.parseInt(x, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d;
  }
  return 0;
}

/** Numeric value of a CFBundleVersion ("7" → 7, "7.1" → 7); NaN for anything non-numeric. */
export const buildNumberValue = (v: string | undefined): number =>
  v && /^\d+(\.\d+)*$/.test(v.trim()) ? Number.parseInt(v.trim(), 10) : Number.NaN;

// ---------------------------------------------------------------------------------------------------------------------
// Xcode project

export interface ProjectSettings {
  target: string;
  configuration: string;
  bundleId: string;
  /** MARKETING_VERSION → CFBundleShortVersionString */
  marketingVersion: string;
  /** CURRENT_PROJECT_VERSION → CFBundleVersion */
  buildNumber: string;
}

const unquote = (v: string): string =>
  v.startsWith('"') && v.endsWith('"') ? v.slice(1, -1).replace(/\\(.)/g, '$1') : v;

const escapeRe = (s: string): string => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * Reads bundle id and version numbers of the single application target from project.pbxproj (Release configuration,
 * falling back to the project-level configuration like Xcode does). Fails with a clear message when the project is
 * ambiguous (several app targets, missing configuration) or a value is not a literal.
 */
export function readProjectSettings(configuration = 'Release', path = PBXPROJ): ProjectSettings {
  const text = readFileSync(path, 'utf8');
  // Multi-line objects only (`<ID> /* comment */ = {` + newline … `};` at the same indentation)
  const objects = new Map<string, string>();
  for (const m of text.matchAll(/^\t\t([0-9A-Fa-f]{24})(?: \/\*.*?\*\/)? = \{\n([\s\S]*?)\n\t\t\};$/gm)) {
    objects.set(m[1], m[2]);
  }
  const field = (body: string, key: string): string | undefined => {
    const m = new RegExp(`^\\t\\t\\t${escapeRe(key)} = ("(?:[^"\\\\]|\\\\.)*"|[^;\\n]*);`, 'm').exec(body);
    return m ? unquote(m[1]) : undefined;
  };
  const ref = (body: string, key: string): string | undefined =>
    new RegExp(`^\\t\\t\\t${escapeRe(key)} = ([0-9A-Fa-f]{24})\\b`, 'm').exec(body)?.[1];
  const where = `${relative(REPO_ROOT, path) || path} (${configuration})`;

  /** Build settings block of the configuration named `configuration` in a configuration list. */
  const settingsOf = (listId: string | undefined, owner: string): string => {
    const list = listId ? objects.get(listId) : undefined;
    if (!list) fail(`${where}: no build configuration list for ${owner}`);
    const ids = /buildConfigurations = \(([\s\S]*?)\);/.exec(list as string)?.[1].match(/[0-9A-Fa-f]{24}/g) ?? [];
    const configs = ids.map((id) => objects.get(id) ?? '').filter((b) => field(b, 'name') === configuration);
    if (configs.length !== 1) fail(`${where}: expected exactly one "${configuration}" configuration for ${owner}, found ${configs.length}`);
    return /^\t\t\tbuildSettings = \{\n([\s\S]*?)\n\t\t\t\};$/m.exec(configs[0])?.[1] ?? '';
  };
  const setting = (settings: string, key: string): string | undefined => {
    const m = new RegExp(`^\\s*${escapeRe(key)} = ("(?:[^"\\\\]|\\\\.)*"|[^;\\n]*);$`, 'm').exec(settings);
    return m ? unquote(m[1].trim()) : undefined;
  };

  const apps = [...objects.values()].filter(
    (b) => field(b, 'isa') === 'PBXNativeTarget' && field(b, 'productType') === 'com.apple.product-type.application');
  if (apps.length !== 1) fail(`${where}: expected exactly one application target, found ${apps.length}`);
  const target = field(apps[0], 'name') ?? '?';
  const project = [...objects.values()].find((b) => field(b, 'isa') === 'PBXProject');

  const targetSettings = settingsOf(ref(apps[0], 'buildConfigurationList'), `target "${target}"`);
  const projectSettings = project ? settingsOf(ref(project, 'buildConfigurationList'), 'the project') : '';
  const get = (key: string): string | undefined => setting(targetSettings, key) ?? setting(projectSettings, key);

  const literal = (key: string, value: string | undefined, pattern: RegExp, hint: string): string => {
    if (value === undefined) fail(`${where}: ${key} is not set for target "${target}" (xcconfig files are not read by this script)`);
    if (!pattern.test(value as string)) fail(`${where}: ${key} is "${value}" – expected ${hint}, written literally in the project`);
    return value as string;
  };
  const version = /^\d+(\.\d+){0,2}$/;
  return {
    target,
    configuration,
    bundleId: literal('PRODUCT_BUNDLE_IDENTIFIER', get('PRODUCT_BUNDLE_IDENTIFIER'), /^[A-Za-z0-9.-]+$/, 'a bundle id'),
    marketingVersion: literal('MARKETING_VERSION', get('MARKETING_VERSION'), version, 'one to three dot-separated integers (e.g. 1.2 or 1.2.3)'),
    buildNumber: literal('CURRENT_PROJECT_VERSION', get('CURRENT_PROJECT_VERSION') ?? '1', version, 'one to three dot-separated integers'),
  };
}
