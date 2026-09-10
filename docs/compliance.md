---
sidebar_position: 8
---

# Compliance: Pseudonimizacion

<a href="/mssqltosnowflake-migration-hol/downloads/06_compliance.sql" download="06_compliance.sql" class="button button--primary button--sm" style={{marginBottom: "1.5rem", display: "inline-block"}}>Descargar 06_compliance.sql</a>


Flujo completo de derecho al olvido (regulacion de proteccion de datos personales): masking policies por rol, pseudonimizacion con hash irreversible, y auditoria.

## Masking dinamico por rol

El mismo SELECT retorna resultados diferentes segun el rol:

```sql
-- Masking para RUT
CREATE OR REPLACE MASKING POLICY COMPLIANCE.MASK_RUT
AS (val VARCHAR) RETURNS VARCHAR ->
    CASE
        WHEN CURRENT_ROLE() IN ('COMPLIANCE_ROLE', 'ACCOUNTADMIN')
            THEN val
        ELSE '**.***.***-*'
    END;

-- Aplicar a la columna
ALTER TABLE DWH.DIM_CLIENTES
    MODIFY COLUMN rut SET MASKING POLICY COMPLIANCE.MASK_RUT;
```

### Demo

```sql
-- Con rol ACCOUNTADMIN: ve todo
SELECT client_id, rut, nombre, email FROM DWH.DIM_CLIENTES LIMIT 5;
-- Resultado: 12.345.678-9 | Maria | maria@email.cl

-- Con rol ANALYST: PII enmascarada
USE ROLE ANALYST_ROLE;
SELECT client_id, rut, nombre, email FROM DWH.DIM_CLIENTES LIMIT 5;
-- Resultado: **.***.***-* | *** | ***@masked.local
```

:::info Mismo query, diferente resultado
El analista nunca ve PII. No necesitan vistas filtradas ni tablas separadas. La policy se aplica a nivel de columna, transparente para el usuario.
:::

## Pseudonimizacion

Cuando un cliente solicita la eliminacion de sus datos, no borramos registros — reemplazamos los campos PII con hashes irreversibles.

### Tabla de auditoria

```sql
CREATE TABLE COMPLIANCE.DELETION_REQUESTS (
    request_id      NUMBER AUTOINCREMENT,
    user_id         NUMBER NOT NULL,
    user_identifier VARCHAR,
    request_source  VARCHAR DEFAULT 'web_form',
    reason          VARCHAR,
    requested_at    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    processed_at    TIMESTAMP_LTZ,
    status          VARCHAR DEFAULT 'PENDING',
    processed_by    VARCHAR,
    tables_affected ARRAY,
    rows_affected   NUMBER
);
```

### Stored procedure

```sql
CREATE OR REPLACE PROCEDURE COMPLIANCE.PROCESS_DELETION_REQUEST(
    P_REQUEST_ID NUMBER
)
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_user_id NUMBER;
    v_salt VARCHAR;
BEGIN
    -- Obtener solicitud pendiente
    SELECT user_id INTO :v_user_id
    FROM COMPLIANCE.DELETION_REQUESTS
    WHERE request_id = :P_REQUEST_ID AND status = 'PENDING';

    -- Salt aleatorio NO ALMACENADO = hash irreversible
    v_salt := RANDSTR(32, RANDOM());

    -- Pseudonimizar campos PII
    UPDATE DWH.DIM_CLIENTES
    SET nombre  = LEFT(SHA2(nombre || :v_salt, 256), 8),
        apellido = LEFT(SHA2(apellido || :v_salt, 256), 8),
        email   = LEFT(SHA2(email || :v_salt, 256), 8) || '@del.local',
        rut     = LEFT(SHA2(rut || :v_salt, 256), 8),
        telefono = LEFT(SHA2(telefono || :v_salt, 256), 8),
        pseudonymized = TRUE,
        pseudonymized_at = CURRENT_TIMESTAMP()
    WHERE client_id = :v_user_id;

    -- Registrar completado
    UPDATE COMPLIANCE.DELETION_REQUESTS
    SET status = 'COMPLETED',
        processed_at = CURRENT_TIMESTAMP(),
        processed_by = CURRENT_USER()
    WHERE request_id = :P_REQUEST_ID;

    RETURN 'OK: Usuario pseudonimizado';
END;
```

### Ejecucion

```sql
-- 1. Registrar solicitud
INSERT INTO COMPLIANCE.DELETION_REQUESTS (user_id, user_identifier, reason)
VALUES (1, '12.345.678-9', 'Solicitud voluntaria de eliminacion');

-- 2. Procesar
CALL COMPLIANCE.PROCESS_DELETION_REQUEST(1);

-- 3. Verificar: PII hasheada, montos intactos
SELECT client_id, rut, nombre, email, pseudonymized
FROM DWH.DIM_CLIENTES WHERE client_id = 1;
```

| Campo | Antes | Despues |
|-------|-------|---------|
| rut | 12.345.678-9 | a4f8c2e1b3d09... |
| nombre | Maria | 7b2e9f4a1c8d3... |
| email | maria@email.cl | 5e1a8c3f7b2d4...@deleted.local |
| segmento | Premium | Premium (no cambia) |
| monto transacciones | 1,500,000 | 1,500,000 (no cambia) |

El salt no se almacena — nadie puede reconstruir el dato original, ni siquiera Snowflake.

## Auditoria para el regulador

```sql
SELECT request_id, user_id, request_source, reason,
       requested_at, processed_at, status, rows_affected
FROM COMPLIANCE.DELETION_REQUESTS
ORDER BY requested_at DESC;
```

## Consideraciones de Time Travel

Los datos originales persisten en Time Travel (1-90 dias en Enterprise). Opciones:
1. Documentar que la pseudonimizacion se completo y Time Travel expirara naturalmente
2. Reducir `DATA_RETENTION_TIME_IN_DAYS` en tablas con PII
3. Fail-safe (7 dias adicionales) solo es accesible por Snowflake Support
