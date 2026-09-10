-- ======================================================================
-- PRIMUS CAPITAL POC — Módulo 2: Pipeline Medallion (Bronze → Silver → Gold)
-- Arquitectura de producción para data engineers avanzados.
-- 
-- Bronze: Tablas raw con ingesta CDC vía Streams
-- Silver: Dynamic Tables con limpieza, dedup, y conformación
-- Gold: Dynamic Tables con agregaciones de negocio
-- 
-- El grafo de dependencias se auto-resuelve — no hay orquestación manual.

USE DATABASE PRIMUS_POC;
USE WAREHOUSE PRIMUS_ETL_WH;

-- ======================================================================
-- 0. SCHEMAS POR CAPA (reemplazan RAW/DWH genéricos)

CREATE SCHEMA IF NOT EXISTS PRIMUS_POC.BRONZE;
CREATE SCHEMA IF NOT EXISTS PRIMUS_POC.SILVER;
CREATE SCHEMA IF NOT EXISTS PRIMUS_POC.GOLD;

-- ======================================================================
-- 1. BRONZE LAYER — Ingesta CDC con Streams
-- Las tablas bronze son append-only staging tables con change tracking.
-- Representan la carga cruda desde SQL Server (SSIS hoy, Snowpipe mañana).
-- 
-- Tabla de landing con change tracking habilitado

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

CREATE OR REPLACE TABLE BRONZE.CLIENTES (
    client_id       NUMBER,
    rut             VARCHAR(12),
    nombre          VARCHAR(100),
    apellido        VARCHAR(100),
    email           VARCHAR(200),
    telefono        VARCHAR(20),
    direccion       VARCHAR(300),
    fecha_registro  DATE,
    segmento        VARCHAR(50),
    sucursal_id     NUMBER,
    _loaded_at      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    _source_file    VARCHAR DEFAULT 'initial_load'
) CHANGE_TRACKING = TRUE;

CREATE OR REPLACE TABLE BRONZE.MOVIMIENTOS (
    movimiento_id   NUMBER,
    client_id       NUMBER,
    producto_id     NUMBER,
    sucursal_id     NUMBER,
    fecha           DATE,
    tipo_movimiento VARCHAR(50),
    monto           NUMBER(15,2),
    saldo_posterior NUMBER(15,2),
    referencia      VARCHAR(50),
    _loaded_at      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    _source_file    VARCHAR DEFAULT 'initial_load'
) CHANGE_TRACKING = TRUE;

CREATE OR REPLACE TABLE BRONZE.SALDOS (
    saldo_id        NUMBER,
    client_id       NUMBER,
    producto_id     NUMBER,
    fecha_corte     DATE,
    saldo_contable  NUMBER(15,2),
    saldo_disponible NUMBER(15,2),
    saldo_promedio_mes NUMBER(15,2),
    estado_cuenta   VARCHAR(20),
    _loaded_at      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    _source_file    VARCHAR DEFAULT 'initial_load'
) CHANGE_TRACKING = TRUE;

-- Carga inicial desde las tablas raw generadas en módulo 01
INSERT INTO BRONZE.TRANSACCIONES (txn_id, client_id, producto_id, sucursal_id, fecha, tipo, monto, moneda, estado, referencia)
SELECT txn_id, client_id, producto_id, sucursal_id, fecha, tipo, monto, moneda, estado, referencia
FROM RAW.TRANSACCIONES;

INSERT INTO BRONZE.CLIENTES (client_id, rut, nombre, apellido, email, telefono, direccion, fecha_registro, segmento, sucursal_id)
SELECT client_id, rut, nombre, apellido, email, telefono, direccion, fecha_registro, segmento, sucursal_id
FROM RAW.CLIENTES;

INSERT INTO BRONZE.MOVIMIENTOS (movimiento_id, client_id, producto_id, sucursal_id, fecha, tipo_movimiento, monto, saldo_posterior, referencia)
SELECT movimiento_id, client_id, producto_id, sucursal_id, fecha, tipo_movimiento, monto, saldo_posterior, referencia
FROM RAW.MOVIMIENTOS;

INSERT INTO BRONZE.SALDOS (saldo_id, client_id, producto_id, fecha_corte, saldo_contable, saldo_disponible, saldo_promedio_mes, estado_cuenta)
SELECT saldo_id, client_id, producto_id, fecha_corte, saldo_contable, saldo_disponible, saldo_promedio_mes, estado_cuenta
FROM RAW.SALDOS;

-- Streams para capturar cambios (CDC)
CREATE OR REPLACE STREAM BRONZE.STREAM_TRANSACCIONES ON TABLE BRONZE.TRANSACCIONES;
CREATE OR REPLACE STREAM BRONZE.STREAM_CLIENTES ON TABLE BRONZE.CLIENTES;
CREATE OR REPLACE STREAM BRONZE.STREAM_MOVIMIENTOS ON TABLE BRONZE.MOVIMIENTOS;
CREATE OR REPLACE STREAM BRONZE.STREAM_SALDOS ON TABLE BRONZE.SALDOS;

-- ======================================================================
-- 2. SILVER LAYER — Dynamic Tables (limpieza + conformación)
-- Las DTs se refrescan automáticamente cuando bronze cambia.
-- No hay SPs, no hay Tasks de orquestación, no hay schedule manual.
-- 
-- Silver: Clientes deduplicados y enriquecidos

CREATE OR REPLACE DYNAMIC TABLE SILVER.DIM_CLIENTES
    TARGET_LAG = '10 minutes'
    WAREHOUSE = PRIMUS_ETL_WH
AS
WITH deduped AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY client_id
            ORDER BY _loaded_at DESC
        ) AS _rn
    FROM BRONZE.CLIENTES
)
SELECT
    c.client_id,
    c.rut,
    INITCAP(TRIM(c.nombre)) AS nombre,
    INITCAP(TRIM(c.apellido)) AS apellido,
    INITCAP(TRIM(c.nombre)) || ' ' || INITCAP(TRIM(c.apellido)) AS nombre_completo,
    LOWER(TRIM(c.email)) AS email,
    c.telefono,
    c.direccion,
    c.fecha_registro,
    c.segmento,
    c.sucursal_id,
    s.comuna AS sucursal_comuna,
    s.region AS sucursal_region,
    -- Derived: antigüedad
    DATEDIFF('day', c.fecha_registro, CURRENT_DATE()) AS dias_antiguedad,
    CASE
        WHEN DATEDIFF('year', c.fecha_registro, CURRENT_DATE()) >= 5 THEN 'Veterano'
        WHEN DATEDIFF('year', c.fecha_registro, CURRENT_DATE()) >= 2 THEN 'Establecido'
        WHEN DATEDIFF('year', c.fecha_registro, CURRENT_DATE()) >= 1 THEN 'Regular'
        ELSE 'Nuevo'
    END AS categoria_antiguedad,
    FALSE AS pseudonymized,
    NULL::TIMESTAMP_LTZ AS pseudonymized_at,
    c._loaded_at,
    CURRENT_TIMESTAMP() AS _silver_processed_at
FROM deduped c
LEFT JOIN RAW.SUCURSALES s ON c.sucursal_id = s.sucursal_id
WHERE c._rn = 1;

-- Silver: Transacciones validadas y enriquecidas
CREATE OR REPLACE DYNAMIC TABLE SILVER.FACT_TRANSACCIONES
    TARGET_LAG = '10 minutes'
    WAREHOUSE = PRIMUS_ETL_WH
AS
SELECT
    t.txn_id,
    t.client_id,
    t.producto_id,
    t.sucursal_id,
    t.fecha,
    t.fecha::DATE AS fecha_date,
    DATE_TRUNC('month', t.fecha)::DATE AS mes,
    DATE_TRUNC('quarter', t.fecha)::DATE AS trimestre,
    YEAR(t.fecha) AS anio,
    DAYOFWEEK(t.fecha) AS dia_semana,
    CASE WHEN DAYOFWEEK(t.fecha) IN (0, 6) THEN TRUE ELSE FALSE END AS es_fin_semana,
    t.tipo,
    t.monto,
    ABS(t.monto) AS monto_absoluto,
    t.moneda,
    t.estado,
    -- Validaciones de calidad a nivel de fila
    CASE
        WHEN t.monto IS NULL THEN 'MONTO_NULL'
        WHEN t.client_id IS NULL THEN 'CLIENT_NULL'
        WHEN t.fecha > CURRENT_TIMESTAMP() THEN 'FECHA_FUTURA'
        ELSE 'OK'
    END AS _quality_flag,
    t.referencia,
    t._loaded_at,
    CURRENT_TIMESTAMP() AS _silver_processed_at
FROM BRONZE.TRANSACCIONES t
WHERE t.estado IS NOT NULL;  -- Filtrar registros corruptos

-- Silver: Movimientos
CREATE OR REPLACE DYNAMIC TABLE SILVER.FACT_MOVIMIENTOS
    TARGET_LAG = '10 minutes'
    WAREHOUSE = PRIMUS_ETL_WH
AS
SELECT
    m.movimiento_id,
    m.client_id,
    m.producto_id,
    m.sucursal_id,
    m.fecha,
    DATE_TRUNC('month', m.fecha)::DATE AS mes,
    m.tipo_movimiento,
    m.monto,
    m.saldo_posterior,
    -- Detectar anomalías
    CASE
        WHEN m.saldo_posterior < 0 AND m.tipo_movimiento NOT IN ('Cargo', 'Comisión') THEN 'SALDO_NEGATIVO_ANOMALO'
        WHEN m.monto > 100000000 THEN 'MONTO_ANOMALO'
        ELSE 'OK'
    END AS _quality_flag,
    m.referencia,
    m._loaded_at,
    CURRENT_TIMESTAMP() AS _silver_processed_at
FROM BRONZE.MOVIMIENTOS m;

-- Silver: Saldos (último saldo por cliente/producto — SCD Type 1)
CREATE OR REPLACE DYNAMIC TABLE SILVER.DIM_SALDOS_ACTUALES
    TARGET_LAG = '10 minutes'
    WAREHOUSE = PRIMUS_ETL_WH
AS
WITH ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY client_id, producto_id
            ORDER BY fecha_corte DESC
        ) AS _rn
    FROM BRONZE.SALDOS
)
SELECT
    client_id,
    producto_id,
    fecha_corte AS fecha_ultimo_saldo,
    saldo_contable,
    saldo_disponible,
    saldo_promedio_mes,
    estado_cuenta,
    saldo_contable - saldo_disponible AS saldo_retenido,
    CASE
        WHEN saldo_contable > 50000000 THEN 'Alto'
        WHEN saldo_contable > 5000000 THEN 'Medio'
        WHEN saldo_contable > 0 THEN 'Bajo'
        ELSE 'Sin saldo'
    END AS rango_saldo,
    CURRENT_TIMESTAMP() AS _silver_processed_at
FROM ranked
WHERE _rn = 1;

-- ======================================================================
-- 3. GOLD LAYER — Dynamic Tables (agregaciones de negocio)
-- Gold depende de Silver, que depende de Bronze.
-- El grafo se resuelve automáticamente. Cero orquestación.
-- 
-- Gold: Perfil 360° de cliente

CREATE OR REPLACE DYNAMIC TABLE GOLD.PERFIL_CLIENTE_360
    TARGET_LAG = '30 minutes'
    WAREHOUSE = PRIMUS_ETL_WH
AS
SELECT
    c.client_id,
    c.nombre_completo,
    c.segmento,
    c.categoria_antiguedad,
    c.sucursal_comuna,
    c.sucursal_region,
    c.dias_antiguedad,
    -- Métricas de transacciones
    COALESCE(t.total_txn, 0) AS total_transacciones,
    COALESCE(t.txn_aprobadas, 0) AS transacciones_aprobadas,
    COALESCE(t.total_ingresos, 0) AS total_ingresos,
    COALESCE(t.total_egresos, 0) AS total_egresos,
    COALESCE(t.neto, 0) AS balance_neto,
    COALESCE(t.ticket_promedio, 0) AS ticket_promedio,
    COALESCE(t.productos_distintos, 0) AS productos_utilizados,
    t.primera_txn,
    t.ultima_txn,
    -- Saldo actual
    COALESCE(s.saldo_total, 0) AS saldo_total,
    COALESCE(s.num_productos_activos, 0) AS productos_activos,
    -- Actividad reciente (últimos 90 días)
    COALESCE(r.txn_90d, 0) AS transacciones_90d,
    COALESCE(r.volumen_90d, 0) AS volumen_90d,
    -- Scoring simplificado
    CASE
        WHEN COALESCE(t.total_txn, 0) > 500 AND COALESCE(s.saldo_total, 0) > 10000000 THEN 'A - Premium'
        WHEN COALESCE(t.total_txn, 0) > 200 OR COALESCE(s.saldo_total, 0) > 5000000 THEN 'B - Alto'
        WHEN COALESCE(t.total_txn, 0) > 50 THEN 'C - Medio'
        ELSE 'D - Bajo'
    END AS categoria_valor,
    CURRENT_TIMESTAMP() AS _gold_processed_at
FROM SILVER.DIM_CLIENTES c
LEFT JOIN (
    SELECT client_id,
        COUNT(*) AS total_txn,
        SUM(CASE WHEN estado = 'Aprobada' THEN 1 ELSE 0 END) AS txn_aprobadas,
        SUM(CASE WHEN monto > 0 THEN monto ELSE 0 END) AS total_ingresos,
        SUM(CASE WHEN monto < 0 THEN ABS(monto) ELSE 0 END) AS total_egresos,
        SUM(monto) AS neto,
        AVG(monto) AS ticket_promedio,
        COUNT(DISTINCT producto_id) AS productos_distintos,
        MIN(fecha) AS primera_txn,
        MAX(fecha) AS ultima_txn
    FROM SILVER.FACT_TRANSACCIONES
    WHERE _quality_flag = 'OK'
    GROUP BY client_id
) t ON c.client_id = t.client_id
LEFT JOIN (
    SELECT client_id,
        SUM(saldo_contable) AS saldo_total,
        COUNT(DISTINCT producto_id) AS num_productos_activos
    FROM SILVER.DIM_SALDOS_ACTUALES
    WHERE estado_cuenta = 'Activa'
    GROUP BY client_id
) s ON c.client_id = s.client_id
LEFT JOIN (
    SELECT client_id,
        COUNT(*) AS txn_90d,
        SUM(monto) AS volumen_90d
    FROM SILVER.FACT_TRANSACCIONES
    WHERE fecha_date >= DATEADD('day', -90, CURRENT_DATE())
      AND _quality_flag = 'OK'
    GROUP BY client_id
) r ON c.client_id = r.client_id;

-- Gold: Resumen mensual por sucursal (para dashboards BI)
CREATE OR REPLACE DYNAMIC TABLE GOLD.RESUMEN_MENSUAL_SUCURSAL
    TARGET_LAG = '30 minutes'
    WAREHOUSE = PRIMUS_ETL_WH
AS
SELECT
    t.mes,
    t.sucursal_id,
    s.comuna,
    s.region,
    COUNT(*) AS total_operaciones,
    COUNT(DISTINCT t.client_id) AS clientes_activos,
    SUM(CASE WHEN t.monto > 0 THEN t.monto ELSE 0 END) AS captaciones,
    SUM(CASE WHEN t.monto < 0 THEN ABS(t.monto) ELSE 0 END) AS colocaciones,
    SUM(t.monto) AS neto,
    AVG(t.monto_absoluto) AS ticket_promedio,
    SUM(CASE WHEN t.estado = 'Aprobada' THEN 1 ELSE 0 END)::FLOAT / NULLIF(COUNT(*), 0) AS tasa_aprobacion,
    COUNT(DISTINCT t.producto_id) AS productos_operados,
    SUM(CASE WHEN t.es_fin_semana THEN 1 ELSE 0 END)::FLOAT / NULLIF(COUNT(*), 0) AS pct_fin_semana,
    CURRENT_TIMESTAMP() AS _gold_processed_at
FROM SILVER.FACT_TRANSACCIONES t
JOIN RAW.SUCURSALES s ON t.sucursal_id = s.sucursal_id
WHERE t._quality_flag = 'OK'
GROUP BY t.mes, t.sucursal_id, s.comuna, s.region;

-- Gold: Alertas de calidad de datos (quality gate)
CREATE OR REPLACE DYNAMIC TABLE GOLD.QUALITY_ALERTS
    TARGET_LAG = '10 minutes'
    WAREHOUSE = PRIMUS_ETL_WH
AS
SELECT 'FACT_TRANSACCIONES' AS tabla, _quality_flag, COUNT(*) AS registros, MAX(_silver_processed_at) AS ultimo_check
FROM SILVER.FACT_TRANSACCIONES WHERE _quality_flag != 'OK' GROUP BY _quality_flag
UNION ALL
SELECT 'FACT_MOVIMIENTOS', _quality_flag, COUNT(*), MAX(_silver_processed_at)
FROM SILVER.FACT_MOVIMIENTOS WHERE _quality_flag != 'OK' GROUP BY _quality_flag;

-- ======================================================================
-- ## 4. OBSERVABILIDAD DEL PIPELINE
-- 
-- Ver el grafo de dependencias y estado de refresh

SHOW DYNAMIC TABLES IN SCHEMA SILVER;
SHOW DYNAMIC TABLES IN SCHEMA GOLD;

-- Historial de refresh (latencia, duración, filas procesadas)
SELECT
    name,
    schema_name,
    target_lag_sec / 60 AS target_lag_min,
    ROUND(data_timestamp_last_refresh_lag_sec / 60, 1) AS actual_lag_min,
    refresh_trigger,
    refresh_status,
    last_completed_refresh_time
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY())
WHERE database_name = 'PRIMUS_POC'
ORDER BY last_completed_refresh_time DESC
LIMIT 20;

-- Lineage: qué depende de qué
SELECT
    name AS dynamic_table,
    schema_name AS schema,
    target_lag_sec / 60 AS lag_min
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_GRAPH_HISTORY())
WHERE database_name = 'PRIMUS_POC'
ORDER BY schema_name, name;

-- ======================================================================
-- 5. DEMO CDC: Simular llegada de datos nuevos
-- 
-- Insertar nuevas transacciones en bronze (simula carga diaria)

INSERT INTO BRONZE.TRANSACCIONES (txn_id, client_id, producto_id, sucursal_id, fecha, tipo, monto, moneda, estado, referencia, _source_file)
SELECT
    txn_id + 100000000,
    client_id,
    producto_id,
    sucursal_id,
    CURRENT_TIMESTAMP(),
    tipo,
    ROUND(monto * UNIFORM(0.9, 1.1, RANDOM()), 2),
    moneda,
    estado,
    'REF-' || UNIFORM(1, 999999, RANDOM())::VARCHAR,
    'daily_load_' || CURRENT_DATE()::VARCHAR
FROM BRONZE.TRANSACCIONES
SAMPLE (100000 ROWS);

-- El stream captura los cambios automáticamente
SELECT
    'STREAM_TRANSACCIONES' AS stream,
    SYSTEM$STREAM_HAS_DATA('BRONZE.STREAM_TRANSACCIONES') AS has_data;

-- Las Dynamic Tables de silver y gold se refrescarán automáticamente
-- dentro de su TARGET_LAG (10 min silver, 30 min gold).
-- Para la demo, forzar refresh:
ALTER DYNAMIC TABLE SILVER.FACT_TRANSACCIONES REFRESH;

-- Verificar que los datos fluyeron bronze → silver → gold
SELECT
    'BRONZE.TRANSACCIONES' AS capa, COUNT(*) AS filas FROM BRONZE.TRANSACCIONES
UNION ALL
SELECT 'SILVER.FACT_TRANSACCIONES', COUNT(*) FROM SILVER.FACT_TRANSACCIONES
UNION ALL
SELECT 'GOLD.RESUMEN_MENSUAL_SUCURSAL', COUNT(*) FROM GOLD.RESUMEN_MENSUAL_SUCURSAL
UNION ALL
SELECT 'GOLD.PERFIL_CLIENTE_360', COUNT(*) FROM GOLD.PERFIL_CLIENTE_360
UNION ALL
SELECT 'GOLD.QUALITY_ALERTS', COUNT(*) FROM GOLD.QUALITY_ALERTS
ORDER BY capa;

SELECT '=== Pipeline medallion operativo: Bronze → Silver → Gold ===' AS status;
