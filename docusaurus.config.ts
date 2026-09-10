import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
  title: 'Hands-on Lab — Migracion plataforma origen a Snowflake',
  tagline: 'Guia paso a paso: Pipeline Medallion, Performance, Compliance y DevOps',
  favicon: 'img/favicon.svg',

  future: {
    v4: false,
  },

  url: 'https://jocastillo.github.io',
  baseUrl: '/mssqltosnowflake-migration-hol/',

  organizationName: 'sfc-gh-jocastillo',
  projectName: 'mssqltosnowflake-migration-hol',

  onBrokenLinks: 'throw',

  i18n: {
    defaultLocale: 'es',
    locales: ['es'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          routeBasePath: 'tutorial',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    image: 'img/social-card.png',
    colorMode: {
      defaultMode: 'dark',
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: 'Hands-on Lab',
      logo: {
        alt: 'Snowflake',
        src: 'img/logo.svg',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'tutorialSidebar',
          position: 'left',
          label: 'Tutorial',
        },
        {
          href: 'https://github.com/jocastillo/snowflake-migration-poc',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Tutorial',
          items: [
            { label: 'Inicio', to: '/tutorial/intro' },
            { label: 'Pipeline Medallion', to: '/tutorial/pipeline-medallion' },
            { label: 'Clustering', to: '/tutorial/clustering' },
          ],
        },
        {
          title: 'Recursos',
          items: [
            { label: 'Snowflake Docs', href: 'https://docs.snowflake.com' },
            { label: 'Snowpark Python', href: 'https://docs.snowflake.com/en/developer-guide/snowpark/python/index' },
            { label: 'Dynamic Tables', href: 'https://docs.snowflake.com/en/user-guide/dynamic-tables-about' },
          ],
        },
      ],
      copyright: `Snowflake POC Guide — ${new Date().getFullYear()}`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ['sql', 'python', 'bash', 'yaml'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
