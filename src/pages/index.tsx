import type {ReactNode} from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';
import Heading from '@theme/Heading';
import styles from './index.module.css';

const features = [
  {
    title: 'Pipeline Medallion',
    description: 'Bronze, Silver, Gold con Dynamic Tables. Orquestacion automatica sin schedulers externos.',
    link: '/tutorial/pipeline-medallion',
    icon: '1',
  },
  {
    title: 'Snowpark Python',
    description: 'API de DataFrames nativa sobre Snowflake. Sin infraestructura adicional.',
    link: '/tutorial/snowpark',
    icon: '2',
  },
  {
    title: 'Clustering y Performance',
    description: 'Reduccion de 260 TB a 10 TB/mes de scanning con clustering keys. Benchmark antes y despues.',
    link: '/tutorial/clustering',
    icon: '3',
  },
  {
    title: 'Compliance y Pseudonimizacion',
    description: 'Derecho al olvido con hash irreversible. Masking policies por rol. Auditoria completa.',
    link: '/tutorial/compliance',
    icon: '4',
  },
  {
    title: 'Data Quality y Governance',
    description: 'DMFs nativos, clasificacion automatica de PII, tags y monitoreo con ACCOUNT_USAGE.',
    link: '/tutorial/data-quality',
    icon: '5',
  },
  {
    title: 'DevOps y CI/CD',
    description: 'Multi-environment con clone zero-copy, GitHub Actions con OIDC, rollback con Time Travel.',
    link: '/tutorial/devops',
    icon: '6',
  },
];

function HomepageHeader() {
  const {siteConfig} = useDocusaurusContext();
  return (
    <header className={clsx('hero hero--primary', styles.heroBanner)}>
      <div className="container">
        <Heading as="h1" className="hero__title">
          {siteConfig.title}
        </Heading>
        <p className="hero__subtitle">{siteConfig.tagline}</p>
        <div className={styles.buttons}>
          <Link className="button button--secondary button--lg" to="/tutorial/intro">
            Comenzar el tutorial
          </Link>
        </div>
        <div style={{marginTop: '2rem', display: 'flex', gap: '2rem', justifyContent: 'center', flexWrap: 'wrap'}}>
          <Stat value="50M+" label="filas de datos" />
          <Stat value="96%" label="menos scanning" />
          <Stat value="8h a 2h" label="ETL reducido" />
          <Stat value="6" label="modulos" />
        </div>
      </div>
    </header>
  );
}

function Stat({value, label}: {value: string; label: string}) {
  return (
    <div style={{textAlign: 'center'}}>
      <div style={{fontSize: '2rem', fontWeight: 700, color: 'white'}}>{value}</div>
      <div style={{fontSize: '0.9rem', opacity: 0.8, color: 'white'}}>{label}</div>
    </div>
  );
}

function FeatureCard({title, description, link, icon}: {title: string; description: string; link: string; icon: string}) {
  return (
    <div className="col col--4" style={{marginBottom: '1.5rem'}}>
      <Link to={link} style={{textDecoration: 'none', color: 'inherit'}}>
        <div className="feature-card" style={{height: '100%'}}>
          <div style={{fontSize: '2rem', fontWeight: 700, color: 'var(--ifm-color-primary)', marginBottom: '0.5rem'}}>
            {icon}
          </div>
          <Heading as="h3">{title}</Heading>
          <p>{description}</p>
        </div>
      </Link>
    </div>
  );
}

export default function Home(): ReactNode {
  return (
    <Layout title="Inicio" description="POC de migracion a Snowflake — guia paso a paso">
      <HomepageHeader />
      <main>
        <section style={{padding: '3rem 0'}}>
          <div className="container">
            <div className="row">
              <div className="col col--8 col--offset-2" style={{textAlign: 'center', marginBottom: '2rem'}}>
                <Heading as="h2">Que cubre esta POC</Heading>
                <p>
                  Migracion de un Data Warehouse desde plataforma origen a Snowflake.
                  Cada modulo incluye codigo ejecutable, explicaciones tecnicas, y metricas de resultado.
                </p>
              </div>
            </div>
            <div className="row">
              {features.map((f) => (
                <FeatureCard key={f.title} {...f} />
              ))}
            </div>
          </div>
        </section>
        <section style={{padding: '3rem 0', background: 'var(--ifm-background-surface-color)'}}>
          <div className="container">
            <div className="row">
              <div className="col col--6">
                <Heading as="h2">Escenario de migracion</Heading>
                <ul>
                  <li><strong>Industria</strong>: Servicios financieros</li>
                  <li><strong>Origen</strong>: Data Warehouse on-premise con ETL batch</li>
                  <li><strong>Volumetria</strong>: ~300 GB, 1,000M+ filas, 1,300+ tablas</li>
                  <li><strong>Problema</strong>: ETL lento, scanning excesivo</li>
                  <li><strong>Objetivo</strong>: ETL en menos de 2 horas, scanning reducido &gt;90%</li>
                </ul>
              </div>
              <div className="col col--6">
                <Heading as="h2">Stack propuesto</Heading>
                <ul>
                  <li><strong>Compute</strong>: Warehouse Medium (ETL) + Small (BI)</li>
                  <li><strong>Pipeline</strong>: Medallion con Dynamic Tables</li>
                  <li><strong>Procesos</strong>: Snowpark Python</li>
                  <li><strong>Compliance</strong>: Masking + pseudonimizacion</li>
                  <li><strong>DevOps</strong>: GitHub Actions + OIDC + multi-environment</li>
                  <li><strong>Edicion</strong>: Enterprise</li>
                </ul>
              </div>
            </div>
          </div>
        </section>
      </main>
    </Layout>
  );
}
