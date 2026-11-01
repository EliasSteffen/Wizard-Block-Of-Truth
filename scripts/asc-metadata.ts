// Syncs the App Store texts in fastlane/metadata/<locale>/ to the App Store version for MARKETING_VERSION.
// Called by .github/workflows/ios.yml after the upload. It NEVER submits anything for review.
//   description.txt → description, promotional_text.txt → promotionalText, release_notes.txt → whatsNew
// Missing or empty files are skipped (the value in App Store Connect stays as it is); only changed fields are sent.
// Steps:
//   1. find the iOS App Store version for VERSION; if there is none, rename the editable version (when it is lower)
//      or create a new one. Versions in review or already released are left alone (warning, exit 0).
//   2. create or update the appStoreVersionLocalizations of every locale folder (de-DE, en-GB, …; other folders such
//      as promotion-images are ignored)
//   3. if BUILD is set: attach that build to the version once Apple has processed it (failures are only warnings)
// Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, VERSION (default: MARKETING_VERSION from the project), BUILD (optional)
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  AscApiError, EDITABLE_STATES, RELEASED_STATES, REPO_ROOT, ascGetAll, ascRequest, compareVersions, describeErrors, error,
  fail, findApp, listIosVersions, notice, readKey, readProjectSettings, storeVersion, summary, warn,
} from './asc-api.ts';
import type { AscKey, Resource, StoreVersion } from './asc-api.ts';

const METADATA_DIR = join(REPO_ROOT, 'fastlane', 'metadata');
/** App Store Connect locale codes look like `de-DE`, `en-GB`, `ja`, `zh-Hans`. */
const LOCALE = /^[a-z]{2,3}(-[A-Za-z]{2,4})?$/;
const FIELDS = [
  { file: 'description.txt', attribute: 'description', label: 'Description' },
  { file: 'promotional_text.txt', attribute: 'promotionalText', label: 'Promotional text' },
  { file: 'release_notes.txt', attribute: 'whatsNew', label: "What's New" },
] as const;
/** How long to wait for the uploaded build to finish processing before giving up on attaching it. */
const ATTACH_WAIT_MS = 10 * 60_000;
const POLL_MS = 30_000;

type Attribute = (typeof FIELDS)[number]['attribute'];
type Texts = Partial<Record<Attribute, string>>;
type LocalizationAttributes = Partial<Record<Attribute, string | null>> & { locale?: string };

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
const normalize = (s: string | null | undefined): string => (s ?? '').replace(/\r\n?/g, '\n').trimEnd();

/** Reads every locale folder that contains at least one non-empty text file. */
function readLocales(): Array<{ locale: string; texts: Texts }> {
  if (!existsSync(METADATA_DIR)) return [];
  const result: Array<{ locale: string; texts: Texts }> = [];
  for (const entry of readdirSync(METADATA_DIR, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (!entry.isDirectory()) continue;
    if (!LOCALE.test(entry.name)) {
      console.log(`Ignoring fastlane/metadata/${entry.name} (not a locale)`);
      continue;
    }
    const texts: Texts = {};
    for (const f of FIELDS) {
      const path = join(METADATA_DIR, entry.name, f.file);
      const text = existsSync(path) ? normalize(readFileSync(path, 'utf8')) : '';
      if (text) texts[f.attribute] = text;
    }
    if (Object.keys(texts).length > 0) result.push({ locale: entry.name, texts });
    else console.log(`Ignoring fastlane/metadata/${entry.name} (no texts)`);
  }
  return result;
}

/** The editable App Store version for `version` – found, renamed or created – or null when it cannot be edited now. */
async function resolveVersion(key: AscKey, appId: string, version: string): Promise<StoreVersion | null> {
  const versions = await listIosVersions(key, appId);
  const same = versions.find((v) => v.versionString === version);
  if (same) {
    if (EDITABLE_STATES.has(same.state)) return same;
    warn(RELEASED_STATES.has(same.state)
      ? `Metadata not synced: version ${version} is already released (${same.state}) – bump MARKETING_VERSION`
      : `Metadata not synced: App Store version ${version} is ${same.state}; its texts are locked until Apple's review is done`);
    return null;
  }
  // Like fastlane deliver: a version that is still being prepared gets the new version number instead of a second version
  const editable = versions.find((v) => EDITABLE_STATES.has(v.state));
  if (editable && compareVersions(version, editable.versionString) <= 0) {
    warn(`Metadata not synced: App Store version ${editable.versionString} (${editable.state}) is being prepared and is not lower `
      + `than MARKETING_VERSION ${version} – fix the version in the project or in App Store Connect`);
    return null;
  }
  try {
    if (editable) {
      await ascRequest(key, 'PATCH', `/v1/appStoreVersions/${editable.id}`, {
        data: { type: 'appStoreVersions', id: editable.id, attributes: { versionString: version } },
      });
      console.log(`Renamed the editable App Store version ${editable.versionString} (${editable.state}) to ${version}`);
      return { ...editable, versionString: version };
    }
    const created = await ascRequest<{ data: Resource<{ versionString?: string; appVersionState?: string; appStoreState?: string }> }>(
      key, 'POST', '/v1/appStoreVersions', {
        data: {
          type: 'appStoreVersions',
          attributes: { platform: 'IOS', versionString: version },
          relationships: { app: { data: { type: 'apps', id: appId } } },
        },
      });
    const v = storeVersion(created.data);
    console.log(`Created App Store version ${version} (${v.state})`);
    return { ...v, versionString: v.versionString || version };
  } catch (e) {
    // e.g. another version is still in review or waiting for release: App Store Connect allows only one open version
    if (e instanceof AscApiError && e.status === 409) {
      const others = versions.map((o) => `${o.versionString} ${o.state}`).join(', ') || 'none';
      warn(`Metadata not synced: App Store Connect does not allow ${editable ? 'renaming the version being prepared to' : 'creating version'} `
        + `${version} now (${describeErrors(e.errors)}). Existing versions: ${others}`);
      return null;
    }
    throw e;
  }
}

/** Whether Apple's error is (or may be) about whatsNew: it names the field, or it is a 409 that names no other field. */
const maybeWhatsNew = (e: AscApiError): boolean =>
  e.errors.some((x) => /whatsNew/i.test(`${x.source?.pointer ?? ''} ${x.detail ?? ''}`))
  || (e.status === 409 && !e.errors.some((x) => x.source?.pointer?.startsWith('/data/attributes/')));

/**
 * Creates or updates one localization. Apple rejects `whatsNew` on the very first version of an app: then the other
 * fields are saved without it and a warning is printed. Returns true when whatsNew was dropped.
 */
async function saveLocalization(
  key: AscKey, versionId: string, locale: string, currentId: string | undefined, attributes: Texts,
): Promise<boolean> {
  const send = (attrs: Texts): Promise<unknown> => currentId
    ? ascRequest(key, 'PATCH', `/v1/appStoreVersionLocalizations/${currentId}`, {
      data: { type: 'appStoreVersionLocalizations', id: currentId, attributes: attrs },
    })
    : ascRequest(key, 'POST', '/v1/appStoreVersionLocalizations', {
      data: {
        type: 'appStoreVersionLocalizations',
        attributes: { locale, ...attrs },
        relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: versionId } } },
      },
    });
  try {
    await send(attributes);
    return false;
  } catch (e) {
    if (!(e instanceof AscApiError) || attributes.whatsNew === undefined || !maybeWhatsNew(e)) throw e;
    const { whatsNew: _dropped, ...rest } = attributes;
    if (Object.keys(rest).length > 0 || !currentId) await send(rest);
    warn(`${locale}: Apple did not accept the release notes (whatsNew), the other texts were saved – `
      + `this is expected for the very first version of an app (${describeErrors(e.errors)})`);
    return true;
  }
}

/** Attaches the uploaded build to the version once Apple has processed it. Returns a line for the summary. */
async function attachBuild(key: AscKey, appId: string, v: StoreVersion, build: string): Promise<string> {
  const deadline = Date.now() + ATTACH_WAIT_MS;
  for (;;) {
    const builds = await ascGetAll<{ version?: string; processingState?: string }>(key, `/v1/builds?filter[app]=${appId}`
      + `&filter[version]=${encodeURIComponent(build)}&filter[preReleaseVersion.version]=${encodeURIComponent(v.versionString)}`
      + '&fields[builds]=version,processingState&limit=10');
    const b = builds.find((x) => x.attributes?.version === build);
    const state = b?.attributes?.processingState;
    if (b && state === 'VALID') {
      await ascRequest(key, 'PATCH', `/v1/appStoreVersions/${v.id}/relationships/build`, { data: { type: 'builds', id: b.id } });
      console.log(`ok: build ${build} attached to version ${v.versionString}`);
      return `Build ${build} is attached to version ${v.versionString}.`;
    }
    if (state === 'FAILED' || state === 'INVALID') {
      warn(`Build ${build} was not attached: Apple marked it ${state}`);
      return `Build ${build} was not attached (Apple marked it ${state}).`;
    }
    if (Date.now() > deadline) {
      notice(`Build ${build} is not processed yet (${state ?? 'not visible yet'}) – select it for version ${v.versionString} in App Store Connect`);
      return `Build ${build} was not attached yet (${state ?? 'not visible yet'}); select it in App Store Connect once it is processed.`;
    }
    await sleep(POLL_MS);
  }
}

async function main(): Promise<void> {
  const key = readKey();
  const project = readProjectSettings();
  const version = process.env.VERSION || project.marketingVersion;
  const build = process.env.BUILD ?? '';
  if (!/^\d+(\.\d+){0,2}$/.test(version)) fail(`VERSION "${version}" is not a valid version number`);

  const locales = readLocales();
  if (locales.length === 0) {
    notice('No App Store texts found in fastlane/metadata/<locale>/ – nothing to sync');
    return;
  }
  const app = await findApp(key, project.bundleId);
  if (!app) fail(`No app with bundle id ${project.bundleId} in App Store Connect`);
  const appId = (app as { id: string }).id;

  const v = await resolveVersion(key, appId, version);
  if (!v) {
    summary(`### App Store metadata\n\nNot synced for version ${version} – see the warning in the log.\n`);
    return;
  }

  const existing = await ascGetAll<LocalizationAttributes>(key, `/v1/appStoreVersions/${v.id}/appStoreVersionLocalizations?limit=50`);
  const rows: string[] = [];
  let failed = 0;
  for (const { locale, texts } of locales) {
    const current = existing.find((l) => l.attributes?.locale === locale);
    const changed: Texts = {};
    for (const f of FIELDS) {
      const value = texts[f.attribute];
      if (value !== undefined && normalize(current?.attributes?.[f.attribute]) !== value) changed[f.attribute] = value;
    }
    const status = (attr: Attribute, droppedWhatsNew: boolean): string => {
      if (texts[attr] === undefined) return 'no file';
      if (attr === 'whatsNew' && droppedWhatsNew) return 'rejected by Apple';
      if (changed[attr] === undefined) return 'unchanged';
      return current ? 'updated' : 'created';
    };
    try {
      let dropped = false;
      if (Object.keys(changed).length > 0 || !current) {
        dropped = await saveLocalization(key, v.id, locale, current?.id, changed);
      }
      const cells = FIELDS.map((f) => status(f.attribute, dropped));
      console.log(`${locale}: ${FIELDS.map((f, i) => `${f.label} ${cells[i]}`).join(', ')}`);
      rows.push(`| ${locale} | ${cells.join(' | ')} |`);
    } catch (e) {
      failed++;
      error(`${locale}: ${e instanceof Error ? e.message : String(e)}`);
      rows.push(`| ${locale} | ${FIELDS.map(() => 'failed').join(' | ')} |`);
    }
  }

  let buildLine = '';
  if (build) {
    try {
      buildLine = await attachBuild(key, appId, v, build);
    } catch (e) {
      warn(`Build ${build} was not attached to version ${v.versionString}: ${e instanceof Error ? e.message : String(e)}`);
      buildLine = `Build ${build} was not attached (see the warning in the log); select it in App Store Connect.`;
    }
  }

  summary([
    `### App Store metadata – version ${v.versionString} (${v.state})`,
    '',
    `| Locale | ${FIELDS.map((f) => f.label).join(' | ')} |`,
    `|---|${FIELDS.map(() => '---').join('|')}|`,
    ...rows,
    '',
    ...(buildLine ? [buildLine, ''] : []),
    'Not submitted for review – submit the version in App Store Connect when it is ready.',
    '',
  ].join('\n'));
  if (failed > 0) fail(`${failed} locale(s) could not be synced (see the errors above)`);
  console.log('ok: metadata synced (not submitted for review)');
}

if (import.meta.main) {
  main().catch((e: unknown) => fail(e instanceof Error ? e.message : String(e)));
}
