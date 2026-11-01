// Pre-flight for the release job in .github/workflows/ios.yml, run before anything is archived:
//   1. API key: format, accepted by App Store Connect, a team key (not an individual key), allowed to read apps
//   2. the app with the project's bundle id exists in App Store Connect
//   3. App Store version for MARKETING_VERSION: if it (or a higher one) is already released, the version train is closed
//      → ship=false plus a warning, the job stays green and skips archive/upload/metadata
//   4. build number = highest build number already in App Store Connect (all versions, TestFlight included) + 1
// Step outputs: ship (true/false), version, build, app_id, state. Prints only status codes and Apple's error texts.
//
// Locally: ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=AuthKey_….p8 node scripts/asc-check.ts
import {
  AscApiError, RELEASED_STATES, EDITABLE_STATES, ascGetAll, ascRequest, buildNumberValue, compareVersions, describeErrors,
  fail, findApp, listIosVersions, readKey, readProjectSettings, setOutput, summary, warn,
} from './asc-api.ts';
import type { App, AscKey, StoreVersion } from './asc-api.ts';

export interface Plan {
  ship: boolean;
  /** state of the App Store version for MARKETING_VERSION, or NOT_CREATED */
  state: string;
  reason: string;
}

/** Decides whether a build with CFBundleShortVersionString `version` can still be shipped. */
export function planRelease(version: string, versions: StoreVersion[]): Plan {
  const same = versions.find((v) => v.versionString === version);
  const state = same?.state ?? 'NOT_CREATED';
  if (same && RELEASED_STATES.has(same.state)) {
    return { ship: false, state, reason: `Version ${version} is already released – bump MARKETING_VERSION to ship a new build (App Store state ${same.state})` };
  }
  const newest = versions
    .filter((v) => RELEASED_STATES.has(v.state) && compareVersions(v.versionString, version) >= 0)
    .sort((a, b) => compareVersions(b.versionString, a.versionString))[0];
  if (newest) {
    return {
      ship: false,
      state,
      reason: `MARKETING_VERSION ${version} is not higher than the released version ${newest.versionString} (${newest.state}) – `
        + 'bump MARKETING_VERSION to ship a new build',
    };
  }
  if (!same) {
    return { ship: true, state, reason: `App Store version ${version} does not exist yet – the metadata step creates it (or renames the version being prepared)` };
  }
  if (EDITABLE_STATES.has(same.state)) {
    return { ship: true, state, reason: `App Store version ${version} is editable (${same.state})` };
  }
  return {
    ship: true,
    state,
    reason: `App Store version ${version} is ${same.state} – the build still goes to TestFlight, but its metadata is locked`,
  };
}

/** HTTP status of the app lookup when the key is used as an individual key (diagnosis only). */
async function probeIndividual(key: AscKey, bundleId: string): Promise<number> {
  try {
    await ascRequest(key, 'GET', `/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&fields[apps]=bundleId&limit=1`);
    return 200;
  } catch (e) {
    return e instanceof AscApiError ? e.status : 0;
  }
}

async function checkKeyAndApp(key: AscKey, bundleId: string): Promise<App> {
  let app: App | null = null;
  try {
    app = await findApp(key, bundleId);
  } catch (e) {
    if (!(e instanceof AscApiError)) throw e;
    const why = describeErrors(e.errors) || `HTTP ${e.status}`;
    console.log(`App Store Connect as team key: HTTP ${e.status} ${describeErrors(e.errors)}`);
    if (e.status === 403) fail(`Key is valid but lacks permission (${why}). Give the API key the Admin role.`);
    if (e.status !== 401) throw e;
    const individual = await probeIndividual({ ...key, issuerId: null }, bundleId);
    console.log(`App Store Connect as individual key: HTTP ${individual}`);
    if (individual === 200) {
      fail('This is an individual key; xcodebuild needs a team key: App Store Connect → Users and Access → Integrations → '
        + 'App Store Connect API → Team Keys (request access first if needed), role Admin. Then set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 again.');
    }
    fail(`App Store Connect rejects the key (${why}). Check: ASC_ISSUER_ID is the issuer ID shown at the top of the Team Keys page, `
      + 'ASC_KEY_ID belongs to the .p8 file in ASC_KEY_P8, and the key has not been revoked.');
  }
  if (!app) {
    const all = await ascGetAll<{ bundleId?: string }>(key, '/v1/apps?fields[apps]=bundleId&limit=200');
    const ids = all.map((a) => a.attributes?.bundleId).filter(Boolean).join(', ') || 'none';
    fail(`Key is valid, but there is no app with bundle id ${bundleId} – create it in App Store Connect → Apps → +. Apps visible to the key: ${ids}.`);
  }
  return app as App;
}

/** Highest numeric CFBundleVersion already known to App Store Connect for this app (0 if none). */
async function highestBuild(key: AscKey, appId: string): Promise<{ highest: number; count: number }> {
  const builds = await ascGetAll<{ version?: string }>(key, `/v1/builds?filter[app]=${appId}&fields[builds]=version&limit=200`);
  let highest = 0;
  for (const b of builds) highest = Math.max(highest, buildNumberValue(b.attributes?.version) || 0);
  // Uploads Apple has not turned into a build yet (e.g. a previous run stopped waiting). Best effort only.
  try {
    const uploads = await ascGetAll<{ cfBundleVersion?: string }>(key, `/v1/apps/${appId}/buildUploads`);
    for (const u of uploads) highest = Math.max(highest, buildNumberValue(u.attributes?.cfBundleVersion) || 0);
  } catch (e) {
    console.log(`(could not list build uploads, using processed builds only: ${e instanceof Error ? e.message : String(e)})`);
  }
  return { highest, count: builds.length };
}

async function main(): Promise<void> {
  const key = readKey();
  const project = readProjectSettings();
  const version = project.marketingVersion;
  console.log(`Project: target "${project.target}", bundle id ${project.bundleId}, `
    + `MARKETING_VERSION ${version}, CURRENT_PROJECT_VERSION ${project.buildNumber} (${project.configuration})`);

  const app = await checkKeyAndApp(key, project.bundleId);
  console.log(`ok: key valid, app "${app.name}" (Apple ID ${app.id}) found`);

  const versions = await listIosVersions(key, app.id);
  console.log(`App Store versions (iOS): ${versions.map((v) => `${v.versionString} ${v.state}`).join(', ') || 'none'}`);
  const plan = planRelease(version, versions);

  const { highest, count } = await highestBuild(key, app.id);
  const build = String(Math.max(highest + 1, buildNumberValue(project.buildNumber) || 0, 1));
  console.log(`Builds in App Store Connect: ${count}, highest build number ${highest || 'none'} → next build number ${build}`);

  setOutput('version', version);
  setOutput('build', build);
  setOutput('app_id', app.id);
  setOutput('state', plan.state);
  setOutput('ship', String(plan.ship));
  if (plan.ship) console.log(`ok: ${plan.reason}`);
  else warn(plan.reason);

  summary([
    '### iOS release',
    '',
    '| | |',
    '|---|---|',
    `| Version (MARKETING_VERSION) | ${version} |`,
    `| Build number | ${plan.ship ? build : `${build} (not used)`} |`,
    `| App Store version state | ${plan.state} |`,
    `| Upload | ${plan.ship ? 'yes' : `skipped: ${plan.reason}`} |`,
    '',
  ].join('\n'));
}

if (import.meta.main) {
  main().catch((e: unknown) => fail(e instanceof Error ? e.message : String(e)));
}
