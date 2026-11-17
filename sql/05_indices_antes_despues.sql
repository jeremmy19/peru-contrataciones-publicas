/* ============================================================================
   05_indices_antes_despues.sql
   Mide el efecto de los indices de rendimiento sobre consultas de busqueda.

   El pipeline (02) ya crea los indices al final. Este script permite medir:
     PASO 1  quitar los indices            -> estado "antes"
     PASO 2  ejecutar el bloque de medicion (guardar pestana Mensajes: antes.txt)
     PASO 3  crear los indices             -> estado "despues"
     PASO 4  ejecutar de nuevo el bloque de medicion (despues.txt)

   Metricas a anotar por consulta (pestana Mensajes):
     - logical reads (sumar todas las tablas)
     - elapsed time
   Activar tambien el plan de ejecucion real (Ctrl+M): Scan antes, Seek despues.
   ============================================================================ */
USE ContratacionesPE;
GO

-- ===== PASO 1: quitar indices (estado "antes") =====
DROP INDEX IF EXISTS IX_postor_proveedor              ON core.postor;
DROP INDEX IF EXISTS IX_adjudicacion_proveedor_fecha  ON core.adjudicacion;
DROP INDEX IF EXISTS IX_adjudicacion_proceso          ON core.adjudicacion;
DROP INDEX IF EXISTS IX_proceso_entidad_fecha         ON core.proceso;
DROP INDEX IF EXISTS IX_item_proceso                  ON core.item;
DROP INDEX IF EXISTS IX_contrato_proceso              ON core.contrato;
GO
EXEC sp_spaceused;
GO

-- ===== Preparacion de parametros de prueba (no se mide) =====
DROP TABLE IF EXISTS #p;
SELECT
  (SELECT TOP 1 proveedor_id FROM core.postor GROUP BY proveedor_id ORDER BY COUNT(*) DESC) AS prov,
  (SELECT TOP 1 entidad_id FROM core.proceso GROUP BY entidad_id ORDER BY COUNT(*) DESC)   AS ent
INTO #p;
SELECT * FROM #p;
GO

-- ===== PASOS 2 y 4: BLOQUE DE MEDICION (ejecutar antes y despues de los indices) =====
CHECKPOINT; DBCC DROPCLEANBUFFERS; DBCC FREEPROCCACHE;
GO
SET STATISTICS TIME ON; SET STATISTICS IO ON;
GO
DECLARE @prov INT = (SELECT prov FROM #p), @ent INT = (SELECT ent FROM #p);

PRINT '--- Q1: historial de participacion de un proveedor ---';
SELECT p.proceso_id, p.fecha_publicacion, p.monto_referencial_pen, e.nombre
FROM core.postor po
JOIN core.proceso p ON p.proceso_id = po.proceso_id
JOIN core.entidad e ON e.entidad_id = p.entidad_id
WHERE po.proveedor_id = @prov
ORDER BY p.fecha_publicacion DESC
OPTION (RECOMPILE);

PRINT '--- Q2: adjudicaciones ganadas por un proveedor en 2025 ---';
SELECT COUNT(*) AS ganadas, SUM(monto_pen) AS monto
FROM core.adjudicacion
WHERE proveedor_id = @prov AND fecha_adjudicacion >= '2025-01-01'
OPTION (RECOMPILE);

PRINT '--- Q3: procesos de una entidad en el primer semestre 2025 ---';
SELECT COUNT(*) AS procesos, SUM(monto_referencial_pen) AS monto
FROM core.proceso
WHERE entidad_id = @ent AND fecha_publicacion >= '2025-01-01' AND fecha_publicacion < '2025-07-01'
OPTION (RECOMPILE);

PRINT '--- Q4: items por clasificacion de una entidad ---';
SELECT TOP 20 i.clasificacion_desc, COUNT(*) AS items, SUM(i.monto_pen) AS monto
FROM core.proceso p
JOIN core.item i ON i.proceso_id = p.proceso_id
WHERE p.entidad_id = @ent
GROUP BY i.clasificacion_desc
ORDER BY monto DESC
OPTION (RECOMPILE);

PRINT '--- Q5: ranking global de proveedores (recorre todo; el indice casi no ayuda) ---';
WITH part AS (SELECT proveedor_id, COUNT(*) AS n FROM core.postor GROUP BY proveedor_id),
     gan  AS (SELECT proveedor_id, COUNT(DISTINCT proceso_id) AS g FROM core.adjudicacion
              WHERE proveedor_id IS NOT NULL GROUP BY proveedor_id)
SELECT TOP 20 part.proveedor_id, part.n AS participaciones, ISNULL(gan.g,0) AS ganadas,
       CAST(ISNULL(gan.g,0) * 100.0 / part.n AS DECIMAL(5,2)) AS pct_exito,
       RANK() OVER (ORDER BY part.n DESC) AS ranking
FROM part LEFT JOIN gan ON gan.proveedor_id = part.proveedor_id
ORDER BY part.n DESC
OPTION (RECOMPILE);
GO
SET STATISTICS TIME OFF; SET STATISTICS IO OFF;
GO

-- ===== Prueba sintetica opcional: 200 ejecuciones seguidas =====
DECLARE @i INT = 0, @t DATETIME2 = SYSDATETIME(), @prov INT = (SELECT prov FROM #p), @x INT;
WHILE @i < 200
BEGIN
  SELECT @x = COUNT(*) FROM core.adjudicacion
  WHERE proveedor_id = @prov AND fecha_adjudicacion >= '2025-01-01';
  SET @i += 1;
END
SELECT DATEDIFF(MILLISECOND, @t, SYSDATETIME()) AS ms_200_ejecuciones;
GO

-- ===== PASO 3: crear indices (estado "despues") =====
CREATE NONCLUSTERED INDEX IX_postor_proveedor
  ON core.postor (proveedor_id);
CREATE NONCLUSTERED INDEX IX_adjudicacion_proveedor_fecha
  ON core.adjudicacion (proveedor_id, fecha_adjudicacion) INCLUDE (monto_pen, proceso_id);
CREATE NONCLUSTERED INDEX IX_adjudicacion_proceso
  ON core.adjudicacion (proceso_id);
CREATE NONCLUSTERED INDEX IX_proceso_entidad_fecha
  ON core.proceso (entidad_id, fecha_publicacion) INCLUDE (monto_referencial_pen);
CREATE NONCLUSTERED INDEX IX_item_proceso
  ON core.item (proceso_id) INCLUDE (clasificacion_desc, monto_pen);
CREATE NONCLUSTERED INDEX IX_contrato_proceso
  ON core.contrato (proceso_id);
GO
UPDATE STATISTICS core.postor; UPDATE STATISTICS core.adjudicacion; UPDATE STATISTICS core.proceso;
UPDATE STATISTICS core.item;   UPDATE STATISTICS core.contrato;
GO
EXEC sp_spaceused;
GO
-- Ejecutar de nuevo el BLOQUE DE MEDICION (paso 4) y comparar.
