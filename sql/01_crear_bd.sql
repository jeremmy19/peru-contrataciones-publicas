/* ============================================================================
   01_crear_bd.sql
   Crea la base de datos ContratacionesPE y los esquemas del proyecto.

   Esquemas:
     stg   staging: copia fiel de los CSV (todo texto)
     core  modelo normalizado (tipos reales, llaves PK/FK)
     dw    modelo estrella (dimensiones y hechos) para Power BI
     etl   bitacora, vista de metricas y procedimientos del pipeline

   ============================================================================ */
USE master;
GO
IF DB_ID('ContratacionesPE') IS NULL
    CREATE DATABASE ContratacionesPE;
GO

-- Entorno de desarrollo: el log no crece sin control durante las cargas masivas.
-- En produccion se mantendria FULL con respaldos de log periodicos.
ALTER DATABASE ContratacionesPE SET RECOVERY SIMPLE;
GO

USE ContratacionesPE;
GO
IF SCHEMA_ID('stg')  IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('core') IS NULL EXEC('CREATE SCHEMA core');
IF SCHEMA_ID('dw')   IS NULL EXEC('CREATE SCHEMA dw');
IF SCHEMA_ID('etl')  IS NULL EXEC('CREATE SCHEMA etl');
GO
