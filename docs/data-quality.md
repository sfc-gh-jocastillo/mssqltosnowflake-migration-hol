---
sidebar_position: 9
---

# Data Quality y Governance

<a href="/mssqltosnowflake-migration-hol/downloads/07_data_quality.sql" download="07_data_quality.sql" class="button button--primary button--sm" style={{marginBottom: "1.5rem", display: "inline-block"}}>Descargar 07_data_quality.sql</a>


Capacidades nativas de Snowflake para governance: Data Metric Functions, clasificacion automatica de PII, tags, y monitoreo con ACCOUNT_USAGE.

## Data Metric Functions (DMFs)

Checks de calidad que corren automaticamente cuando los datos cambian.

### Built-in

```sql
-- Contar NULLs en campos obligatorios
ALTER TABLE DWH.DIM_CLIENTES ADD DATA METRIC FUNCTION
    SNOWFLAKE.CORE.NULL_COUNT ON (email);

-- Contar duplicados en primary key
ALTER TABLE DWH.FACT_TRANSACCIONES ADD DATA METRIC FUNCTION
    SNOWFLAKE.CORE.DUPLICATE_COUNT ON (txn_id);

-- Frescura: cuanto hace que se cargo
ALTER TABLE DWH.FACT_TRANSACCIONES ADD DATA METRIC FUNCTION
    SNOWFLAKE.CORE.FRESHNESS ON (etl_timestamp);

-- Ejecutar cuando cambian los datos
ALTER TABLE DWH.DIM_CLIENTES
    SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';
```

### DMF custom: validar documento de identidad

```sql
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
      AND LENGTH(ARG_C) < 20
$$;

ALTER TABLE DWH.DIM_CLIENTES ADD DATA METRIC FUNCTION
    DWH.DMF_INVALID_RUT_COUNT ON (rut);
```

:::info TRIGGER_ON_CHANGES
El DMF corre cada vez que la tabla se modifica. No hay un job separado para data quality — esta embebido en la plataforma.
:::

## Clasificacion automatica de PII

`SYSTEM$CLASSIFY` escanea la tabla y detecta que columnas contienen PII sin configuracion manual:

```sql
CALL SYSTEM$CLASSIFY('SNOWFLAKE_POC.DWH.DIM_CLIENTES', {'auto_tag': true});
```

Resultado: identifica `rut` como identificador nacional, `email` como correo, `telefono` como numero de telefono. Aplica tags automaticamente.

En plataformas tradicionales se necesitan herramientas de governance externas para esto.

## Tags de clasificacion

```sql
CREATE OR REPLACE TAG COMPLIANCE.DATA_CLASSIFICATION
    ALLOWED_VALUES 'PII', 'FINANCIAL', 'CONFIDENTIAL', 'PUBLIC';

-- Aplicar a tablas
ALTER TABLE DWH.DIM_CLIENTES SET TAG
    COMPLIANCE.DATA_CLASSIFICATION = 'PII';

ALTER TABLE DWH.FACT_TRANSACCIONES SET TAG
    COMPLIANCE.DATA_CLASSIFICATION = 'FINANCIAL';

-- Aplicar a columnas especificas
ALTER TABLE DWH.DIM_CLIENTES MODIFY COLUMN rut SET TAG
    COMPLIANCE.DATA_CLASSIFICATION = 'PII';
ALTER TABLE DWH.FACT_TRANSACCIONES MODIFY COLUMN monto SET TAG
    COMPLIANCE.DATA_CLASSIFICATION = 'FINANCIAL';
```

## Monitoreo con ACCOUNT_USAGE

```sql
-- Quien consulta tablas con PII
SELECT user_name, role_name, COUNT(*) AS queries
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_text ILIKE '%DIM_CLIENTES%'
  AND start_time >= DATEADD('day', -1, CURRENT_TIMESTAMP())
GROUP BY user_name, role_name;

-- Consumo de creditos por warehouse
SELECT warehouse_name,
       ROUND(SUM(credits_used), 2) AS total_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE warehouse_name LIKE 'SNOWFLAKE%'
GROUP BY warehouse_name;
```

Para compliance financiero, ACCESS_HISTORY es clave: pueden demostrar que solo ciertos roles acceden a datos sensibles.
