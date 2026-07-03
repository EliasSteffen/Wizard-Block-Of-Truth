import en from '../i18n/en.json';

export type Dictionary = typeof en;

export function getDictionary(): Dictionary {
  return en;
}

export function pathHref(path: string): string {
  const normalized = path.startsWith('/') ? path : `/${path}`;
  return normalized === '/' ? '/' : normalized;
}
