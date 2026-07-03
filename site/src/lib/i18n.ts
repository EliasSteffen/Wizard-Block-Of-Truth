import en from '../i18n/en.json';

export type Dictionary = typeof en;

export function getDictionary(): Dictionary {
  return en;
}

export function pathHref(path: string): string {
  const base = import.meta.env.BASE_URL.replace(/\/$/, ''); // strip trailing slash
  const normalized = path.startsWith('/') ? path : `/${path}`;
  return `${base}${normalized}`;
}
