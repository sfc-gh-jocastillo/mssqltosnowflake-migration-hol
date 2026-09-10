---
sidebar_position: 4
---

# Pipeline Medallion

<a href="/mssqltosnowflake-migration-hol/downloads/02_pipeline_medallion.sql" download="02_pipeline_medallion.sql" class="button button--primary button--sm" style={{marginBottom: "1.5rem", display: "inline-block"}}>Descargar 02_pipeline_medallion.sql</a>


Arquitectura Bronze, Silver, Gold con Dynamic Tables. El grafo de dependencias se auto-resuelve — no hay orquestacion manual, no hay scheduler externo.

## Concepto

```
BRONZE (tablas)          SILVER (Dynamic Tables)       GOLD (Dynamic Tables)
┌──────────────┐        ┌───────────────────┐        ┌────────────────────┐
│ Transacciones│───────>│ FACT_TRANSACCIONES │───────>│ PERFIL_CLIENTE_360 │
│ (CHANGE_     │        │ (dedup, validate,  │        │ RESUMEN_MENSUAL    │
│  TRACKING)   │        │  quality flags)    │        │ QUALITY_ALERTS     │
│              │        └───────────────────┘        └────────────────────┘
│ + Streams    │               ▲                            ▲
│   (CDC)      │               │ TARGET_LAG='10m'           │ TARGET_LAG='30m'
└──────────────┘               │ auto-refresh               │ auto-refresh
```

## Bronze: Ingesta con CDC

Las tablas Bronze tienen `CHANGE_TRACKING = TRUE` para que Snowflake registre internamente que filas cambiaron. Es el equivalente a CDC pero sin middleware de CDC externo.

```sql
CREATE SCHEMA IF NOT EXISTS SNOWFLAKE_POC.BRONZE;

CREATE OR REPLACE TABLE BRONZE.TRANSACCIONES (
    txn_id          NUMBER,
    client_id       NUMBER,
    producto_id     NUMBER,
    sucursal_id     NUMBER,
    fecha           TIMESTAMP_NTZ,
    tipo            VARCHAR(50),
    monto           NUMBER(15,2),
    moneda          VARCHAR(3),
    estado          VARCHAR(20),
    referencia      VARCHAR(50),
    _loaded_at      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    _source_file    VARCHAR DEFAULT 'initial_load'
) CHANGE_TRACKING = TRUE;
```

Los **Streams** son punteros que marcan "hasta aca lei". La proxima vez que los consultes, te dan solo los cambios nuevos:

```sql
CREATE OR REPLACE STREAM BRONZE.STREAM_TRANSACCIONES
    ON TABLE BRONZE.TRANSACCIONES;
```

## Silver: Dynamic Tables con limpieza

Cada Dynamic Table de Silver tiene un `TARGET_LAG` que define la frescura maxima. Se refresca **sola** cuando Bronze cambia.

### DIM_CLIENTES (deduplicacion + enriquecimiento)

```sql
CREATE OR REPLACE DYNAMIC TABLE SILVER.DIM_CLIENTES
    TARGET_LAG = '10 minutes'
    WAREHOUSE = ETL_WH
AS
WITH deduped AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY client_id ORDER BY _loaded_at DESC
        ) AS _rn
    FROM BRONZE.CLIENTES
)
SELECT
    c.client_id,
    c.rut,
    INITCAP(TRIM(c.nombre)) AS nombre,
    INITCAP(TRIM(c.apellido)) AS apellido,
    LOWER(TRIM(c.email)) AS email,
    c.fecha_registro,
    c.segmento,
    DATEDIFF('day', c.fecha_registro, CURRENT_DATE()) AS dias_antiguedad,
    CASE
        WHEN DATEDIFF('year', c.fecha_registro, CURRENT_DATE()) >= 5
            THEN 'Veterano'
        WHEN DATEDIFF('year', c.fecha_registro, CURRENT_DATE()) >= 2
            THEN 'Establecido'
        ELSE 'Nuevo'
    END AS categoria_antiguedad
FROM deduped c
WHERE c._rn = 1;
```

### FACT_TRANSACCIONES (validacion + quality flags)

```sql
CREATE OR REPLACE DYNAMIC TABLE SILVER.FACT_TRANSACCIONES
    TARGET_LAG = '10 minutes'
    WAREHOUSE = ETL_WH
AS
SELECT
    t.txn_id, t.client_id, t.producto_id, t.sucursal_id,
    t.fecha,
    DATE_TRUNC('month', t.fecha)::DATE AS mes,
    t.tipo, t.monto, ABS(t.monto) AS monto_absoluto,
    t.estado,
    -- Quality gate por fila
    CASE
        WHEN t.monto IS NULL THEN 'MONTO_NULL'
        WHEN t.client_id IS NULL THEN 'CLIENT_NULL'
        WHEN t.fecha > CURRENT_TIMESTAMP() THEN 'FECHA_FUTURA'
        ELSE 'OK'
    END AS _quality_flag
FROM BRONZE.TRANSACCIONES t
WHERE t.estado IS NOT NULL;
```

:::info Quality gate embebido
El campo `_quality_flag` marca anomalias a nivel de fila. La capa Gold solo procesa filas con `_quality_flag = 'OK'`. Si empiezan a llegar datos corruptos, una Dynamic Table de alertas lo detecta automaticamente.
:::

## Gold: Agregaciones de negocio

Gold depende de Silver, que depende de Bronze. Snowflake resuelve el grafo completo.

### Perfil 360 de cliente

```sql
CREATE OR REPLACE DYNAMIC TABLE GOLD.PERFIL_CLIENTE_360
    TARGET_LAG = '30 minutes'
    WAREHOUSE = ETL_WH
AS
SELECT
    c.client_id,
    c.nombre_completo,
    c.segmento,
    COALESCE(t.total_txn, 0) AS total_transacciones,
    COALESCE(t.total_ingresos, 0) AS total_ingresos,
    COALESCE(s.saldo_total, 0) AS saldo_total,
    COALESCE(r.txn_90d, 0) AS transacciones_90d,
    CASE
        WHEN COALESCE(t.total_txn, 0) > 500
         AND COALESCE(s.saldo_total, 0) > 10000000
            THEN 'A - Premium'
        WHEN COALESCE(t.total_txn, 0) > 200
            THEN 'B - Alto'
        ELSE 'C - Medio'
    END AS categoria_valor
FROM SILVER.DIM_CLIENTES c
LEFT JOIN (...) t ON c.client_id = t.client_id
LEFT JOIN (...) s ON c.client_id = s.client_id
LEFT JOIN (...) r ON c.client_id = r.client_id;
```

### Quality Alerts (auto-detecta datos corruptos)

```sql
CREATE OR REPLACE DYNAMIC TABLE GOLD.QUALITY_ALERTS
    TARGET_LAG = '10 minutes'
    WAREHOUSE = ETL_WH
AS
SELECT 'FACT_TRANSACCIONES' AS tabla,
       _quality_flag, COUNT(*) AS registros
FROM SILVER.FACT_TRANSACCIONES
WHERE _quality_flag != 'OK'
GROUP BY _quality_flag;
```

## Observabilidad

```sql
-- Historial de refresh: latencia, duracion, estado
SELECT name, schema_name,
    target_lag_sec / 60 AS target_lag_min,
    refresh_status,
    last_completed_refresh_time
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY())
WHERE database_name = 'SNOWFLAKE_POC'
ORDER BY last_completed_refresh_time DESC;
```

## Demo CDC en vivo

Insertar datos nuevos en Bronze y ver como fluyen automaticamente a Silver y Gold:

```sql
-- Simular carga diaria
INSERT INTO BRONZE.TRANSACCIONES (...)
SELECT ... FROM BRONZE.TRANSACCIONES SAMPLE (100000 ROWS);

-- El stream detecta los cambios
SELECT SYSTEM$STREAM_HAS_DATA('BRONZE.STREAM_TRANSACCIONES');

-- Forzar refresh (en produccion se auto-refresca)
ALTER DYNAMIC TABLE SILVER.FACT_TRANSACCIONES REFRESH;

-- Verificar flujo completo
SELECT 'BRONZE' AS capa, COUNT(*) FROM BRONZE.TRANSACCIONES
UNION ALL SELECT 'SILVER', COUNT(*) FROM SILVER.FACT_TRANSACCIONES
UNION ALL SELECT 'GOLD', COUNT(*) FROM GOLD.PERFIL_CLIENTE_360;
```

:::tip Comparacion con ETL tradicional
Con herramientas ETL tradicionales necesitas: decenas de paquetes, jobs secuenciales, dependencias manuales, y logs en archivos planos. Con Dynamic Tables: defines el SQL, Snowflake resuelve dependencias, refresca automaticamente, y expone metricas via SQL.
:::
