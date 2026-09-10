---
sidebar_position: 3
---

# Datos sinteticos

<a href="/mssqltosnowflake-migration-hol/downloads/01_datos_sinteticos.sql" download="01_datos_sinteticos.sql" class="button button--primary button--sm" style={{marginBottom: "1.5rem", display: "inline-block"}}>Descargar 01_datos_sinteticos.sql</a>


Generar 70M+ filas que simulan la volumetria real: 500K clientes con RUT, 50M transacciones, 10M movimientos, 8M saldos.

## Dimensiones

```sql
USE DATABASE SNOWFLAKE_POC;
USE SCHEMA RAW;
USE WAREHOUSE ETL_WH;
```

### Sucursales (200 filas)

```sql
CREATE OR REPLACE TABLE RAW.SUCURSALES AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4()) AS sucursal_id,
    'SUC-' || LPAD(ROW_NUMBER() OVER (ORDER BY SEQ4()), 4, '0') AS codigo,
    CASE MOD(SEQ4(), 10)
        WHEN 0 THEN 'Providencia' WHEN 1 THEN 'Las Condes'
        WHEN 2 THEN 'Santiago Centro' WHEN 3 THEN 'Vitacura'
        WHEN 4 THEN 'Nunoa' WHEN 5 THEN 'La Florida'
        WHEN 6 THEN 'Maipu' WHEN 7 THEN 'Puente Alto'
        WHEN 8 THEN 'Valparaiso' WHEN 9 THEN 'Concepcion'
    END AS comuna
FROM TABLE(GENERATOR(ROWCOUNT => 200));
```

### Clientes (500K filas)

Incluye documento de identidad simulado, nombres, email, telefono — datos PII que usaremos para compliance:

```sql
CREATE OR REPLACE TABLE RAW.CLIENTES AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4()) AS client_id,
    LPAD(UNIFORM(5,25,RANDOM())::VARCHAR,2,'0') || '.' ||
    LPAD(UNIFORM(100,999,RANDOM())::VARCHAR,3,'0') || '.' ||
    LPAD(UNIFORM(100,999,RANDOM())::VARCHAR,3,'0') || '-' ||
    SUBSTR('0123456789K', UNIFORM(1,11,RANDOM()), 1) AS rut,
    -- ... nombre, apellido, email, telefono, etc.
    FALSE AS pseudonymized,
    NULL::TIMESTAMP_LTZ AS pseudonymized_at
FROM TABLE(GENERATOR(ROWCOUNT => 500000));
```

:::tip GENERATOR()
`GENERATOR()` crea filas en memoria directamente sobre el warehouse. No sube archivos, no necesita stages. Util para pruebas de carga y datos sinteticos.
:::

## Tablas de hechos

### Transacciones: 50M filas

Esta tabla simula la tabla mas grande del cliente (79 GB en origen). Con compresion columnar de Snowflake, se comprime a ~15-20 GB.

```sql
CREATE OR REPLACE TABLE RAW.TRANSACCIONES AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ8()) AS txn_id,
    UNIFORM(1, 500000, RANDOM()) AS client_id,
    UNIFORM(1, 5000, RANDOM()) AS producto_id,
    UNIFORM(1, 200, RANDOM()) AS sucursal_id,
    DATEADD('second', -UNIFORM(0, 157680000, RANDOM()),
            CURRENT_TIMESTAMP())::TIMESTAMP_NTZ AS fecha,
    CASE MOD(SEQ8(), 6)
        WHEN 0 THEN 'Deposito' WHEN 1 THEN 'Retiro'
        WHEN 2 THEN 'Transferencia' WHEN 3 THEN 'Pago'
        WHEN 4 THEN 'Inversion' ELSE 'Comision'
    END AS tipo,
    ROUND(UNIFORM(100, 50000000, RANDOM()), 2) AS monto
    -- ... moneda, estado, referencia
FROM TABLE(GENERATOR(ROWCOUNT => 50000000));
```

Tambien se generan **Movimientos** (10M) y **Saldos** (8M) con la misma tecnica.

## Verificacion

```sql
SELECT 'RAW.SUCURSALES' AS tabla, COUNT(*) AS filas FROM RAW.SUCURSALES
UNION ALL SELECT 'RAW.PRODUCTOS', COUNT(*) FROM RAW.PRODUCTOS
UNION ALL SELECT 'RAW.CLIENTES', COUNT(*) FROM RAW.CLIENTES
UNION ALL SELECT 'RAW.TRANSACCIONES', COUNT(*) FROM RAW.TRANSACCIONES
UNION ALL SELECT 'RAW.MOVIMIENTOS', COUNT(*) FROM RAW.MOVIMIENTOS
UNION ALL SELECT 'RAW.SALDOS', COUNT(*) FROM RAW.SALDOS
ORDER BY tabla;
```

| Tabla | Filas |
|-------|-------|
| CLIENTES | 500,000 |
| MOVIMIENTOS | 10,000,000 |
| PRODUCTOS | 5,000 |
| SALDOS | 8,000,000 |
| SUCURSALES | 200 |
| TRANSACCIONES | 50,000,000 |

:::note Tiempo de generacion
Con un warehouse Medium, las 50M de transacciones tardan ~3 minutos. Las demas tablas se generan en segundos.
:::
