/* ============================================================================
   03_validacion_metricas.sql
   Verifica que el pipeline reproduce siempre el mismo resultado.

   Como usarlo:
     1. Ejecutar 02_pipeline_etl.sql y luego  EXEC etl.sp_ejecutar_pipeline;
     2. Ejecutar la seccion A (crea la vista) y la B (toma la "foto" baseline).
     3. Para probar reproducibilidad: borrar stg/core/dw, volver a ejecutar el
        pipeline y ejecutar la seccion C. Todas las filas deben dar OK.
   ============================================================================ */
USE ContratacionesPE;
GO

-- ===== A. Vista de metricas =====
CREATE OR ALTER VIEW etl.v_metricas AS
SELECT CAST('stg.main' AS NVARCHAR(100)) AS metrica, CAST(COUNT(*) AS DECIMAL(24,2)) AS valor FROM stg.main
UNION ALL SELECT 'stg.parties', COUNT(*) FROM stg.parties
UNION ALL SELECT 'stg.tender_tenderers', COUNT(*) FROM stg.tender_tenderers
UNION ALL SELECT 'stg.awards', COUNT(*) FROM stg.awards
UNION ALL SELECT 'stg.awards_suppliers', COUNT(*) FROM stg.awards_suppliers
UNION ALL SELECT 'stg.contracts', COUNT(*) FROM stg.contracts
UNION ALL SELECT 'stg.tender_items', COUNT(*) FROM stg.tender_items
UNION ALL SELECT 'stg.awards_fx', COUNT(*) FROM stg.awards_value_exchangeRates
UNION ALL SELECT 'stg.contracts_fx', COUNT(*) FROM stg.contracts_value_exchangeRates
UNION ALL SELECT 'core.entidad', COUNT(*) FROM core.entidad
UNION ALL SELECT 'core.proveedor', COUNT(*) FROM core.proveedor
UNION ALL SELECT 'core.proceso', COUNT(*) FROM core.proceso
UNION ALL SELECT 'core.postor', COUNT(*) FROM core.postor
UNION ALL SELECT 'core.adjudicacion', COUNT(*) FROM core.adjudicacion
UNION ALL SELECT 'core.contrato', COUNT(*) FROM core.contrato
UNION ALL SELECT 'core.item', COUNT(*) FROM core.item
UNION ALL SELECT 'dw.fact_proceso', COUNT(*) FROM dw.fact_proceso
UNION ALL SELECT 'dw.fact_adjudicacion', COUNT(*) FROM dw.fact_adjudicacion
UNION ALL SELECT 'dw.dim_fecha', COUNT(*) FROM dw.dim_fecha
UNION ALL SELECT 'suma monto_referencial_pen', SUM(monto_referencial_pen) FROM core.proceso
UNION ALL SELECT 'suma adjudicacion monto_pen', SUM(monto_pen) FROM core.adjudicacion
UNION ALL SELECT 'suma contrato monto_pen', SUM(monto_pen) FROM core.contrato
UNION ALL SELECT 'suma contrato monto_final_pen', SUM(monto_final_pen) FROM core.contrato
UNION ALL SELECT 'adjudicaciones pen_inferido', SUM(CAST(pen_inferido AS INT)) FROM core.adjudicacion
UNION ALL SELECT 'contratos pen_inferido', SUM(CAST(pen_inferido AS INT)) FROM core.contrato
UNION ALL SELECT 'proveedores sin nombre', COUNT(*) FROM core.proveedor WHERE nombre = 'Sin nombre en la fuente'
UNION ALL SELECT 'adj sin proveedor', COUNT(*) FROM core.adjudicacion WHERE proveedor_id IS NULL
UNION ALL SELECT 'con sin proveedor', COUNT(*) FROM core.contrato WHERE proveedor_id IS NULL
UNION ALL SELECT 'fact proxy_desierto', SUM(CAST(proxy_desierto AS INT)) FROM dw.fact_proceso
UNION ALL SELECT 'fact en_curso', SUM(CAST(en_curso AS INT)) FROM dw.fact_proceso
UNION ALL SELECT 'fact un_solo_postor', SUM(CAST(un_solo_postor AS INT)) FROM dw.fact_proceso
UNION ALL SELECT 'fact firma_fuera_rango', SUM(CAST(firma_fuera_rango AS INT)) FROM dw.fact_proceso
UNION ALL SELECT 'fact suma monto_adjudicado_pen', SUM(monto_adjudicado_pen) FROM dw.fact_proceso
UNION ALL SELECT 'checksum proceso', CHECKSUM_AGG(CHECKSUM(ocid, monto_referencial_pen, fecha_publicacion)) FROM core.proceso
UNION ALL SELECT 'checksum entidad', CHECKSUM_AGG(CHECKSUM(entidad_key, nombre, departamento)) FROM core.entidad
UNION ALL SELECT 'checksum proveedor', CHECKSUM_AGG(CHECKSUM(proveedor_key, nombre)) FROM core.proveedor
UNION ALL SELECT 'checksum adjudicacion', CHECKSUM_AGG(CHECKSUM(p.ocid, a.award_key, a.monto_pen))
  FROM core.adjudicacion a JOIN core.proceso p ON p.proceso_id = a.proceso_id
UNION ALL SELECT 'checksum contrato', CHECKSUM_AGG(CHECKSUM(p.ocid, c.contrato_key, c.monto_pen, c.monto_final_pen))
  FROM core.contrato c JOIN core.proceso p ON p.proceso_id = c.proceso_id;
GO

-- ===== B. Foto del estado actual (baseline) =====
DROP TABLE IF EXISTS etl.baseline;
SELECT metrica, valor INTO etl.baseline FROM etl.v_metricas;
GO
SELECT * FROM etl.baseline;
GO

-- ===== C. Comparacion contra la foto (ejecutar despues de reconstruir) =====
SELECT b.metrica, b.valor AS antes, v.valor AS despues,
       CASE WHEN b.valor = v.valor THEN 'OK' ELSE 'DIFERENTE' END AS estado
FROM etl.baseline b
LEFT JOIN etl.v_metricas v ON v.metrica = b.metrica
ORDER BY estado DESC, b.metrica;
GO
