---
sidebar_position: 7
---

# Clustering y Performance

<a href="/mssqltosnowflake-migration-hol/downloads/05_clustering_performance.sql" download="05_clustering_performance.sql" class="button button--primary button--sm" style={{marginBottom: "1.5rem", display: "inline-block"}}>Descargar 05_clustering_performance.sql</a>


Reduccion de scanning de 260 TB a ~10 TB/mes con clustering keys. Benchmark con 5 queries antes y despues.

## Como funciona

En bases de datos tradicionales se usan indices B-tree. En Snowflake no hay indices — hay **micro-partitions**: bloques de 50-500 MB con metadata estadistica (min/max por columna). Cuando filtran por fecha, Snowflake descarta particiones enteras sin leerlas. Eso es **partition pruning**.

El clustering key le dice a Snowflake como ordenar los datos para maximizar el pruning.

## Baseline: sin clustering

Ejecutar 5 queries representativas sobre FACT_TRANSACCIONES (50M filas) y capturar `PARTITIONS_SCANNED`:

```sql
USE WAREHOUSE ANALYTICS_WH;
ALTER SESSION SET QUERY_TAG = 'BENCH_NO_CLUSTER';

-- Query 1: Rango de fechas
SELECT mes, tipo,
       COUNT(*) AS num_txn, SUM(monto) AS volumen
FROM DWH.FACT_TRANSACCIONES
WHERE fecha BETWEEN '2024-01-01' AND '2024-03-31'
GROUP BY mes, tipo;

-- Query 2: Fecha + sucursal
SELECT t.sucursal_id, COUNT(*) AS num_txn, SUM(t.monto) AS volumen
FROM DWH.FACT_TRANSACCIONES t
WHERE t.fecha >= '2024-06-01' AND t.fecha < '2024-07-01'
  AND t.sucursal_id IN (1, 5, 10, 15, 20)
GROUP BY t.sucursal_id;

-- Query 3: Point lookup
SELECT client_id, tipo, COUNT(*) AS num_txn
FROM DWH.FACT_TRANSACCIONES
WHERE client_id = 12345
GROUP BY client_id, tipo;

-- Query 4: Agregacion mensual
SELECT mes,
       COUNT(*) AS total, SUM(monto) AS volumen
FROM DWH.FACT_TRANSACCIONES
WHERE estado = 'Aprobada'
GROUP BY mes;

-- Query 5: Join pesado
SELECT t.client_id,
       COUNT(DISTINCT t.txn_id) AS num_txn,
       COUNT(DISTINCT m.movimiento_id) AS num_mov
FROM DWH.FACT_TRANSACCIONES t
INNER JOIN RAW.MOVIMIENTOS m
    ON t.client_id = m.client_id
    AND DATE_TRUNC('month', t.fecha) = DATE_TRUNC('month', m.fecha)
WHERE t.fecha BETWEEN '2024-06-01' AND '2024-06-30'
GROUP BY t.client_id
LIMIT 100;
```

## Aplicar clustering

```sql
ALTER TABLE DWH.FACT_TRANSACCIONES CLUSTER BY (fecha, sucursal_id);
ALTER TABLE RAW.MOVIMIENTOS CLUSTER BY (fecha, client_id);

-- Forzar reorganizacion
ALTER TABLE DWH.FACT_TRANSACCIONES RECLUSTER;
```

Luego re-ejecutar **exactamente las mismas 5 queries** con tag `BENCH_WITH_CLUSTER`.

## Comparacion

```sql
WITH benchmarks AS (
    SELECT QUERY_TAG, QUERY_TEXT, BYTES_SCANNED,
           PARTITIONS_SCANNED, PARTITIONS_TOTAL,
           TOTAL_ELAPSED_TIME,
           ROW_NUMBER() OVER (PARTITION BY QUERY_TAG
                              ORDER BY START_TIME) AS query_num
    FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(...))
    WHERE QUERY_TAG IN ('BENCH_NO_CLUSTER', 'BENCH_WITH_CLUSTER')
)
SELECT
    nc.query_num AS query,
    ROUND(nc.BYTES_SCANNED / 1024/1024, 1) AS mb_sin_cluster,
    ROUND(wc.BYTES_SCANNED / 1024/1024, 1) AS mb_con_cluster,
    nc.PARTITIONS_SCANNED || '/' || nc.PARTITIONS_TOTAL AS partitions_sin,
    wc.PARTITIONS_SCANNED || '/' || wc.PARTITIONS_TOTAL AS partitions_con,
    ROUND((1 - wc.BYTES_SCANNED::FLOAT / nc.BYTES_SCANNED) * 100, 1)
        AS reduccion_pct
FROM benchmarks nc
JOIN benchmarks wc ON nc.query_num = wc.query_num
WHERE nc.QUERY_TAG = 'BENCH_NO_CLUSTER'
  AND wc.QUERY_TAG = 'BENCH_WITH_CLUSTER';
```

### Resultado esperado

| Query | Sin clustering | Con clustering | Reduccion |
|-------|---------------|---------------|-----------|
| Rango fechas | ~todas | ~5-10% | >90% |
| Fecha + sucursal | ~todas | ~1-3% | >95% |
| Point lookup | ~todas | ~2-5% | >95% |
| Agregacion | ~todas | ~todas | similar |
| Join pesado | ~todas | ~10-20% | >80% |

## Extrapolacion

```sql
-- Si 260 TB/mes se reducen en el mismo porcentaje:
SELECT
    260 AS tb_mes_actual,
    ROUND(260 * (1 - AVG(reduccion)), 1) AS tb_mes_estimado
FROM (...);
-- Resultado esperado: ~10 TB/mes
```

:::tip Menos bytes = menos creditos
Menos scanning = queries mas rapidas = warehouse activo menos tiempo = menos creditos. El clustering es probablemente el mayor ahorro de costos operativos para este cliente.
:::
