-- ======================================================================
-- PRIMUS CAPITAL POC — Módulo 1: Generación de datos sintéticos
-- Genera ~70M filas que simulan la volumetría del cliente.
-- Ejecutar con PRIMUS_ETL_WH (Medium) — tarda ~2-5 minutos.

USE DATABASE PRIMUS_POC;
USE SCHEMA RAW;
USE WAREHOUSE PRIMUS_ETL_WH;

-- ======================================================================
-- ## DIMENSIONES
-- 
-- Sucursales (200 filas)

CREATE OR REPLACE TABLE RAW.SUCURSALES AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4()) AS sucursal_id,
    'SUC-' || LPAD(ROW_NUMBER() OVER (ORDER BY SEQ4()), 4, '0') AS codigo,
    CASE MOD(SEQ4(), 10)
        WHEN 0 THEN 'Providencia' WHEN 1 THEN 'Las Condes' WHEN 2 THEN 'Santiago Centro'
        WHEN 3 THEN 'Vitacura'    WHEN 4 THEN 'Ñuñoa'      WHEN 5 THEN 'La Florida'
        WHEN 6 THEN 'Maipú'       WHEN 7 THEN 'Puente Alto' WHEN 8 THEN 'Valparaíso'
        WHEN 9 THEN 'Concepción'
    END AS comuna,
    CASE WHEN MOD(SEQ4(), 10) IN (0,1,3) THEN 'Región Metropolitana'
         WHEN MOD(SEQ4(), 10) = 8 THEN 'Valparaíso'
         WHEN MOD(SEQ4(), 10) = 9 THEN 'Biobío'
         ELSE 'Región Metropolitana'
    END AS region,
    DATEADD('day', -UNIFORM(365, 3650, RANDOM()), CURRENT_DATE()) AS fecha_apertura,
    CASE MOD(SEQ4(), 3) WHEN 0 THEN 'Grande' WHEN 1 THEN 'Mediana' ELSE 'Pequeña' END AS categoria
FROM TABLE(GENERATOR(ROWCOUNT => 200));

-- Productos financieros (5000 filas)
CREATE OR REPLACE TABLE RAW.PRODUCTOS AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4()) AS producto_id,
    'PRD-' || LPAD(ROW_NUMBER() OVER (ORDER BY SEQ4()), 6, '0') AS codigo,
    CASE MOD(SEQ4(), 8)
        WHEN 0 THEN 'Cuenta Corriente' WHEN 1 THEN 'Cuenta Ahorro' WHEN 2 THEN 'Depósito a Plazo'
        WHEN 3 THEN 'Fondo Mutuo'      WHEN 4 THEN 'Crédito Consumo' WHEN 5 THEN 'Crédito Hipotecario'
        WHEN 6 THEN 'Tarjeta Crédito'  WHEN 7 THEN 'Línea de Crédito'
    END AS tipo,
    CASE MOD(SEQ4(), 4) WHEN 0 THEN 'Personas' WHEN 1 THEN 'Empresas' WHEN 2 THEN 'Premium' ELSE 'Personas' END AS segmento,
    ROUND(UNIFORM(0.5, 15.0, RANDOM())::NUMERIC(5,2), 2) AS tasa_anual,
    CASE WHEN MOD(SEQ4(), 8) IN (4,5,7) THEN TRUE ELSE FALSE END AS es_credito,
    TRUE AS activo
FROM TABLE(GENERATOR(ROWCOUNT => 5000));

-- Clientes (500K filas)
CREATE OR REPLACE TABLE RAW.CLIENTES AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4()) AS client_id,
    -- RUT chileno simulado: XX.XXX.XXX-D
    LPAD(UNIFORM(5, 25, RANDOM())::VARCHAR, 2, '0') || '.' ||
    LPAD(UNIFORM(100, 999, RANDOM())::VARCHAR, 3, '0') || '.' ||
    LPAD(UNIFORM(100, 999, RANDOM())::VARCHAR, 3, '0') || '-' ||
    SUBSTR('0123456789K', UNIFORM(1, 11, RANDOM()), 1) AS rut,
    CASE MOD(SEQ4(), 20)
        WHEN 0 THEN 'María' WHEN 1 THEN 'Juan' WHEN 2 THEN 'Carolina' WHEN 3 THEN 'Roberto'
        WHEN 4 THEN 'Andrea' WHEN 5 THEN 'Felipe' WHEN 6 THEN 'Valentina' WHEN 7 THEN 'Sebastián'
        WHEN 8 THEN 'Catalina' WHEN 9 THEN 'Nicolás' WHEN 10 THEN 'Javiera' WHEN 11 THEN 'Diego'
        WHEN 12 THEN 'Francisca' WHEN 13 THEN 'Matías' WHEN 14 THEN 'Constanza' WHEN 15 THEN 'Tomás'
        WHEN 16 THEN 'Camila' WHEN 17 THEN 'Ignacio' WHEN 18 THEN 'Josefa' ELSE 'Fernando'
    END AS nombre,
    CASE MOD(SEQ4(), 15)
        WHEN 0 THEN 'González' WHEN 1 THEN 'Muñoz' WHEN 2 THEN 'Rojas' WHEN 3 THEN 'Díaz'
        WHEN 4 THEN 'Pérez' WHEN 5 THEN 'Soto' WHEN 6 THEN 'Contreras' WHEN 7 THEN 'Silva'
        WHEN 8 THEN 'Martínez' WHEN 9 THEN 'Sepúlveda' WHEN 10 THEN 'Morales' WHEN 11 THEN 'Rodríguez'
        WHEN 12 THEN 'López' WHEN 13 THEN 'Fuentes' ELSE 'Hernández'
    END AS apellido,
    LOWER(nombre) || '.' || LOWER(apellido) || UNIFORM(1, 9999, RANDOM())::VARCHAR || '@'
        || CASE MOD(SEQ4(), 5)
            WHEN 0 THEN 'gmail.com' WHEN 1 THEN 'hotmail.com' WHEN 2 THEN 'yahoo.cl'
            WHEN 3 THEN 'outlook.com' ELSE 'empresa.cl'
        END AS email,
    '+569' || LPAD(UNIFORM(10000000, 99999999, RANDOM())::VARCHAR, 8, '0') AS telefono,
    'Calle ' || UNIFORM(1, 9999, RANDOM())::VARCHAR || ', ' ||
        CASE MOD(SEQ4(), 10)
            WHEN 0 THEN 'Providencia' WHEN 1 THEN 'Las Condes' WHEN 2 THEN 'Santiago'
            WHEN 3 THEN 'Vitacura'    WHEN 4 THEN 'Ñuñoa'      WHEN 5 THEN 'La Florida'
            WHEN 6 THEN 'Maipú'       WHEN 7 THEN 'Puente Alto' WHEN 8 THEN 'Valparaíso'
            ELSE 'Concepción'
        END AS direccion,
    DATEADD('day', -UNIFORM(0, 2500, RANDOM()), CURRENT_DATE()) AS fecha_registro,
    CASE MOD(SEQ4(), 4) WHEN 0 THEN 'Standard' WHEN 1 THEN 'Premium' WHEN 2 THEN 'VIP' ELSE 'Standard' END AS segmento,
    UNIFORM(1, 200, RANDOM()) AS sucursal_id,
    FALSE AS pseudonymized,
    NULL::TIMESTAMP_LTZ AS pseudonymized_at
FROM TABLE(GENERATOR(ROWCOUNT => 500000));

-- ======================================================================
-- TABLAS DE HECHOS (volumen para benchmarks)
-- 
-- Transacciones: 50M filas (tabla más grande — simula la de 79 GB)

CREATE OR REPLACE TABLE RAW.TRANSACCIONES AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ8()) AS txn_id,
    UNIFORM(1, 500000, RANDOM()) AS client_id,
    UNIFORM(1, 5000, RANDOM()) AS producto_id,
    UNIFORM(1, 200, RANDOM()) AS sucursal_id,
    DATEADD('second',
        -UNIFORM(0, 157680000, RANDOM()),  -- últimos 5 años en segundos
        CURRENT_TIMESTAMP()
    )::TIMESTAMP_NTZ AS fecha,
    CASE MOD(SEQ8(), 6)
        WHEN 0 THEN 'Depósito'      WHEN 1 THEN 'Retiro'
        WHEN 2 THEN 'Transferencia' WHEN 3 THEN 'Pago'
        WHEN 4 THEN 'Inversión'     ELSE 'Comisión'
    END AS tipo,
    ROUND(
        CASE MOD(SEQ8(), 6)
            WHEN 0 THEN UNIFORM(10000, 5000000, RANDOM())
            WHEN 1 THEN -UNIFORM(5000, 2000000, RANDOM())
            WHEN 2 THEN UNIFORM(1000, 10000000, RANDOM()) * (CASE WHEN RANDOM() > 0 THEN 1 ELSE -1 END)
            WHEN 3 THEN -UNIFORM(500, 500000, RANDOM())
            WHEN 4 THEN UNIFORM(100000, 50000000, RANDOM())
            ELSE -UNIFORM(100, 50000, RANDOM())
        END, 2
    ) AS monto,
    CASE MOD(SEQ8(), 3) WHEN 0 THEN 'CLP' WHEN 1 THEN 'CLP' ELSE 'USD' END AS moneda,
    CASE MOD(SEQ8(), 4) WHEN 0 THEN 'Aprobada' WHEN 1 THEN 'Aprobada' WHEN 2 THEN 'Aprobada' ELSE 'Rechazada' END AS estado,
    'CH-' || LPAD(UNIFORM(1, 999999, RANDOM())::VARCHAR, 8, '0') AS referencia
FROM TABLE(GENERATOR(ROWCOUNT => 50000000));

-- Movimientos diarios: 10M filas (segunda tabla grande)
CREATE OR REPLACE TABLE RAW.MOVIMIENTOS AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ8()) AS movimiento_id,
    UNIFORM(1, 500000, RANDOM()) AS client_id,
    UNIFORM(1, 5000, RANDOM()) AS producto_id,
    UNIFORM(1, 200, RANDOM()) AS sucursal_id,
    DATEADD('day', -UNIFORM(0, 1825, RANDOM()), CURRENT_DATE()) AS fecha,
    CASE MOD(SEQ8(), 5)
        WHEN 0 THEN 'Cargo' WHEN 1 THEN 'Abono' WHEN 2 THEN 'Ajuste'
        WHEN 3 THEN 'Interés' ELSE 'Comisión'
    END AS tipo_movimiento,
    ROUND(UNIFORM(100, 10000000, RANDOM()), 2) AS monto,
    ROUND(UNIFORM(0, 100000000, RANDOM()), 2) AS saldo_posterior,
    'MOV-' || LPAD(UNIFORM(1, 99999999, RANDOM())::VARCHAR, 10, '0') AS referencia
FROM TABLE(GENERATOR(ROWCOUNT => 10000000));

-- Saldos históricos: 8M filas (tercera tabla grande)
CREATE OR REPLACE TABLE RAW.SALDOS AS
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ8()) AS saldo_id,
    UNIFORM(1, 500000, RANDOM()) AS client_id,
    UNIFORM(1, 5000, RANDOM()) AS producto_id,
    DATEADD('day', -UNIFORM(0, 1825, RANDOM()), CURRENT_DATE()) AS fecha_corte,
    ROUND(UNIFORM(-5000000, 500000000, RANDOM()), 2) AS saldo_contable,
    ROUND(UNIFORM(-5000000, 500000000, RANDOM()), 2) AS saldo_disponible,
    ROUND(UNIFORM(0, 100000000, RANDOM()), 2) AS saldo_promedio_mes,
    CASE MOD(SEQ8(), 3) WHEN 0 THEN 'Activa' WHEN 1 THEN 'Activa' ELSE 'Inactiva' END AS estado_cuenta
FROM TABLE(GENERATOR(ROWCOUNT => 8000000));

-- ======================================================================
-- ## VERIFICACIÓN

SELECT 'RAW.SUCURSALES' AS tabla, COUNT(*) AS filas FROM RAW.SUCURSALES
UNION ALL SELECT 'RAW.PRODUCTOS', COUNT(*) FROM RAW.PRODUCTOS
UNION ALL SELECT 'RAW.CLIENTES', COUNT(*) FROM RAW.CLIENTES
UNION ALL SELECT 'RAW.TRANSACCIONES', COUNT(*) FROM RAW.TRANSACCIONES
UNION ALL SELECT 'RAW.MOVIMIENTOS', COUNT(*) FROM RAW.MOVIMIENTOS
UNION ALL SELECT 'RAW.SALDOS', COUNT(*) FROM RAW.SALDOS
ORDER BY tabla;
