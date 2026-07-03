import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const releases = defineCollection({
  loader: glob({ pattern: '**/*.json', base: './src/content/releases' }),
  schema: z.object({
    version: z.string(),
    date: z.string(),
    sortOrder: z.number(),
    items: z.array(z.string()),
  }),
});

export const collections = { releases };
