---
sidebar_position: 6
---

# Snowpark Python

<a href="/mssqltosnowflake-migration-hol/downloads/04_snowpark_procesos.py" download="04_snowpark_procesos.py" class="button button--primary button--sm" style={{marginBottom: "1.5rem", display: "inline-block"}}>Descargar 04_snowpark_procesos.py</a>


Tres procesos complejos ejecutados con Snowpark DataFrames — API de DataFrames nativa que corre sobre el warehouse de Snowflake.

## Por que Snowpark

Snowpark es la API nativa de DataFrames de Snowflake. Se ejecuta sobre el warehouse, los datos nunca salen de la plataforma.

| | ETL Tradicional | Snowpark |
|--|---------|----------|
| API | `DataFrame` externo | `snowflake.snowpark.DataFrame` |
| Compute | Cluster externo | Warehouse Snowflake |
| Infra | Gestionar infraestructura | Cero (auto-suspend) |
| Movimiento de datos | Requiere mover datos | Datos ya estan en Snowflake |

## Proceso 1: Scoring de clientes

Cruza transacciones + saldos + movimientos para calcular un score:

```python
from snowflake.snowpark.functions import col, sum as sum_, count, avg, when, lit, row_number
from snowflake.snowpark.window import Window

clientes = session.table("DWH.DIM_CLIENTES")
transacciones = session.table("DWH.FACT_TRANSACCIONES")
saldos = session.table("RAW.SALDOS")

# Metricas de transacciones
txn_metrics = (
    transacciones
    .filter(col("ESTADO") == "Aprobada")
    .group_by("CLIENT_ID")
    .agg(
        count("TXN_ID").alias("TOTAL_TXN"),
        sum_(when(col("MONTO") > 0, col("MONTO")).otherwise(lit(0))).alias("TOTAL_INGRESOS"),
        avg("MONTO").alias("MONTO_PROMEDIO")
    )
)

# Ultimo saldo por cliente (window function)
w_saldo = Window.partition_by("CLIENT_ID").order_by(col("FECHA_CORTE").desc())
ultimo_saldo = (
    saldos
    .with_column("RN", row_number().over(w_saldo))
    .filter(col("RN") == 1)
    .select("CLIENT_ID", "SALDO_CONTABLE")
)

# Scoring
scoring = (
    clientes.select("CLIENT_ID", "SEGMENTO")
    .join(txn_metrics, "CLIENT_ID", "left")
    .join(ultimo_saldo, "CLIENT_ID", "left")
    .with_column("SCORE_TOTAL", ...)
    .with_column("CATEGORIA_SCORE",
        when(col("SCORE_TOTAL") >= 80, lit("A - Excelente"))
        .when(col("SCORE_TOTAL") >= 60, lit("B - Bueno"))
        .otherwise(lit("D - Basico"))
    )
)

scoring.write.mode("overwrite").save_as_table("DWH.SCORING_CLIENTES")
```

## Proceso 2: Reconciliacion de saldos

Detecta discrepancias entre saldos calculados y reportados:

```python
# Saldo calculado desde movimientos
saldo_calculado = (
    movimientos
    .group_by("CLIENT_ID", "PRODUCTO_ID")
    .agg(sum_("MONTO").alias("SALDO_CALCULADO"))
)

# Cruce + deteccion de discrepancias
reconciliacion = (
    saldo_calculado
    .join(saldo_reportado, ["CLIENT_ID", "PRODUCTO_ID"], "full")
    .with_column("DIFERENCIA",
        coalesce(col("SALDO_CALCULADO"), lit(0)) -
        coalesce(col("SALDO_CONTABLE"), lit(0)))
    .with_column("ESTADO",
        when(abs_(col("DIFERENCIA")) <= lit(1000), lit("OK"))
        .otherwise(lit("DISCREPANCIA")))
)
```

## Proceso 3: Agregacion con window functions

Promedios moviles, variacion MoM, ranking:

```python
w_cliente = Window.partition_by("CLIENT_ID").order_by("MES")
w_rolling3 = Window.partition_by("CLIENT_ID").order_by("MES").rows_between(-2, 0)

resultado = (
    mensual
    .with_column("NETO_ACUM", sum_("NETO").over(w_cliente))
    .with_column("PROMEDIO_MOVIL_3M", avg("NETO").over(w_rolling3))
    .with_column("MES_ANTERIOR", lag("NETO", 1).over(w_cliente))
    .with_column("VARIACION_MOM", ...)
)
```

:::tip rows_between(-2, 0)
Rolling window de 3 periodos. Semantica equivalente a rolling windows en otros frameworks de DataFrames.
:::

## Benchmark

Los tres procesos corren sobre 70M+ filas en un warehouse Medium:

| Proceso | Filas procesadas | Tiempo |
|---------|-----------------|--------|
| Scoring | 500K clientes | ~X seg |
| Reconciliacion | 18M registros | ~X seg |
| Agregacion | 50M transacciones | ~X seg |
| **Total** | | **~X seg** |

Sin infraestructura adicional. El warehouse se apaga en 60 segundos.
