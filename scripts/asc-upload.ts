// Uploads the signed .ipa through the App Store Connect API (buildUploads), bypassing Xcode's older upload service,
// which rejects team keys with "Cannot verify client's JWT headers". Called by .github/workflows/ios.yml:
//   node scripts/asc-upload.ts <ipa> <version> <build number>
// Flow: create upload → register the file → send the parts to the URLs Apple hands out → mark as uploaded with the MD5
// → wait for processing and report Apple's errors. Prints only status messages, never the key.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { basename } from 'node:path';
import { ascRequest, fail, findApp, readKey, readProjectSettings, summary } from './asc-api.ts';

/** How long to wait for Apple's processing result; after that it continues on Apple's side. */
const WAIT_MS = 20 * 60_000;
const POLL_MS = 30_000;

interface Detail {
  code?: string;
  description?: string;
}
interface UploadOperation {
  method: string;
  url: string;
  offset: number;
  length: number;
  requestHeaders?: Array<{ name: string; value: string }>;
}
interface UploadState {
  state?: string;
  errors?: Detail[];
  warnings?: Detail[];
}

const details = (list: Detail[] | undefined): string =>
  (list ?? []).map((d) => `${d.code ?? ''}: ${d.description ?? ''}`).join('; ');

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/** Sends one part to Apple's storage; retried a few times because a single network hiccup should not fail a release. */
async function sendPart(op: UploadOperation, file: Uint8Array<ArrayBuffer>, label: string): Promise<void> {
  const headers = Object.fromEntries((op.requestHeaders ?? []).map((h) => [h.name, h.value]));
  for (let attempt = 1; ; attempt++) {
    let status = 0; // 0 = network error
    let why = '';
    try {
      const res = await fetch(op.url, { method: op.method, headers, body: file.subarray(op.offset, op.offset + op.length) });
      if (res.ok) return;
      status = res.status;
      why = `HTTP ${res.status}`;
    } catch (e) {
      why = e instanceof Error ? e.message : String(e);
    }
    const retryable = status === 0 || status === 429 || status >= 500;
    if (!retryable || attempt >= 3) throw new Error(`${label}: ${why}`);
    await sleep(attempt * 5000);
  }
}

async function main(): Promise<void> {
  const [ipaPath = '', version = '', build = ''] = process.argv.slice(2);
  if (!ipaPath || !version || !build) fail('Usage: node scripts/asc-upload.ts <ipa> <version> <build number>');
  const key = readKey();
  const { bundleId } = readProjectSettings();

  const app = await findApp(key, bundleId);
  if (!app) throw new Error(`No app with bundle id ${bundleId} in App Store Connect`);

  const file = readFileSync(ipaPath);
  const md5 = createHash('md5').update(file).digest('hex');
  console.log(`${basename(ipaPath)}: ${(file.length / 1024 / 1024).toFixed(1)} MB, version ${version} (${build})`);

  const upload = await ascRequest<{ data: { id: string } }>(key, 'POST', '/v1/buildUploads', {
    data: {
      type: 'buildUploads',
      attributes: { cfBundleShortVersionString: version, cfBundleVersion: build, platform: 'IOS' },
      relationships: { app: { data: { type: 'apps', id: app.id } } },
    },
  });

  const uploadFile = await ascRequest<{ data: { id: string; attributes: { uploadOperations?: UploadOperation[] } } }>(
    key, 'POST', '/v1/buildUploadFiles', {
      data: {
        type: 'buildUploadFiles',
        attributes: { assetType: 'ASSET', fileName: basename(ipaPath), fileSize: file.length, uti: 'com.apple.ipa' },
        relationships: { buildUpload: { data: { type: 'buildUploads', id: upload.data.id } } },
      },
    });

  const ops = uploadFile.data.attributes.uploadOperations ?? [];
  for (const [i, op] of ops.entries()) await sendPart(op, file, `part ${i + 1}/${ops.length}`);
  console.log(`${ops.length} part(s) sent`);

  await ascRequest(key, 'PATCH', `/v1/buildUploadFiles/${uploadFile.data.id}`, {
    data: {
      type: 'buildUploadFiles',
      id: uploadFile.data.id,
      attributes: { uploaded: true, sourceFileChecksums: { file: { algorithm: 'MD5', hash: md5 } } },
    },
  });

  const end = Date.now() + WAIT_MS;
  let lastState = '';
  for (;;) {
    const r = await ascRequest<{ data: { attributes: { state?: UploadState } } }>(
      key, 'GET', `/v1/buildUploads/${upload.data.id}?fields[buildUploads]=state`);
    const st = r.data.attributes.state;
    if (st?.state && st.state !== lastState) console.log(`Processing state: ${st.state}`);
    lastState = st?.state ?? lastState;
    if (st?.warnings?.length) console.log(`Notes from Apple: ${details(st.warnings)}`);
    if (st?.state === 'COMPLETE') {
      console.log('ok: build uploaded and processed – visible in App Store Connect → TestFlight');
      summary(`Uploaded version ${version} (build ${build}); Apple finished processing – it is in TestFlight.`);
      return;
    }
    if (st?.state === 'FAILED') throw new Error(`Apple rejected the build: ${details(st.errors) || 'no reason given'}`);
    if (Date.now() > end) {
      console.log(`Uploaded; processing still running (${st?.state ?? 'unknown'}) – the build appears in TestFlight afterwards`);
      summary(`Uploaded version ${version} (build ${build}); Apple is still processing it – it appears in TestFlight afterwards.`);
      return;
    }
    await sleep(POLL_MS);
  }
}

if (import.meta.main) {
  main().catch((e: unknown) => fail(e instanceof Error ? e.message : String(e)));
}
