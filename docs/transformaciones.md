---
sidebar_position: 5
---

# Transformaciones SQL + Tasks DAG

<a href="/mssqltosnowflake-migration-hol/downloads/03_transformaciones.sql" download="03_transformaciones.sql" class="button button--primary button--sm" style={{marginBottom: "1.5rem", display: "inline-block"}}>Descargar 03_transformaciones.sql</a>


Stored procedures con logica de negocio orquestados en un DAG paralelo. Reemplaza jobs ETL secuenciales con paralelismo nativo.

## Stored Procedures

### Resumen de actividad por cliente

```sql
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
        COUNT(DISTINCT t.txn_id) AS total_transacciones,
        SUM(CASE WHEN t.monto > 0 THEN t.monto ELSE 0 END) AS total_ingresos,
        SUM(CASE WHEN t.monto < 0 THEN ABS(t.monto) ELSE 0 END) AS total_egresos,
        AVG(t.monto) AS monto_promedio,
        COUNT(DISTINCT DATE_TRUNC('month', t.fecha)) AS meses_activo
    FROM DWH.DIM_CLIENTES c
    INNER JOIN DWH.FACT_TRANSACCIONES t ON c.client_id = t.client_id
    WHERE t.estado = 'Aprobada'
    GROUP BY c.client_id, c.segmento;
    RETURN 'OK: ' || (SELECT COUNT(*) FROM DWH.RESUMEN_ACTIVIDAD_CLIENTE) || ' clientes';
END;
$$
```

Se crean tambien `SP_TOP_CLIENTES_SUCURSAL` y `SP_METRICAS_PRODUCTOS` con patrones similares.

## Task DAG

El DAG define dependencias entre tareas. Las que dependen del mismo padre **corren en paralelo**:

```
TASK_ETL_ROOT (6 AM local)
    ├── TASK_RESUMEN_ACTIVIDAD    ─┐
    ├── TASK_TOP_CLIENTES         ─┤── paralelo
    └── TASK_METRICAS_PRODUCTOS   ─┘
```

```sql
-- Root task con schedule
CREATE OR REPLACE TASK DWH.TASK_ETL_ROOT
    WAREHOUSE = ETL_WH
    SCHEDULE = 'USING CRON 0 6 * * * America/Santiago'
AS
SELECT 'Pipeline ETL iniciado' AS status;

-- Tareas paralelas
CREATE OR REPLACE TASK DWH.TASK_RESUMEN_ACTIVIDAD
    WAREHOUSE = ETL_WH
    AFTER DWH.TASK_ETL_ROOT
AS
CALL DWH.SP_RESUMEN_ACTIVIDAD();

CREATE OR REPLACE TASK DWH.TASK_TOP_CLIENTES
    WAREHOUSE = ETL_WH
    AFTER DWH.TASK_ETL_ROOT
AS
CALL DWH.SP_TOP_CLIENTES_SUCURSAL();
```

:::info AFTER = paralelismo
La clausula `AFTER task_padre` hace que los tres tasks hijos corran **en paralelo**, no secuencialmente. Para paralelizar en herramientas ETL tradicionales se requiere configuracion compleja. Aca es una linea.
:::

## Dynamic Tables como alternativa

Para transformaciones que son puro SQL sin logica procedural, las Dynamic Tables son mejor que SPs + Tasks:

```sql
CREATE OR REPLACE DYNAMIC TABLE DWH.DT_RESUMEN_MENSUAL
    TARGET_LAG = '1 hour'
    WAREHOUSE = ETL_WH
AS
SELECT
    DATE_TRUNC('month', t.fecha)::DATE AS mes,
    t.tipo,
    s.region,
    COUNT(*) AS num_transacciones,
    SUM(t.monto) AS volumen_total,
    AVG(t.monto) AS ticket_promedio
FROM DWH.FACT_TRANSACCIONES t
JOIN DWH.DIM_SUCURSALES s ON t.sucursal_id = s.sucursal_id
GROUP BY mes, t.tipo, s.region;
```

No hay que ejecutarla, no hay que programarla. Se refresca sola.
