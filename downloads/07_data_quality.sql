-- ======================================================================
-- PRIMUS CAPITAL POC — Módulo 5: Data Quality + Governance
-- Capacidades que SQL Server no tiene nativamente.
-- DMFs, clasificación automática de PII, tags, monitoreo.

USE DATABASE PRIMUS_POC;
USE SCHEMA DWH;
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE PRIMUS_ETL_WH;

-- ======================================================================
-- 1. DATA METRIC FUNCTIONS (DMFs)
-- 
-- DMF custom: validar formato RUT chileno (XX.XXX.XXX-X)

CREATE OR REPLACE DATA METRIC FUNCTION DWH.DMF_INVALID_RUT_COUNT(
    ARG_T TABLE(ARG_C VARCHAR)
)
RETURNS NUMBER
AS
$$
    SELECT COUNT(*)
    FROM ARG_T
    WHERE ARG_C IS NOT NULL
      AND NOT RLIKE(ARG_C, '^[0-9]{2}\\.[0-9]{3}\\.[0-9]{3}-[0-9K]$')
      AND LENGTH(ARG_C) < 20  -- excluir hasheados (pseudonimizados)
$$;

-- Asociar DMFs built-in a las tablas principales
-- Completitud: contar NULLs
ALTER TABLE DWH.DIM_CLIENTES
    SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

ALTER TABLE DWH.DIM_CLIENTES ADD DATA METRIC FUNCTION
    SNOWFLAKE.CORE.NULL_COUNT ON (email);

ALTER TABLE DWH.DIM_CLIENTES ADD DATA METRIC FUNCTION
    SNOWFLAKE.CORE.NULL_COUNT ON (rut);

ALTER TABLE DWH.DIM_CLIENTES ADD DATA METRIC FUNCTION
    SNOWFLAKE.CORE.NULL_COUNT ON (telefono);

-- Unicidad: contar duplicados en primary key
ALTER TABLE DWH.DIM_CLIENTES ADD DATA METRIC FUNCTION
    SNOWFLAKE.CORE.DUPLICATE_COUNT ON (client_id);

ALTER TABLE DWH.FACT_TRANSACCIONES
    SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

ALTER TABLE DWH.FACT_TRANSACCIONES ADD DATA METRIC FUNCTION
    SNOWFLAKE.CORE.DUPLICATE_COUNT ON (txn_id);

-- Frescura
ALTER TABLE DWH.FACT_TRANSACCIONES ADD DATA METRIC FUNCTION
    SNOWFLAKE.CORE.FRESHNESS ON (etl_timestamp);

-- DMF custom: RUTs inválidos
ALTER TABLE DWH.DIM_CLIENTES ADD DATA METRIC FUNCTION
    DWH.DMF_INVALID_RUT_COUNT ON (rut);

-- Forzar ejecución de métricas (para la demo)
ALTER TABLE DWH.DIM_CLIENTES SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

-- Ver resultados de las métricas
SELECT
    METRIC_DATABASE,
    METRIC_SCHEMA,
    METRIC_NAME,
    TABLE_NAME,
    COLUMN_NAME,
    VALUE,
    MEASUREMENT_TIME
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
WHERE TABLE_DATABASE = 'PRIMUS_POC'
ORDER BY MEASUREMENT_TIME DESC
LIMIT 20;

-- ======================================================================
-- ## 2. TAGS DE CLASIFICACIÓN
-- 
-- Crear tags

CREATE OR REPLACE TAG COMPLIANCE.DATA_CLASSIFICATION
    ALLOWED_VALUES 'PII', 'FINANCIAL', 'CONFIDENTIAL', 'PUBLIC';

CREATE OR REPLACE TAG COMPLIANCE.DATA_OWNER;

CREATE OR REPLACE TAG COMPLIANCE.RETENTION_DAYS;

-- Aplicar tags a tablas
ALTER TABLE DWH.DIM_CLIENTES SET TAG
    COMPLIANCE.DATA_CLASSIFICATION = 'PII',
    COMPLIANCE.DATA_OWNER = 'compliance-team';

ALTER TABLE DWH.FACT_TRANSACCIONES SET TAG
    COMPLIANCE.DATA_CLASSIFICATION = 'FINANCIAL',
    COMPLIANCE.DATA_OWNER = 'finance-team';

-- Aplicar tags a columnas específicas
ALTER TABLE DWH.DIM_CLIENTES MODIFY COLUMN rut SET TAG
    COMPLIANCE.DATA_CLASSIFICATION = 'PII';
ALTER TABLE DWH.DIM_CLIENTES MODIFY COLUMN email SET TAG
    COMPLIANCE.DATA_CLASSIFICATION = 'PII';
ALTER TABLE DWH.DIM_CLIENTES MODIFY COLUMN telefono SET TAG
    COMPLIANCE.DATA_CLASSIFICATION = 'PII';
ALTER TABLE DWH.DIM_CLIENTES MODIFY COLUMN nombre SET TAG
    COMPLIANCE.DATA_CLASSIFICATION = 'PII';
ALTER TABLE DWH.DIM_CLIENTES MODIFY COLUMN direccion SET TAG
    COMPLIANCE.DATA_CLASSIFICATION = 'PII';

ALTER TABLE DWH.FACT_TRANSACCIONES MODIFY COLUMN monto SET TAG
    COMPLIANCE.DATA_CLASSIFICATION = 'FINANCIAL';

-- ======================================================================
-- ## 3. CLASIFICACIÓN AUTOMÁTICA DE PII
-- 
-- Snowflake detecta automáticamente qué columnas contienen PII

CALL SYSTEM$CLASSIFY('PRIMUS_POC.DWH.DIM_CLIENTES', {'auto_tag': true});

-- Ver resultados de la clasificación
SELECT *
FROM TABLE(
    INFORMATION_SCHEMA.TAG_REFERENCES('PRIMUS_POC.DWH.DIM_CLIENTES', 'TABLE')
)
ORDER BY COLUMN_NAME;

-- ======================================================================
-- 4. MONITOREO CON ACCOUNT_USAGE
-- 
-- Quién consulta las tablas con PII (últimas 24 horas)

SELECT
    user_name,
    role_name,
    query_type,
    COUNT(*) AS num_queries,
    SUM(bytes_scanned) / 1024 / 1024 AS mb_scanned,
    MIN(start_time) AS primera_query,
    MAX(start_time) AS ultima_query
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -1, CURRENT_TIMESTAMP())
  AND query_text ILIKE '%DIM_CLIENTES%'
  AND query_type = 'SELECT'
GROUP BY user_name, role_name, query_type
ORDER BY num_queries DESC;

-- Intentos de login (seguridad)
SELECT
    user_name,
    client_ip,
    reported_client_type,
    is_success,
    error_code,
    error_message,
    event_timestamp
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE event_timestamp >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY event_timestamp DESC
LIMIT 50;

-- Consumo de créditos por warehouse (para validar el sizing del Birdbox)
SELECT
    warehouse_name,
    ROUND(SUM(credits_used), 2) AS total_credits,
    COUNT(DISTINCT DATE_TRUNC('day', start_time)) AS dias_activo,
    ROUND(SUM(credits_used) / COUNT(DISTINCT DATE_TRUNC('day', start_time)), 2) AS credits_por_dia
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE warehouse_name LIKE 'PRIMUS%'
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY total_credits DESC;

-- ======================================================================
-- 5. DASHBOARD DE GOVERNANCE (vista consolidada)

CREATE OR REPLACE VIEW COMPLIANCE.V_GOVERNANCE_DASHBOARD AS

-- Resumen de data quality
SELECT
    'Data Quality' AS categoria,
    TABLE_NAME AS objeto,
    METRIC_NAME AS metrica,
    VALUE::VARCHAR AS valor,
    MEASUREMENT_TIME AS timestamp
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
WHERE TABLE_DATABASE = 'PRIMUS_POC'

UNION ALL

-- Solicitudes de eliminación
SELECT
    'Compliance' AS categoria,
    'DELETION_REQUESTS' AS objeto,
    status AS metrica,
    COUNT(*)::VARCHAR AS valor,
    MAX(requested_at) AS timestamp
FROM COMPLIANCE.DELETION_REQUESTS
GROUP BY status

UNION ALL

-- Clientes pseudonimizados
SELECT
    'Compliance' AS categoria,
    'DIM_CLIENTES' AS objeto,
    'Pseudonimizados' AS metrica,
    COUNT(*)::VARCHAR AS valor,
    MAX(pseudonymized_at) AS timestamp
FROM DWH.DIM_CLIENTES
WHERE pseudonymized = TRUE;


SELECT '=== Módulo 5 completo: DMFs + Tags + Clasificación + Monitoreo ===' AS status;
