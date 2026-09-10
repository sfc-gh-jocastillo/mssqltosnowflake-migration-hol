import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  tutorialSidebar: [
    'intro',
    {
      type: 'category',
      label: 'Infraestructura',
      items: ['setup', 'datos-sinteticos'],
    },
    {
      type: 'category',
      label: 'Pipeline de datos',
      items: ['pipeline-medallion', 'transformaciones', 'snowpark'],
    },
    {
      type: 'category',
      label: 'Performance',
      items: ['clustering'],
    },
    {
      type: 'category',
      label: 'Governance',
      items: ['compliance', 'data-quality'],
    },
    {
      type: 'category',
      label: 'Operaciones',
      items: ['devops'],
    },
  ],
};

export default sidebars;
