---
sidebar_position: 10
---

# DevOps y CI/CD

<a href="/mssqltosnowflake-migration-hol/downloads/09_devops.sql" download="09_devops.sql" class="button button--primary button--sm" style={{marginBottom: "1.5rem", display: "inline-block"}}>Descargar 09_devops.sql</a>


Multi-environment con clone zero-copy, Git integration nativa, deploy parametrizado, pipeline CI/CD con GitHub Actions y OIDC.

## Multi-environment

Tres ambientes: DEV, STAGING, PROD. Los ambientes se crean con `CLONE` — zero-copy, instantaneo, sin duplicar storage:

```sql
CREATE DATABASE IF NOT EXISTS SNOWFLAKE_DEV;
CREATE DATABASE IF NOT EXISTS SNOWFLAKE_STAGING;

-- Clonar estructura de prod a dev (< 1 segundo, 0 GB adicionales)
CREATE SCHEMA IF NOT EXISTS SNOWFLAKE_DEV.BRONZE
    CLONE SNOWFLAKE_POC.BRONZE;
CREATE SCHEMA IF NOT EXISTS SNOWFLAKE_DEV.SILVER
    CLONE SNOWFLAKE_POC.SILVER;
CREATE SCHEMA IF NOT EXISTS SNOWFLAKE_DEV.GOLD
    CLONE SNOWFLAKE_POC.GOLD;
```

:::tip Clone zero-copy
Clonar 290 GB de produccion a dev toma menos de 1 segundo y no cuesta storage adicional. En plataformas tradicionales, restaurar un backup de 290 GB para crear un ambiente de QA toma horas y duplica el storage.
:::

### Roles por ambiente

```sql
CREATE ROLE IF NOT EXISTS DEV_DEPLOY;     -- cualquier developer
CREATE ROLE IF NOT EXISTS STAGING_DEPLOY;  -- requiere PR aprobado
CREATE ROLE IF NOT EXISTS PROD_DEPLOY;     -- solo CI/CD con aprobacion
```

## Git Integration

Snowflake se conecta directamente a un repositorio Git:

```sql
CREATE OR REPLACE GIT REPOSITORY SNOWFLAKE_POC.COMPLIANCE.SNOWFLAKE_REPO
    API_INTEGRATION = GIT_INTEGRATION
    GIT_CREDENTIALS = SNOWFLAKE_POC.COMPLIANCE.GIT_SECRET
    ORIGIN = 'https://github.com/snowflake-dwh/snowflake-dwh.git';

-- Listar archivos del repo desde Snowflake
SHOW FILES IN @SNOWFLAKE_REPO/branches/main/;

-- Ejecutar un script directamente desde el repo
EXECUTE IMMEDIATE FROM @SNOWFLAKE_REPO/branches/main/deploy/silver_tables.sql;
```

## Deploy parametrizado

Stored procedure que aplica cambios a cualquier ambiente con dry-run y auditoria:

```sql
CREATE OR REPLACE PROCEDURE COMPLIANCE.DEPLOY_CHANGES(
    P_ENVIRONMENT VARCHAR,  -- 'DEV', 'STAGING', 'PROD'
    P_VERSION     VARCHAR,  -- '1.2.0' o commit hash
    P_DRY_RUN     BOOLEAN   -- TRUE = solo valida
)
RETURNS VARIANT
LANGUAGE SQL
AS
DECLARE
    v_database VARCHAR;
BEGIN
    v_database := CASE UPPER(:P_ENVIRONMENT)
        WHEN 'DEV' THEN 'SNOWFLAKE_DEV'
        WHEN 'STAGING' THEN 'SNOWFLAKE_STAGING'
        WHEN 'PROD' THEN 'SNOWFLAKE_POC'
    END;
    -- ... validar, ejecutar, registrar en DEPLOY_HISTORY
END;
```

```sql
-- Dry run (valida sin ejecutar)
CALL DEPLOY_CHANGES('DEV', '1.0.0', TRUE);

-- Deploy real
CALL DEPLOY_CHANGES('DEV', '1.0.0', FALSE);
CALL DEPLOY_CHANGES('STAGING', '1.0.0', FALSE);
CALL DEPLOY_CHANGES('PROD', '1.0.0', FALSE);

-- Historial
SELECT * FROM COMPLIANCE.DEPLOY_HISTORY ORDER BY deployed_at DESC;
```

## Pipeline CI/CD (GitHub Actions)

```yaml
name: Snowflake Deploy Pipeline

on:
  push:
    branches: [develop, main]
    paths: ['deploy/**']
  pull_request:
    branches: [main]

permissions:
  id-token: write  # OIDC

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: Snowflake-Labs/snowflake-cli-action@v1
      - run: |
          for f in deploy/*.sql; do
            snow sql -f "$f" -x --dry-run
          done

  deploy-dev:
    needs: validate
    if: github.ref == 'refs/heads/develop'
    environment: development
    steps:
      - run: snow sql -f deploy/*.sql -x

  deploy-staging:
    needs: validate
    if: github.ref == 'refs/heads/main'
    environment: staging
    steps:
      - run: snow sql -f deploy/*.sql -x

  deploy-prod:
    needs: deploy-staging
    environment:
      name: production  # requiere aprobacion manual
    steps:
      - run: snow sql -f deploy/*.sql -x
```

### Flujo

```
develop branch → auto-deploy a DEV
       │
       ▼
PR a main → validacion SQL + tests
       │
       ▼
merge a main → auto-deploy a STAGING
       │
       ▼
aprobacion manual → deploy a PROD
```

### OIDC: zero secrets

La autenticacion usa Workload Identity Federation. GitHub genera un token JWT efimero que Snowflake valida. No hay passwords ni API keys almacenadas en el pipeline.

## Rollback con Time Travel

Si un deploy sale mal, restauracion instantanea sin scripts de rollback:

```sql
-- Restaurar tabla a hace 5 minutos
CREATE OR REPLACE TABLE DWH.DIM_CLIENTES
    CLONE DWH.DIM_CLIENTES AT (OFFSET => -300);

-- Restaurar a timestamp exacto (pre-deploy)
CREATE OR REPLACE TABLE DWH.DIM_CLIENTES
    CLONE DWH.DIM_CLIENTES AT (TIMESTAMP => '2024-01-15 10:00:00');

-- Si dropearon algo por error
UNDROP TABLE DWH.DIM_CLIENTES;
UNDROP SCHEMA DWH;
```

Sin backups, sin downtime, sin scripts de rollback manuales.
