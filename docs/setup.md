---
sidebar_position: 2
---

# Setup

<a href="/mssqltosnowflake-migration-hol/downloads/00_setup.sql" download="00_setup.sql" class="button button--primary button--sm" style={{marginBottom: "1.5rem", display: "inline-block"}}>Descargar 00_setup.sql</a>


Crear la infraestructura base: database, schemas, warehouses con auto-suspend, y roles con separacion de privilegios.

## Por que importa

En plataformas tradicionales el servidor esta prendido 24/7. En Snowflake, el compute se apaga solo cuando nadie lo usa (`AUTO_SUSPEND = 60` segundos) y se prende solo cuando llega una query (`AUTO_RESUME = TRUE`). Solo pagan por lo que usan.

## Database y schemas

```sql
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS SNOWFLAKE_POC;
CREATE SCHEMA IF NOT EXISTS SNOWFLAKE_POC.RAW;
CREATE SCHEMA IF NOT EXISTS SNOWFLAKE_POC.DWH;
CREATE SCHEMA IF NOT EXISTS SNOWFLAKE_POC.COMPLIANCE;
CREATE SCHEMA IF NOT EXISTS SNOWFLAKE_POC.SANDBOX;
```

## Warehouses

Dos warehouses separados para aislar workloads de ETL y queries BI:

```sql
CREATE WAREHOUSE IF NOT EXISTS ETL_WH
    WAREHOUSE_SIZE = 'MEDIUM'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'ETL y transformaciones — Medium para paralelizacion';

CREATE WAREHOUSE IF NOT EXISTS ANALYTICS_WH
    WAREHOUSE_SIZE = 'SMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Queries BI — Small para 100 viewers Power BI + Qlik';
```

:::info Medium = 4 creditos/hora
Un warehouse Medium equivale a ~8 cores. Se prende en ~1 segundo y se apaga solo despues de 60 segundos de inactividad. `INITIALLY_SUSPENDED = TRUE` significa que no cobra hasta que alguien lo use.
:::

## Roles

Tres roles con separacion clara de privilegios:

```sql
CREATE ROLE IF NOT EXISTS ETL_ROLE
    COMMENT = 'Carga y transformacion de datos';
CREATE ROLE IF NOT EXISTS ANALYST_ROLE
    COMMENT = 'Consultas BI — PII enmascarada';
CREATE ROLE IF NOT EXISTS COMPLIANCE_ROLE
    COMMENT = 'Compliance — acceso total a PII, puede pseudonimizar';

-- Jerarquia: SYSADMIN hereda todos los roles
GRANT ROLE ETL_ROLE TO ROLE SYSADMIN;
GRANT ROLE ANALYST_ROLE TO ROLE SYSADMIN;
GRANT ROLE COMPLIANCE_ROLE TO ROLE SYSADMIN;
```

| Rol | Puede cargar datos | Ve PII | Puede pseudonimizar |
|-----|-------------------|--------|-------------------|
| `ETL_ROLE` | Si | No | No |
| `ANALYST_ROLE` | No | No (masking) | No |
| `COMPLIANCE_ROLE` | No | Si | Si |

Esto es RBAC nativo — no necesitan infraestructura adicional de identity management.

## Siguiente paso

Con la infraestructura lista, el siguiente paso es [generar los datos sinteticos](datos-sinteticos) que simulan la volumetria del cliente.
