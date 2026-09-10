---
sidebar_position: 1
slug: /intro
---

# Introduccion

Esta guia cubre la migracion completa de un Data Warehouse financiero desde **plataforma origen** hacia **Snowflake**, con codigo ejecutable en cada paso.

## Para quien es esta guia

Data engineers con experiencia en plataformas de datos y herramientas de ETL/pipeline que necesitan evaluar Snowflake como plataforma de datos.

## Que vas a construir

| Modulo | Que resuelve |
|--------|-------------|
| [Setup](setup) | Infraestructura: database, warehouses, roles |
| [Datos sinteticos](datos-sinteticos) | 50M+ filas para benchmarks |
| [Pipeline Medallion](pipeline-medallion) | Bronze/Silver/Gold con Dynamic Tables |
| [Transformaciones](transformaciones) | SPs + Task DAG paralelo |
| [Snowpark Python](snowpark) | 3 procesos complejos con Snowpark |
| [Clustering](clustering) | Reduccion de scanning de 260 TB a 10 TB |
| [Compliance](compliance) | Pseudonimizacion + masking por rol |
| [Data Quality](data-quality) | DMFs, tags, clasificacion PII |
| [DevOps](devops) | Multi-env, CI/CD, rollback con Time Travel |

## Requisitos

- Cuenta Snowflake con rol `ACCOUNTADMIN`
- Warehouse Medium disponible
- Para el modulo de Snowpark: Python worksheet en Snowsight o Snowflake Notebook

## Arquitectura objetivo

```
                    ┌─────────────────────────────────────┐
                    │         SNOWFLAKE PLATFORM           │
                    │                                     │
  plataforma origen ──────>│  BRONZE ──> SILVER ──> GOLD         │
  (ETL actual)        │  (Streams)  (Dynamic   (Dynamic     │
                    │             Tables)    Tables)      │
                    │                                     │
  Power BI <────────│  ANALYTICS_WH (Small)               │
  Qlik     <────────│                                     │
                    │                                     │
  GitHub Actions ──>│  DEV / STAGING / PROD               │
  (CI/CD)           │  (Clone zero-copy)                  │
                    └─────────────────────────────────────┘
```

## Tiempo estimado

Ejecutar toda la POC toma **25-40 minutos**. Cada modulo es independiente despues del setup y datos sinteticos.
