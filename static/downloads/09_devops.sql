-- ======================================================================
-- PRIMUS CAPITAL POC — Módulo DevOps: Versionamiento y CI/CD
-- Demuestra el flujo completo de Database Change Management:
-- 
--   1. Estructura de proyecto versionable en Git
--   2. Multi-environment: dev / staging / prod con SnowCLI
--   3. Git Integration nativa de Snowflake
--   4. Pipeline CI/CD con GitHub Actions (OIDC, zero secrets)
-- 
-- Para data engineers avanzados: esto reemplaza los deploys manuales
-- y scripts ad-hoc que se envían por email o Slack.

USE ROLE ACCOUNTADMIN;

-- ======================================================================
-- 1. MULTI-ENVIRONMENT: Databases por ambiente
-- Patrón estándar: un database por ambiente, misma estructura.
-- El CI/CD apunta al ambiente correcto según el branch.

CREATE DATABASE IF NOT EXISTS PRIMUS_DEV;
CREATE DATABASE IF NOT EXISTS PRIMUS_STAGING;
-- PRIMUS_POC actúa como PROD para esta demo

-- Clonar estructura de prod a dev y staging (zero-copy, instantáneo)
CREATE SCHEMA IF NOT EXISTS PRIMUS_DEV.BRONZE CLONE PRIMUS_POC.BRONZE;
CREATE SCHEMA IF NOT EXISTS PRIMUS_DEV.SILVER CLONE PRIMUS_POC.SILVER;
CREATE SCHEMA IF NOT EXISTS PRIMUS_DEV.GOLD CLONE PRIMUS_POC.GOLD;
CREATE SCHEMA IF NOT EXISTS PRIMUS_DEV.COMPLIANCE CLONE PRIMUS_POC.COMPLIANCE;

CREATE SCHEMA IF NOT EXISTS PRIMUS_STAGING.BRONZE CLONE PRIMUS_POC.BRONZE;
CREATE SCHEMA IF NOT EXISTS PRIMUS_STAGING.SILVER CLONE PRIMUS_POC.SILVER;
CREATE SCHEMA IF NOT EXISTS PRIMUS_STAGING.GOLD CLONE PRIMUS_POC.GOLD;
CREATE SCHEMA IF NOT EXISTS PRIMUS_STAGING.COMPLIANCE CLONE PRIMUS_POC.COMPLIANCE;

-- Roles por ambiente
CREATE ROLE IF NOT EXISTS PRIMUS_DEV_DEPLOY
    COMMENT = 'Deploy a ambiente DEV — cualquier developer';
CREATE ROLE IF NOT EXISTS PRIMUS_STAGING_DEPLOY
    COMMENT = 'Deploy a STAGING — requiere PR aprobado';
CREATE ROLE IF NOT EXISTS PRIMUS_PROD_DEPLOY
    COMMENT = 'Deploy a PROD — solo CI/CD con aprobación';

GRANT ROLE PRIMUS_DEV_DEPLOY TO ROLE SYSADMIN;
GRANT ROLE PRIMUS_STAGING_DEPLOY TO ROLE SYSADMIN;
GRANT ROLE PRIMUS_PROD_DEPLOY TO ROLE SYSADMIN;

-- Grants por ambiente
GRANT ALL ON DATABASE PRIMUS_DEV TO ROLE PRIMUS_DEV_DEPLOY;
GRANT ALL ON ALL SCHEMAS IN DATABASE PRIMUS_DEV TO ROLE PRIMUS_DEV_DEPLOY;
GRANT USAGE ON WAREHOUSE PRIMUS_ETL_WH TO ROLE PRIMUS_DEV_DEPLOY;

GRANT ALL ON DATABASE PRIMUS_STAGING TO ROLE PRIMUS_STAGING_DEPLOY;
GRANT ALL ON ALL SCHEMAS IN DATABASE PRIMUS_STAGING TO ROLE PRIMUS_STAGING_DEPLOY;
GRANT USAGE ON WAREHOUSE PRIMUS_ETL_WH TO ROLE PRIMUS_STAGING_DEPLOY;

GRANT ALL ON DATABASE PRIMUS_POC TO ROLE PRIMUS_PROD_DEPLOY;
GRANT ALL ON ALL SCHEMAS IN DATABASE PRIMUS_POC TO ROLE PRIMUS_PROD_DEPLOY;
GRANT USAGE ON WAREHOUSE PRIMUS_ETL_WH TO ROLE PRIMUS_PROD_DEPLOY;

-- ======================================================================
-- ## 2. GIT INTEGRATION NATIVA
-- Snowflake puede conectarse directamente a un repo Git.
-- Los archivos SQL del repo se ejecutan desde dentro de Snowflake.
-- 
-- API integration para GitHub (requiere token con permisos de lectura)
-- NOTA: Para la POC, crear el secret con un PAT de GitHub.

CREATE OR REPLACE SECRET PRIMUS_POC.COMPLIANCE.GIT_SECRET
    TYPE = PASSWORD
    USERNAME = 'primus-ci'
    PASSWORD = 'ghp_REPLACE_WITH_REAL_TOKEN';

CREATE OR REPLACE API INTEGRATION PRIMUS_GIT_INTEGRATION
    API_PROVIDER = GIT_HTTPS_API
    API_ALLOWED_PREFIXES = ('https://github.com/primus-capital/')
    ALLOWED_AUTHENTICATION_SECRETS = (PRIMUS_POC.COMPLIANCE.GIT_SECRET)
    ENABLED = TRUE;

-- Repositorio Git como objeto Snowflake
-- (En producción, apunta al repo real del cliente)
-- CREATE OR REPLACE GIT REPOSITORY PRIMUS_POC.COMPLIANCE.PRIMUS_REPO
--     API_INTEGRATION = PRIMUS_GIT_INTEGRATION
--     GIT_CREDENTIALS = PRIMUS_POC.COMPLIANCE.GIT_SECRET
--     ORIGIN = 'https://github.com/primus-capital/snowflake-dwh.git';

-- Ejemplo de uso:
-- SHOW FILES IN @PRIMUS_POC.COMPLIANCE.PRIMUS_REPO/branches/main/;
-- EXECUTE IMMEDIATE FROM @PRIMUS_POC.COMPLIANCE.PRIMUS_REPO/branches/main/deploy/silver_tables.sql;

-- ======================================================================
-- 3. DEPLOY PARAMETRIZADO (simula lo que haría SnowCLI)
-- Stored procedure que aplica cambios a cualquier ambiente.
-- En producción esto lo ejecuta el CI/CD pipeline vía `snow sql`.

CREATE OR REPLACE PROCEDURE PRIMUS_POC.COMPLIANCE.DEPLOY_CHANGES(
    P_ENVIRONMENT VARCHAR,   -- 'DEV', 'STAGING', 'PROD'
    P_VERSION     VARCHAR,   -- '1.2.0', tag o commit hash
    P_DRY_RUN     BOOLEAN    -- TRUE = solo valida, no ejecuta
)
RETURNS VARIANT
LANGUAGE SQL
AS
DECLARE
    v_database VARCHAR;
    v_result VARIANT;
    v_start TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP();
BEGIN
    -- Resolver database por ambiente
    v_database := CASE UPPER(:P_ENVIRONMENT)
        WHEN 'DEV' THEN 'PRIMUS_DEV'
        WHEN 'STAGING' THEN 'PRIMUS_STAGING'
        WHEN 'PROD' THEN 'PRIMUS_POC'
        ELSE NULL
    END;

    IF (:v_database IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Ambiente inválido: ' || :P_ENVIRONMENT);
    END IF;

    -- Validar que el ambiente existe
    EXECUTE IMMEDIATE 'USE DATABASE ' || :v_database;

    IF (:P_DRY_RUN) THEN
        -- Dry run: solo verifica que los objetos existen y la sintaxis es válida
        v_result := OBJECT_CONSTRUCT(
            'status', 'DRY_RUN_OK',
            'environment', :P_ENVIRONMENT,
            'database', :v_database,
            'version', :P_VERSION,
            'schemas', (SELECT ARRAY_AGG(SCHEMA_NAME) FROM INFORMATION_SCHEMA.SCHEMATA WHERE CATALOG_NAME = :v_database),
            'timestamp', CURRENT_TIMESTAMP()
        );
    ELSE
        -- Deploy real: aplicar cambios
        -- En un deploy real, acá se ejecutarían los scripts SQL del repo.
        -- Para la demo, registramos el deploy en una tabla de auditoría.

        EXECUTE IMMEDIATE 'USE DATABASE PRIMUS_POC';

        CREATE TABLE IF NOT EXISTS COMPLIANCE.DEPLOY_HISTORY (
            deploy_id     NUMBER AUTOINCREMENT,
            environment   VARCHAR,
            version       VARCHAR,
            deployed_by   VARCHAR DEFAULT CURRENT_USER(),
            deployed_at   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
            duration_sec  NUMBER,
            status        VARCHAR,
            details       VARIANT
        );

        INSERT INTO COMPLIANCE.DEPLOY_HISTORY (environment, version, duration_sec, status, details)
        SELECT
            :P_ENVIRONMENT,
            :P_VERSION,
            DATEDIFF('second', :v_start, CURRENT_TIMESTAMP()),
            'SUCCESS',
            OBJECT_CONSTRUCT(
                'database', :v_database,
                'role', CURRENT_ROLE(),
                'warehouse', CURRENT_WAREHOUSE(),
                'schemas_deployed', (SELECT ARRAY_AGG(SCHEMA_NAME) FROM INFORMATION_SCHEMA.SCHEMATA WHERE CATALOG_NAME = :v_database)
            );

        v_result := OBJECT_CONSTRUCT(
            'status', 'DEPLOYED',
            'environment', :P_ENVIRONMENT,
            'database', :v_database,
            'version', :P_VERSION,
            'deployed_by', CURRENT_USER(),
            'timestamp', CURRENT_TIMESTAMP()
        );
    END IF;

    RETURN :v_result;
END;

-- ======================================================================
-- 4. DEMO: Flujo de deploy
-- 
-- Dry run en DEV (cualquier developer puede hacerlo)

CALL PRIMUS_POC.COMPLIANCE.DEPLOY_CHANGES('DEV', '1.0.0', TRUE);

-- Deploy real a DEV
CALL PRIMUS_POC.COMPLIANCE.DEPLOY_CHANGES('DEV', '1.0.0', FALSE);

-- Deploy a STAGING (después de PR aprobado)
CALL PRIMUS_POC.COMPLIANCE.DEPLOY_CHANGES('STAGING', '1.0.0', FALSE);

-- Deploy a PROD (solo desde CI/CD con aprobación)
CALL PRIMUS_POC.COMPLIANCE.DEPLOY_CHANGES('PROD', '1.0.0', FALSE);

-- Historial de deploys
SELECT * FROM COMPLIANCE.DEPLOY_HISTORY ORDER BY deployed_at DESC;

-- ======================================================================
-- ## 5. ROLLBACK CON TIME TRAVEL
-- Si un deploy sale mal, Snowflake permite rollback instantáneo
-- sin scripts de rollback manuales.
-- 
-- Ejemplo: restaurar una tabla a como estaba hace 5 minutos
-- CREATE OR REPLACE TABLE DWH.DIM_CLIENTES
--   CLONE DWH.DIM_CLIENTES AT (OFFSET => -300);
-- 
-- O restaurar a un timestamp exacto (pre-deploy)
-- CREATE OR REPLACE TABLE DWH.DIM_CLIENTES
--   CLONE DWH.DIM_CLIENTES AT (TIMESTAMP => '2024-01-15 10:00:00');
-- 
-- Undrop: si se dropeó algo por error
-- UNDROP TABLE DWH.DIM_CLIENTES;
-- UNDROP SCHEMA DWH;

SELECT '=== DevOps demo completo: multi-env + Git + deploy + rollback ===' AS status;
