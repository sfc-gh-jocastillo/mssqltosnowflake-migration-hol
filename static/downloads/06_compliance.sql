-- ======================================================================
-- PRIMUS CAPITAL POC — Módulo 4: Compliance — Pseudonimización
-- Adapta el flujo de pseudonimización a las tablas reales de la POC.
-- Incluye masking policies por rol y evidencia de ACCESS_HISTORY.

USE DATABASE PRIMUS_POC;
USE SCHEMA COMPLIANCE;
USE WAREHOUSE PRIMUS_ETL_WH;

-- ======================================================================
-- ## 1. TABLAS DE AUDITORÍA

CREATE OR REPLACE TABLE COMPLIANCE.DELETION_REQUESTS (
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
    rows_affected   NUMBER,
    hash_algorithm  VARCHAR DEFAULT 'SHA2-256',
    notes           VARCHAR,
    CONSTRAINT pk_deletion PRIMARY KEY (request_id)
);

CREATE OR REPLACE TABLE COMPLIANCE.DELETION_LOG (
    log_id          NUMBER AUTOINCREMENT,
    request_id      NUMBER NOT NULL,
    table_name      VARCHAR NOT NULL,
    rows_updated    NUMBER,
    columns_hashed  ARRAY,
    executed_at     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    executed_by     VARCHAR DEFAULT CURRENT_USER()
);

-- ======================================================================
-- ## 2. STORED PROCEDURE DE PSEUDONIMIZACIÓN

CREATE OR REPLACE PROCEDURE COMPLIANCE.PROCESS_DELETION_REQUEST(
    P_REQUEST_ID NUMBER
)
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_user_id NUMBER;
    v_salt VARCHAR;
    v_status VARCHAR;
    v_rows_clientes NUMBER DEFAULT 0;
    v_rows_txn NUMBER DEFAULT 0;
    v_total_rows NUMBER DEFAULT 0;
BEGIN
    SELECT user_id, status
    INTO :v_user_id, :v_status
    FROM COMPLIANCE.DELETION_REQUESTS
    WHERE request_id = :P_REQUEST_ID;

    IF (:v_status != 'PENDING') THEN
        RETURN 'ERROR: Solicitud ' || :P_REQUEST_ID || ' tiene status "' || :v_status || '"';
    END IF;

    v_salt := RANDSTR(32, RANDOM());

    UPDATE COMPLIANCE.DELETION_REQUESTS
    SET status = 'PROCESSING'
    WHERE request_id = :P_REQUEST_ID;

    -- Pseudonimizar DIM_CLIENTES
    UPDATE PRIMUS_POC.DWH.DIM_CLIENTES
    SET nombre          = LEFT(SHA2(nombre || :v_salt, 256), 8),
        apellido        = LEFT(SHA2(apellido || :v_salt, 256), 8),
        nombre_completo = LEFT(SHA2(nombre_completo || :v_salt, 256), 8),
        email           = LEFT(SHA2(email || :v_salt, 256), 8) || '@del.local',
        rut             = LEFT(SHA2(rut || :v_salt, 256), 8),
        telefono        = LEFT(SHA2(telefono || :v_salt, 256), 8),
        direccion       = LEFT(SHA2(direccion || :v_salt, 256), 8),
        pseudonymized   = TRUE,
        pseudonymized_at = CURRENT_TIMESTAMP()
    WHERE client_id = :v_user_id;

    v_rows_clientes := SQLROWCOUNT;

    INSERT INTO COMPLIANCE.DELETION_LOG (request_id, table_name, rows_updated, columns_hashed)
    VALUES (:P_REQUEST_ID, 'DWH.DIM_CLIENTES', :v_rows_clientes,
            ARRAY_CONSTRUCT('nombre','apellido','nombre_completo','email','rut','telefono','direccion'));

    -- Pseudonimizar RAW.CLIENTES (fuente)
    UPDATE PRIMUS_POC.RAW.CLIENTES
    SET nombre    = LEFT(SHA2(nombre || :v_salt, 256), 8),
        apellido  = LEFT(SHA2(apellido || :v_salt, 256), 8),
        email     = LEFT(SHA2(email || :v_salt, 256), 8) || '@del.local',
        rut       = LEFT(SHA2(rut || :v_salt, 256), 8),
        telefono  = LEFT(SHA2(telefono || :v_salt, 256), 8),
        direccion = LEFT(SHA2(direccion || :v_salt, 256), 8),
        pseudonymized = TRUE,
        pseudonymized_at = CURRENT_TIMESTAMP()
    WHERE client_id = :v_user_id;

    v_rows_clientes := :v_rows_clientes + SQLROWCOUNT;

    INSERT INTO COMPLIANCE.DELETION_LOG (request_id, table_name, rows_updated, columns_hashed)
    VALUES (:P_REQUEST_ID, 'RAW.CLIENTES', SQLROWCOUNT,
            ARRAY_CONSTRUCT('nombre','apellido','email','rut','telefono','direccion'));

    -- Marcar solicitud como completada
    v_total_rows := :v_rows_clientes + :v_rows_txn;

    UPDATE COMPLIANCE.DELETION_REQUESTS
    SET status          = 'COMPLETED',
        processed_at    = CURRENT_TIMESTAMP(),
        processed_by    = CURRENT_USER(),
        tables_affected = ARRAY_CONSTRUCT('DWH.DIM_CLIENTES', 'RAW.CLIENTES'),
        rows_affected   = :v_total_rows
    WHERE request_id = :P_REQUEST_ID;

    RETURN 'OK: Usuario ' || :v_user_id || ' pseudonimizado. ' || :v_total_rows || ' filas afectadas.';

EXCEPTION
    WHEN OTHER THEN
        UPDATE COMPLIANCE.DELETION_REQUESTS
        SET status = 'FAILED', notes = SQLERRM
        WHERE request_id = :P_REQUEST_ID;
        RETURN 'ERROR: ' || SQLERRM;
END;

-- Vista de auditoría
CREATE OR REPLACE VIEW COMPLIANCE.V_DELETION_AUDIT AS
SELECT
    dr.request_id,
    dr.user_id,
    dr.user_identifier,
    dr.request_source,
    dr.reason,
    dr.requested_at,
    dr.processed_at,
    DATEDIFF('second', dr.requested_at, dr.processed_at) AS seconds_to_process,
    dr.status,
    dr.processed_by,
    dr.tables_affected,
    dr.rows_affected,
    dl.table_name,
    dl.rows_updated,
    dl.columns_hashed
FROM COMPLIANCE.DELETION_REQUESTS dr
LEFT JOIN COMPLIANCE.DELETION_LOG dl ON dr.request_id = dl.request_id
ORDER BY dr.requested_at DESC;

-- ======================================================================
-- ## 3. MASKING POLICIES POR ROL
-- 
-- Masking para RUT

CREATE OR REPLACE MASKING POLICY COMPLIANCE.MASK_RUT AS (val VARCHAR)
RETURNS VARCHAR ->
    CASE
        WHEN CURRENT_ROLE() IN ('PRIMUS_COMPLIANCE_ROLE', 'ACCOUNTADMIN', 'SYSADMIN') THEN val
        ELSE '**.***.***-*'
    END;

-- Masking para email
CREATE OR REPLACE MASKING POLICY COMPLIANCE.MASK_EMAIL AS (val VARCHAR)
RETURNS VARCHAR ->
    CASE
        WHEN CURRENT_ROLE() IN ('PRIMUS_COMPLIANCE_ROLE', 'ACCOUNTADMIN', 'SYSADMIN') THEN val
        ELSE '***@masked.local'
    END;

-- Masking para teléfono
CREATE OR REPLACE MASKING POLICY COMPLIANCE.MASK_TELEFONO AS (val VARCHAR)
RETURNS VARCHAR ->
    CASE
        WHEN CURRENT_ROLE() IN ('PRIMUS_COMPLIANCE_ROLE', 'ACCOUNTADMIN', 'SYSADMIN') THEN val
        ELSE '+569*****' || RIGHT(val, 3)
    END;

-- Masking para nombre
CREATE OR REPLACE MASKING POLICY COMPLIANCE.MASK_NOMBRE AS (val VARCHAR)
RETURNS VARCHAR ->
    CASE
        WHEN CURRENT_ROLE() IN ('PRIMUS_COMPLIANCE_ROLE', 'ACCOUNTADMIN', 'SYSADMIN') THEN val
        ELSE '***'
    END;

-- Aplicar policies a DIM_CLIENTES
ALTER TABLE DWH.DIM_CLIENTES MODIFY COLUMN rut SET MASKING POLICY COMPLIANCE.MASK_RUT;
ALTER TABLE DWH.DIM_CLIENTES MODIFY COLUMN email SET MASKING POLICY COMPLIANCE.MASK_EMAIL;
ALTER TABLE DWH.DIM_CLIENTES MODIFY COLUMN telefono SET MASKING POLICY COMPLIANCE.MASK_TELEFONO;
ALTER TABLE DWH.DIM_CLIENTES MODIFY COLUMN nombre SET MASKING POLICY COMPLIANCE.MASK_NOMBRE;
ALTER TABLE DWH.DIM_CLIENTES MODIFY COLUMN apellido SET MASKING POLICY COMPLIANCE.MASK_NOMBRE;

-- Grants para la demo de masking
GRANT SELECT ON TABLE DWH.DIM_CLIENTES TO ROLE PRIMUS_ANALYST_ROLE;
GRANT SELECT ON TABLE DWH.DIM_CLIENTES TO ROLE PRIMUS_COMPLIANCE_ROLE;
GRANT SELECT ON TABLE DWH.FACT_TRANSACCIONES TO ROLE PRIMUS_ANALYST_ROLE;

-- ======================================================================
-- ## 4. DEMO END-TO-END
-- 
-- ANTES: ver datos con rol ACCOUNTADMIN (ve todo)

SELECT '=== VISTA CON ROL ADMIN (ve PII) ===' AS demo;
SELECT client_id, rut, nombre, apellido, email, telefono, segmento
FROM DWH.DIM_CLIENTES
WHERE client_id IN (1, 2, 3, 4, 5)
ORDER BY client_id;

-- DEMO MASKING: cambiar a rol analista
USE ROLE PRIMUS_ANALYST_ROLE;
USE WAREHOUSE PRIMUS_ANALYTICS_WH;
USE DATABASE PRIMUS_POC;

SELECT '=== VISTA CON ROL ANALISTA (PII enmascarada) ===' AS demo;
SELECT client_id, rut, nombre, apellido, email, telefono, segmento
FROM DWH.DIM_CLIENTES
WHERE client_id IN (1, 2, 3, 4, 5)
ORDER BY client_id;

-- Volver a admin para la pseudonimización
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE PRIMUS_ETL_WH;

-- Registrar solicitud de eliminación
INSERT INTO COMPLIANCE.DELETION_REQUESTS (user_id, user_identifier, request_source, reason)
VALUES (1, (SELECT rut FROM DWH.DIM_CLIENTES WHERE client_id = 1),
        'web_form', 'Solicitud voluntaria de eliminación de datos personales');

-- Procesar
CALL COMPLIANCE.PROCESS_DELETION_REQUEST(1);

-- DESPUÉS: cliente 1 pseudonimizado
SELECT '=== POST-PSEUDONIMIZACIÓN ===' AS demo;
SELECT client_id, rut, nombre, apellido, email, pseudonymized
FROM DWH.DIM_CLIENTES
WHERE client_id IN (1, 2, 3)
ORDER BY client_id;

-- Reporte de auditoría
SELECT * FROM COMPLIANCE.V_DELETION_AUDIT;

-- Segunda solicitud
INSERT INTO COMPLIANCE.DELETION_REQUESTS (user_id, user_identifier, request_source, reason)
VALUES (100, (SELECT rut FROM DWH.DIM_CLIENTES WHERE client_id = 100),
        'email', 'Cierre de cuenta, solicita eliminación por correo');

CALL COMPLIANCE.PROCESS_DELETION_REQUEST(2);

-- Reporte final con ambas solicitudes
SELECT
    request_id,
    user_id,
    request_source,
    reason,
    status,
    rows_affected,
    processed_at
FROM COMPLIANCE.DELETION_REQUESTS
ORDER BY request_id;

SELECT '=== Módulo 4 completo: masking + pseudonimización + auditoría ===' AS status;
