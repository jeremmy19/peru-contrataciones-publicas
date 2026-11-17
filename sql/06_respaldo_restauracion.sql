/* ============================================================================
   06_respaldo_restauracion.sql
   Respaldo completo, verificacion, restauracion como copia y comparacion.

   Requisitos: carpeta C:\datos_oece\ (o cambiar la ruta) con permisos de
   escritura para la cuenta del servicio de SQL Server, y ~5 GB libres para
   la copia restaurada.
   ============================================================================ */
USE master;
GO

-- 1. Respaldo completo con verificacion de integridad (CHECKSUM)
BACKUP DATABASE ContratacionesPE
TO DISK = 'C:\datos_oece\ContratacionesPE_full.bak'
WITH COMPRESSION, CHECKSUM, INIT, STATS = 10;
GO

-- 2. Verificar que el archivo es legible
RESTORE VERIFYONLY FROM DISK = 'C:\datos_oece\ContratacionesPE_full.bak' WITH CHECKSUM;
GO

-- 3. Nombres logicos de los archivos
RESTORE FILELISTONLY FROM DISK = 'C:\datos_oece\ContratacionesPE_full.bak';
GO

-- 4. Restaurar como copia con otro nombre (no toca la base original)
DECLARE @dir    NVARCHAR(260) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(260));
DECLARE @logdir NVARCHAR(260) = CAST(SERVERPROPERTY('InstanceDefaultLogPath')  AS NVARCHAR(260));
DECLARE @sql NVARCHAR(MAX) = N'
RESTORE DATABASE ContratacionesPE_restore
FROM DISK = ''C:\datos_oece\ContratacionesPE_full.bak''
WITH MOVE ''ContratacionesPE''     TO ''' + @dir    + N'ContratacionesPE_restore.mdf'',
     MOVE ''ContratacionesPE_log'' TO ''' + @logdir + N'ContratacionesPE_restore_log.ldf'',
     STATS = 10;';
EXEC sys.sp_executesql @sql;
GO

-- 5. Comprobar que la copia es identica a la original
SELECT o.metrica, o.valor AS original, r.valor AS restaurada,
       CASE WHEN o.valor = r.valor THEN 'OK' ELSE 'DIFERENTE' END AS estado
FROM ContratacionesPE.etl.v_metricas o
JOIN ContratacionesPE_restore.etl.v_metricas r ON r.metrica = o.metrica
ORDER BY estado DESC, o.metrica;
GO

-- 6. Limpiar la copia de prueba
-- USE master;
-- DROP DATABASE ContratacionesPE_restore;
