-- ======================================================================
-- PRIMUS CAPITAL POC — Módulo 2: Transformaciones SQL + Tasks DAG
-- Demuestra ETL paralelo con Tasks DAG y Dynamic Tables.
-- Reemplaza los 50 SQL Server Agent jobs secuenciales.

USE DATABASE PRIMUS_POC;
USE WAREHOUSE PRIMUS_ETL_WH;

-- ======================================================================
-- 1. MODELO DIMENSIONAL (tablas destino)

CREATE OR REPLACE TABLE DWH.DIM_CLIENTES AS
SELECT
    c.client_id,
    c.rut,
    c.nombre,
    c.apellido,
    c.nombre || ' ' || c.apellido AS nombre_completo,
    c.email,
    c.telefono,
    c.direccion,
    c.fecha_registro,
    c.segmento,
    s.comuna AS sucursal_comuna,
    s.region AS sucursal_region,
    c.pseudonymized,
    c.pseudonymized_at,
    CURRENT_TIMESTAMP() AS etl_timestamp
FROM RAW.CLIENTES c
LEFT JOIN RAW.SUCURSALES s ON c.sucursal_id = s.sucursal_id;

CREATE OR REPLACE TABLE DWH.DIM_PRODUCTOS AS
SELECT
    p.producto_id,
    p.codigo,
    p.tipo,
    p.segmento,
    p.tasa_anual,
    p.es_credito,
    p.activo,
    CURRENT_TIMESTAMP() AS etl_timestamp
FROM RAW.PRODUCTOS p;

CREATE OR REPLACE TABLE DWH.DIM_SUCURSALES AS
SELECT
    s.*,
    CURRENT_TIMESTAMP() AS etl_timestamp
FROM RAW.SUCURSALES s;

CREATE OR REPLACE TABLE DWH.FACT_TRANSACCIONES AS
SELECT
    t.txn_id,
    t.client_id,
    t.producto_id,
    t.sucursal_id,
    t.fecha,
    DATE_TRUNC('month', t.fecha)::DATE AS mes,
    DATE_TRUNC('year', t.fecha)::DATE AS anio,
    t.tipo,
    t.monto,
    t.moneda,
    t.estado,
    t.referencia,
    CURRENT_TIMESTAMP() AS etl_timestamp
FROM RAW.TRANSACCIONES t;

-- ======================================================================
-- 2. STORED PROCEDURES (simulan la lógica actual de los 934 SPs)
-- 
-- SP: Resumen de actividad por cliente (simula lógica de negocio compleja)

CREATE OR REPLACE PROCEDURE DWH.SP_RESUMEN_ACTIVIDAD()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    CREATE OR REPLACE TABLE DWH.RESUMEN_ACTIVIDAD_CLIENTE AS
    SELECT
        c.client_id,
        c.segmento,
        c.sucursal_comuna,
        COUNT(DISTINCT t.txn_id) AS total_transacciones,
        COUNT(DISTINCT t.producto_id) AS productos_utilizados,
        SUM(CASE WHEN t.monto > 0 THEN t.monto ELSE 0 END) AS total_ingresos,
        SUM(CASE WHEN t.monto < 0 THEN ABS(t.monto) ELSE 0 END) AS total_egresos,
        SUM(t.monto) AS balance_neto,
        MIN(t.fecha) AS primera_transaccion,
        MAX(t.fecha) AS ultima_transaccion,
        DATEDIFF('day', MIN(t.fecha), MAX(t.fecha)) AS dias_actividad,
        AVG(t.monto) AS monto_promedio,
        MEDIAN(t.monto) AS monto_mediana,
        COUNT(DISTINCT DATE_TRUNC('month', t.fecha)) AS meses_activo
    FROM DWH.DIM_CLIENTES c
    INNER JOIN DWH.FACT_TRANSACCIONES t ON c.client_id = t.client_id
    WHERE t.estado = 'Aprobada'
    GROUP BY c.client_id, c.segmento, c.sucursal_comuna;

    RETURN 'OK: ' || (SELECT COUNT(*) FROM DWH.RESUMEN_ACTIVIDAD_CLIENTE) || ' clientes procesados';
END;
$$

-- SP: Top clientes por sucursal
CREATE OR REPLACE PROCEDURE DWH.SP_TOP_CLIENTES_SUCURSAL()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    CREATE OR REPLACE TABLE DWH.TOP_CLIENTES_SUCURSAL AS
    WITH ranked AS (
        SELECT
            t.sucursal_id,
            s.comuna,
            t.client_id,
            c.nombre_completo,
            c.segmento,
            SUM(CASE WHEN t.monto > 0 THEN t.monto ELSE 0 END) AS volumen_total,
            COUNT(*) AS num_transacciones,
            ROW_NUMBER() OVER (PARTITION BY t.sucursal_id ORDER BY SUM(ABS(t.monto)) DESC) AS ranking
        FROM DWH.FACT_TRANSACCIONES t
        JOIN DWH.DIM_CLIENTES c ON t.client_id = c.client_id
        JOIN DWH.DIM_SUCURSALES s ON t.sucursal_id = s.sucursal_id
        WHERE t.estado = 'Aprobada'
        GROUP BY t.sucursal_id, s.comuna, t.client_id, c.nombre_completo, c.segmento
    )
    SELECT * FROM ranked WHERE ranking <= 10;

    RETURN 'OK: Top 10 clientes por sucursal calculados';
END;
$$

-- SP: Métricas de productos
CREATE OR REPLACE PROCEDURE DWH.SP_METRICAS_PRODUCTOS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    CREATE OR REPLACE TABLE DWH.METRICAS_PRODUCTOS AS
    SELECT
        p.producto_id,
        p.tipo,
        p.segmento,
        p.tasa_anual,
        COUNT(DISTINCT t.client_id) AS clientes_activos,
        COUNT(t.txn_id) AS total_operaciones,
        SUM(t.monto) AS volumen_total,
        AVG(t.monto) AS ticket_promedio,
        MIN(t.fecha) AS primera_operacion,
        MAX(t.fecha) AS ultima_operacion
    FROM DWH.DIM_PRODUCTOS p
    LEFT JOIN DWH.FACT_TRANSACCIONES t ON p.producto_id = t.producto_id
    GROUP BY p.producto_id, p.tipo, p.segmento, p.tasa_anual;

    RETURN 'OK: ' || (SELECT COUNT(*) FROM DWH.METRICAS_PRODUCTOS) || ' productos analizados';
END;
$$

-- ======================================================================
-- 3. DYNAMIC TABLES (reemplazo de vistas materializadas manuales)
-- 
-- Resumen mensual auto-mantenido

CREATE OR REPLACE DYNAMIC TABLE DWH.DT_RESUMEN_MENSUAL
    TARGET_LAG = '1 hour'
    WAREHOUSE = PRIMUS_ETL_WH
AS
SELECT
    DATE_TRUNC('month', t.fecha)::DATE AS mes,
    t.tipo,
    s.region,
    COUNT(*) AS num_transacciones,
    COUNT(DISTINCT t.client_id) AS clientes_unicos,
    SUM(t.monto) AS volumen_total,
    AVG(t.monto) AS ticket_promedio,
    SUM(CASE WHEN t.estado = 'Aprobada' THEN 1 ELSE 0 END) AS aprobadas,
    SUM(CASE WHEN t.estado = 'Rechazada' THEN 1 ELSE 0 END) AS rechazadas,
    ROUND(SUM(CASE WHEN t.estado = 'Aprobada' THEN 1 ELSE 0 END)::FLOAT / COUNT(*) * 100, 2) AS tasa_aprobacion
FROM DWH.FACT_TRANSACCIONES t
JOIN DWH.DIM_SUCURSALES s ON t.sucursal_id = s.sucursal_id
GROUP BY mes, t.tipo, s.region;

-- Posición consolidada por cliente auto-mantenida
CREATE OR REPLACE DYNAMIC TABLE DWH.DT_POSICION_CLIENTE
    TARGET_LAG = '1 hour'
    WAREHOUSE = PRIMUS_ETL_WH
AS
SELECT
    c.client_id,
    c.segmento,
    c.sucursal_comuna,
    COALESCE(s.ultimo_saldo, 0) AS saldo_actual,
    COALESCE(t.total_txn_mes, 0) AS transacciones_mes_actual,
    COALESCE(t.volumen_mes, 0) AS volumen_mes_actual,
    COALESCE(m.movimientos_mes, 0) AS movimientos_mes_actual
FROM DWH.DIM_CLIENTES c
LEFT JOIN (
    SELECT client_id,
           saldo_contable AS ultimo_saldo
    FROM (
        SELECT client_id, saldo_contable,
               ROW_NUMBER() OVER (PARTITION BY client_id ORDER BY fecha_corte DESC) AS rn
        FROM RAW.SALDOS
    ) WHERE rn = 1
) s ON c.client_id = s.client_id
LEFT JOIN (
    SELECT client_id,
           COUNT(*) AS total_txn_mes,
           SUM(monto) AS volumen_mes
    FROM DWH.FACT_TRANSACCIONES
    WHERE fecha >= DATE_TRUNC('month', CURRENT_DATE())
    GROUP BY client_id
) t ON c.client_id = t.client_id
LEFT JOIN (
    SELECT client_id,
           COUNT(*) AS movimientos_mes
    FROM RAW.MOVIMIENTOS
    WHERE fecha >= DATE_TRUNC('month', CURRENT_DATE())
    GROUP BY client_id
) m ON c.client_id = m.client_id;

-- ======================================================================
-- 4. TASK DAG — Pipeline ETL paralelo
-- 
-- Root task (inicia el pipeline)

CREATE OR REPLACE TASK DWH.TASK_ETL_ROOT
    WAREHOUSE = PRIMUS_ETL_WH
    SCHEDULE = 'USING CRON 0 6 * * * America/Santiago'
AS
SELECT 'Pipeline ETL iniciado' AS status;

-- Tareas paralelas de transformación (dependen de root)
CREATE OR REPLACE TASK DWH.TASK_RESUMEN_ACTIVIDAD
    WAREHOUSE = PRIMUS_ETL_WH
    AFTER DWH.TASK_ETL_ROOT
AS
CALL DWH.SP_RESUMEN_ACTIVIDAD();

CREATE OR REPLACE TASK DWH.TASK_TOP_CLIENTES
    WAREHOUSE = PRIMUS_ETL_WH
    AFTER DWH.TASK_ETL_ROOT
AS
CALL DWH.SP_TOP_CLIENTES_SUCURSAL();

CREATE OR REPLACE TASK DWH.TASK_METRICAS_PRODUCTOS
    WAREHOUSE = PRIMUS_ETL_WH
    AFTER DWH.TASK_ETL_ROOT
AS
CALL DWH.SP_METRICAS_PRODUCTOS();

-- ======================================================================
-- 5. EJECUTAR PIPELINE MANUALMENTE (demo)
-- 
-- Ejecutar SPs directamente para medir tiempos

ALTER SESSION SET QUERY_TAG = 'ETL_PIPELINE';

CALL DWH.SP_RESUMEN_ACTIVIDAD();
CALL DWH.SP_TOP_CLIENTES_SUCURSAL();
CALL DWH.SP_METRICAS_PRODUCTOS();

ALTER SESSION SET QUERY_TAG = '';

-- Verificar resultados
SELECT 'DWH.DIM_CLIENTES' AS tabla, COUNT(*) AS filas FROM DWH.DIM_CLIENTES
UNION ALL SELECT 'DWH.FACT_TRANSACCIONES', COUNT(*) FROM DWH.FACT_TRANSACCIONES
UNION ALL SELECT 'DWH.RESUMEN_ACTIVIDAD_CLIENTE', COUNT(*) FROM DWH.RESUMEN_ACTIVIDAD_CLIENTE
UNION ALL SELECT 'DWH.TOP_CLIENTES_SUCURSAL', COUNT(*) FROM DWH.TOP_CLIENTES_SUCURSAL
UNION ALL SELECT 'DWH.METRICAS_PRODUCTOS', COUNT(*) FROM DWH.METRICAS_PRODUCTOS
ORDER BY tabla;

-- Tiempos del pipeline
SELECT
    QUERY_TEXT,
    ROUND(TOTAL_ELAPSED_TIME / 1000, 2) AS seconds,
    ROWS_PRODUCED
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    DATEADD('hour', -1, CURRENT_TIMESTAMP()),
    CURRENT_TIMESTAMP(),
    100
))
WHERE QUERY_TAG = 'ETL_PIPELINE'
ORDER BY START_TIME;

-- Sample de Dynamic Tables
SELECT * FROM DWH.DT_RESUMEN_MENSUAL ORDER BY mes DESC LIMIT 20;
SELECT * FROM DWH.DT_POSICION_CLIENTE LIMIT 20;
