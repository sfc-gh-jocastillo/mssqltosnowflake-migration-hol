# ======================================================================
# PRIMUS CAPITAL POC — Módulo 2b: Snowpark Python — 3 Procesos Complejos

# ======================================================================
# Ejecutar en Snowflake Notebook (Python) o Snowsight Python Worksheet.
# Demuestra que los 3 procesos lentos del cliente se resuelven con Snowpark
# sin necesidad de infraestructura Spark externa.

# ======================================================================
# ## Celda 1: Setup

import snowflake.snowpark as snowpark
from snowflake.snowpark import Session, DataFrame
from snowflake.snowpark.functions import (
    col, sum as sum_, count, avg, min as min_, max as max_,
    abs as abs_, when, lit, row_number, dense_rank,
    datediff, date_trunc, current_timestamp, round as round_,
    iff, coalesce, lag
)
from snowflake.snowpark.window import Window
from snowflake.snowpark.types import (
    StructType, StructField, StringType, FloatType, IntegerType
)
import time

# Si ejecutas desde notebook, session ya existe.
# Si ejecutas local: session = Session.builder.configs({...}).create()

session.sql("USE DATABASE PRIMUS_POC").collect()
session.sql("USE SCHEMA SANDBOX").collect()
session.sql("USE WAREHOUSE PRIMUS_ETL_WH").collect()

print("Snowpark session activa:", session.get_current_database(), session.get_current_schema())

# ======================================================================
# ## Celda 2: Proceso 1 — Scoring de clientes
# Lógica compleja: combina transacciones + saldos + movimientos para calcular
# un score por cliente. En SQL Server esto tarda mucho por los JOINs pesados.

print("=" * 60)
print("PROCESO 1: Scoring de clientes")
print("=" * 60)

start = time.time()

# Leer tablas
clientes = session.table("DWH.DIM_CLIENTES")
transacciones = session.table("DWH.FACT_TRANSACCIONES")
saldos = session.table("RAW.SALDOS")

# Métricas de transacciones por cliente
txn_metrics = (
    transacciones
    .filter(col("ESTADO") == "Aprobada")
    .group_by("CLIENT_ID")
    .agg(
        count("TXN_ID").alias("TOTAL_TXN"),
        sum_(when(col("MONTO") > 0, col("MONTO")).otherwise(lit(0))).alias("TOTAL_INGRESOS"),
        sum_(when(col("MONTO") < 0, abs_(col("MONTO"))).otherwise(lit(0))).alias("TOTAL_EGRESOS"),
        avg("MONTO").alias("MONTO_PROMEDIO"),
        count(date_trunc("month", col("FECHA"))).alias("MESES_ACTIVO"),
        max_("FECHA").alias("ULTIMA_TXN")
    )
)

# Último saldo por cliente
w_saldo = Window.partition_by("CLIENT_ID").order_by(col("FECHA_CORTE").desc())
ultimo_saldo = (
    saldos
    .with_column("RN", row_number().over(w_saldo))
    .filter(col("RN") == 1)
    .select("CLIENT_ID", "SALDO_CONTABLE", "SALDO_DISPONIBLE")
)

# Calcular scoring
scoring = (
    clientes
    .select("CLIENT_ID", "SEGMENTO", "SUCURSAL_COMUNA", "FECHA_REGISTRO")
    .join(txn_metrics, "CLIENT_ID", "left")
    .join(ultimo_saldo, "CLIENT_ID", "left")
    .with_column("ANTIGUEDAD_DIAS",
        datediff("day", col("FECHA_REGISTRO"), current_timestamp()))
    .with_column("SCORE_ACTIVIDAD",
        # Más transacciones = mejor score (normalizado 0-30)
        iff(col("TOTAL_TXN").is_null(), lit(0),
            when(col("TOTAL_TXN") > 500, lit(30))
            .when(col("TOTAL_TXN") > 200, lit(25))
            .when(col("TOTAL_TXN") > 100, lit(20))
            .when(col("TOTAL_TXN") > 50, lit(15))
            .when(col("TOTAL_TXN") > 10, lit(10))
            .otherwise(lit(5))
        )
    )
    .with_column("SCORE_VOLUMEN",
        # Mayor volumen = mejor score (normalizado 0-30)
        iff(col("TOTAL_INGRESOS").is_null(), lit(0),
            when(col("TOTAL_INGRESOS") > 100000000, lit(30))
            .when(col("TOTAL_INGRESOS") > 50000000, lit(25))
            .when(col("TOTAL_INGRESOS") > 10000000, lit(20))
            .when(col("TOTAL_INGRESOS") > 1000000, lit(15))
            .when(col("TOTAL_INGRESOS") > 100000, lit(10))
            .otherwise(lit(5))
        )
    )
    .with_column("SCORE_SALDO",
        # Mayor saldo = mejor score (normalizado 0-20)
        iff(col("SALDO_CONTABLE").is_null(), lit(0),
            when(col("SALDO_CONTABLE") > 100000000, lit(20))
            .when(col("SALDO_CONTABLE") > 10000000, lit(15))
            .when(col("SALDO_CONTABLE") > 1000000, lit(10))
            .otherwise(lit(5))
        )
    )
    .with_column("SCORE_ANTIGUEDAD",
        # Mayor antigüedad = mejor score (normalizado 0-20)
        when(col("ANTIGUEDAD_DIAS") > 1825, lit(20))
        .when(col("ANTIGUEDAD_DIAS") > 1095, lit(15))
        .when(col("ANTIGUEDAD_DIAS") > 365, lit(10))
        .otherwise(lit(5))
    )
    .with_column("SCORE_TOTAL",
        col("SCORE_ACTIVIDAD") + col("SCORE_VOLUMEN") +
        col("SCORE_SALDO") + col("SCORE_ANTIGUEDAD")
    )
    .with_column("CATEGORIA_SCORE",
        when(col("SCORE_TOTAL") >= 80, lit("A - Excelente"))
        .when(col("SCORE_TOTAL") >= 60, lit("B - Bueno"))
        .when(col("SCORE_TOTAL") >= 40, lit("C - Regular"))
        .otherwise(lit("D - Básico"))
    )
)

# Guardar resultado
scoring.write.mode("overwrite").save_as_table("DWH.SCORING_CLIENTES")

elapsed_1 = time.time() - start
count_1 = session.table("DWH.SCORING_CLIENTES").count()
print(f"  Resultado: {count_1:,} clientes con scoring")
print(f"  Tiempo: {elapsed_1:.1f} segundos")

# Distribución de scores
session.table("DWH.SCORING_CLIENTES") \
    .group_by("CATEGORIA_SCORE") \
    .agg(count("CLIENT_ID").alias("CLIENTES")) \
    .sort("CATEGORIA_SCORE") \
    .show()

# ======================================================================
# ## Celda 3: Proceso 2 — Reconciliación de saldos
# Cruza saldos calculados (desde movimientos) vs saldos reportados.
# Detecta discrepancias. En SQL Server es uno de los procesos más lentos.

print("=" * 60)
print("PROCESO 2: Reconciliación de saldos")
print("=" * 60)

start = time.time()

movimientos = session.table("RAW.MOVIMIENTOS")
saldos = session.table("RAW.SALDOS")

# Saldo calculado: sumar movimientos por cliente/producto
saldo_calculado = (
    movimientos
    .group_by("CLIENT_ID", "PRODUCTO_ID")
    .agg(
        sum_("MONTO").alias("SALDO_CALCULADO"),
        count("MOVIMIENTO_ID").alias("NUM_MOVIMIENTOS"),
        max_("FECHA").alias("ULTIMO_MOVIMIENTO")
    )
)

# Último saldo reportado por cliente/producto
w = Window.partition_by("CLIENT_ID", "PRODUCTO_ID").order_by(col("FECHA_CORTE").desc())
saldo_reportado = (
    saldos
    .with_column("RN", row_number().over(w))
    .filter(col("RN") == 1)
    .select("CLIENT_ID", "PRODUCTO_ID", "SALDO_CONTABLE", "FECHA_CORTE")
)

# Cruzar y detectar discrepancias
TOLERANCIA = 1000  # CLP de tolerancia

reconciliacion = (
    saldo_calculado
    .join(saldo_reportado, ["CLIENT_ID", "PRODUCTO_ID"], "full")
    .with_column("DIFERENCIA",
        coalesce(col("SALDO_CALCULADO"), lit(0)) - coalesce(col("SALDO_CONTABLE"), lit(0))
    )
    .with_column("ABS_DIFERENCIA", abs_(col("DIFERENCIA")))
    .with_column("ESTADO_RECONCILIACION",
        when(col("ABS_DIFERENCIA") <= lit(TOLERANCIA), lit("OK"))
        .when(col("SALDO_CALCULADO").is_null(), lit("SIN_MOVIMIENTOS"))
        .when(col("SALDO_CONTABLE").is_null(), lit("SIN_SALDO_REPORTADO"))
        .otherwise(lit("DISCREPANCIA"))
    )
)

# Solo guardar excepciones (discrepancias)
excepciones = reconciliacion.filter(col("ESTADO_RECONCILIACION") != "OK")
excepciones.write.mode("overwrite").save_as_table("DWH.EXCEPCIONES_RECONCILIACION")

elapsed_2 = time.time() - start
count_2 = session.table("DWH.EXCEPCIONES_RECONCILIACION").count()
print(f"  Excepciones encontradas: {count_2:,}")
print(f"  Tiempo: {elapsed_2:.1f} segundos")

# Resumen de estados
reconciliacion.group_by("ESTADO_RECONCILIACION") \
    .agg(count("*").alias("REGISTROS")) \
    .sort("ESTADO_RECONCILIACION") \
    .show()

# ======================================================================
# ## Celda 4: Proceso 3 — Agregación compleja con window functions
# Calcula acumulados, promedios móviles y tendencias por cliente/mes.
# Este tipo de proceso es el que peor rinde en SQL Server por la
# combinación de window functions + GROUP BY sobre tablas grandes.

print("=" * 60)
print("PROCESO 3: Agregación compleja de movimientos")
print("=" * 60)

start = time.time()

transacciones = session.table("DWH.FACT_TRANSACCIONES")

# Agregación mensual por cliente
mensual = (
    transacciones
    .filter(col("ESTADO") == "Aprobada")
    .with_column("MES", date_trunc("month", col("FECHA")))
    .group_by("CLIENT_ID", "MES")
    .agg(
        count("TXN_ID").alias("NUM_TXN"),
        sum_(when(col("MONTO") > 0, col("MONTO")).otherwise(lit(0))).alias("INGRESOS"),
        sum_(when(col("MONTO") < 0, abs_(col("MONTO"))).otherwise(lit(0))).alias("EGRESOS"),
        sum_("MONTO").alias("NETO"),
        avg("MONTO").alias("TICKET_PROMEDIO")
    )
)

# Window functions: acumulados y promedios móviles
w_cliente = Window.partition_by("CLIENT_ID").order_by("MES")
w_rolling3 = Window.partition_by("CLIENT_ID").order_by("MES").rows_between(-2, 0)

resultado = (
    mensual
    .with_column("INGRESOS_ACUM", sum_("INGRESOS").over(w_cliente))
    .with_column("EGRESOS_ACUM", sum_("EGRESOS").over(w_cliente))
    .with_column("NETO_ACUM", sum_("NETO").over(w_cliente))
    .with_column("PROMEDIO_MOVIL_3M", round_(avg("NETO").over(w_rolling3), 2))
    .with_column("MES_ANTERIOR_NETO", lag("NETO", 1).over(w_cliente))
    .with_column("VARIACION_MOM",
        iff(
            col("MES_ANTERIOR_NETO").is_null() | (col("MES_ANTERIOR_NETO") == lit(0)),
            lit(None),
            round_((col("NETO") - col("MES_ANTERIOR_NETO")) / abs_(col("MES_ANTERIOR_NETO")) * lit(100), 2)
        )
    )
    .with_column("RANKING_MES",
        dense_rank().over(Window.partition_by("MES").order_by(col("NETO").desc()))
    )
)

resultado.write.mode("overwrite").save_as_table("DWH.AGREGACION_MENSUAL_CLIENTES")

elapsed_3 = time.time() - start
count_3 = session.table("DWH.AGREGACION_MENSUAL_CLIENTES").count()
print(f"  Registros generados: {count_3:,}")
print(f"  Tiempo: {elapsed_3:.1f} segundos")

# Sample
session.table("DWH.AGREGACION_MENSUAL_CLIENTES") \
    .filter(col("CLIENT_ID") == 1) \
    .sort("MES") \
    .show(12)

# ======================================================================
# ## Celda 5: Resumen del benchmark

print("=" * 60)
print("RESUMEN DE BENCHMARK — Snowpark Python")
print("=" * 60)
print(f"  Proceso 1 (Scoring):        {elapsed_1:6.1f} seg  ({count_1:>10,} filas)")
print(f"  Proceso 2 (Reconciliación):  {elapsed_2:6.1f} seg  ({count_2:>10,} excepciones)")
print(f"  Proceso 3 (Agregación):      {elapsed_3:6.1f} seg  ({count_3:>10,} filas)")
print(f"  {'─' * 50}")
total = elapsed_1 + elapsed_2 + elapsed_3
print(f"  TOTAL:                       {total:6.1f} seg")
print(f"")
print(f"  Los 3 procesos complejos se ejecutaron en {total:.0f} segundos")
print(f"  usando Snowpark Python sobre un warehouse Medium,")
print(f"  sin infraestructura Spark externa.")
