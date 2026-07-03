/** App Store listing (id6761933762 — opens the user’s local storefront). */
export const APP_STORE_URL = 'https://apps.apple.com/app/id6761933762';

export const GITHUB_URL = 'https://github.com/EliasSteffen/Wizard-Block-Of-Truth';
export const GITHUB_ISSUES_URL = `${GITHUB_URL}/issues`;

export const SITE_NAME = 'Wizard Block of Truth';

export function isAppStoreConfigured(): boolean {
  return !APP_STORE_URL.includes('XXXXXXXXX');
}
