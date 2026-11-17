/* ============================================================================
   exploracion/perfilado_calidad.sql
   Consultas de perfilado (sobre staging) y de calidad (sobre core/dw) que
   sustentan las decisiones de modelado. Solo lectura: no modifica datos.
   Ejecutar despues del pipeline (02).
   ============================================================================ */
USE ContratacionesPE;
GO

/* ============================ A. PERFILADO DE STAGING ===================== */

-- A1. ¿Se repiten procesos? (ocid e id unicos; tender_id se repite en algunos casos)
SELECT COUNT(*) AS filas, COUNT(DISTINCT ocid) AS ocids, COUNT(DISTINCT id) AS ids,
       COUNT(DISTINCT tender_id) AS tender_ids
FROM stg.main;

-- A2. Distribucion de procesos por anio de publicacion (el archivo "2025" contiene
--     procesos de muchos anios: lo compilado/actualizado en 2025)
SELECT LEFT(tender_datePublished, 4) AS anio, COUNT(*) AS procesos
FROM stg.main GROUP BY LEFT(tender_datePublished, 4) ORDER BY anio;

-- A3. Procesos del rango de analisis (ajustar fechas segun los anios cargados)
SELECT COUNT(*) AS procesos_2024_2025
FROM stg.main
WHERE tender_datePublished >= '2024-01-01' AND tender_datePublished < '2026-01-01';

-- A4. Roles en parties
SELECT roles, COUNT(*) AS filas FROM stg.parties GROUP BY roles ORDER BY filas DESC;

-- A5. Compradores: address_region es la PROVINCIA y address_department el DEPARTAMENTO
SELECT TOP 15 address_region, address_department, COUNT(*) AS filas
FROM stg.parties WHERE roles LIKE '%buyer%'
GROUP BY address_region, address_department ORDER BY filas DESC;

-- A6. Compradores unicos y un solo nombre por id
SELECT COUNT(DISTINCT id) AS compradores, COUNT(DISTINCT CONCAT(id, '|', name)) AS combinaciones_id_nombre
FROM stg.parties WHERE roles LIKE '%buyer%';

-- A7. Adjudicaciones y contratos: filas, ids distintos, procesos
SELECT 'awards' AS tabla, COUNT(*) AS filas, COUNT(DISTINCT id) AS ids_distintos, COUNT(DISTINCT main_id) AS procesos FROM stg.awards
UNION ALL
SELECT 'contracts', COUNT(*), COUNT(DISTINCT id), COUNT(DISTINCT main_id) FROM stg.contracts;

-- A8. Contratos por adjudicacion (adendas / lotes: un awardID llega a tener 200 contratos)
SELECT contratos_por_award, COUNT(*) AS awards
FROM (SELECT awardID, COUNT(*) AS contratos_por_award FROM stg.contracts GROUP BY awardID) x
GROUP BY contratos_por_award ORDER BY contratos_por_award;

-- A9. Monedas por origen
SELECT 'main' AS origen, tender_value_currency AS moneda, COUNT(*) AS filas FROM stg.main GROUP BY tender_value_currency
UNION ALL SELECT 'awards', value_currency, COUNT(*) FROM stg.awards GROUP BY value_currency
UNION ALL SELECT 'contracts', value_currency, COUNT(*) FROM stg.contracts GROUP BY value_currency;

-- A10. Tipos de procedimiento (mas de 50 variantes por ley o decreto)
SELECT tender_procurementMethodDetails, COUNT(*) AS procesos
FROM stg.main GROUP BY tender_procurementMethodDetails ORDER BY procesos DESC;

-- A11. Ids de adjudicacion repetidos entre procesos distintos (id = tender_id-RUC)
SELECT TOP 10 id, COUNT(*) AS n, COUNT(DISTINCT main_id) AS procesos
FROM stg.awards GROUP BY id HAVING COUNT(*) > 1 ORDER BY n DESC;

-- A12. tender_id repetidos entre procesos (mismo procedimiento registrado bajo varias entidades)
SELECT TOP 10 tender_id, COUNT(*) AS n, MIN(ocid) AS ocid_a, MAX(ocid) AS ocid_b
FROM stg.main WHERE NULLIF(tender_id,'') IS NOT NULL
GROUP BY tender_id HAVING COUNT(*) > 1 ORDER BY n DESC;

-- A13. Integridad referencial de staging (todas deben dar 0)
SELECT
 (SELECT COUNT(*) FROM stg.awards a        WHERE NOT EXISTS (SELECT 1 FROM stg.main m WHERE m.id = a.main_id)) AS awards_huerfanos,
 (SELECT COUNT(*) FROM stg.contracts c     WHERE NOT EXISTS (SELECT 1 FROM stg.main m WHERE m.id = c.main_id)) AS contracts_huerfanos,
 (SELECT COUNT(*) FROM stg.tender_items i  WHERE NOT EXISTS (SELECT 1 FROM stg.main m WHERE m.id = i.main_id)) AS items_huerfanos,
 (SELECT COUNT(*) FROM stg.tender_tenderers t WHERE NOT EXISTS (SELECT 1 FROM stg.main m WHERE m.id = t.main_id)) AS tenderers_huerfanos;

/* ============================ B. CALIDAD (core / dw) ====================== */

-- B1. Postores declarados vs reales
SELECT COUNT(*) AS procesos,
       SUM(CASE WHEN p.num_postores_declarado IS NULL THEN 1 ELSE 0 END) AS sin_declarado,
       SUM(CASE WHEN p.num_postores_declarado = ISNULL(x.n,0) THEN 1 ELSE 0 END) AS coinciden
FROM core.proceso p
LEFT JOIN (SELECT proceso_id, COUNT(*) AS n FROM core.postor GROUP BY proceso_id) x ON x.proceso_id = p.proceso_id;

-- B2. Procesos sin adjudicacion y con un solo postor
SELECT COUNT(*) AS procesos,
       SUM(CASE WHEN a.proceso_id IS NULL THEN 1 ELSE 0 END) AS sin_adjudicacion,
       SUM(CASE WHEN ISNULL(po.n,0) = 1 THEN 1 ELSE 0 END)   AS un_postor
FROM core.proceso p
LEFT JOIN (SELECT DISTINCT proceso_id FROM core.adjudicacion) a ON a.proceso_id = p.proceso_id
LEFT JOIN (SELECT proceso_id, COUNT(*) AS n FROM core.postor GROUP BY proceso_id) po ON po.proceso_id = p.proceso_id;

-- B3. "Sin adjudicacion" por familia, separando con y sin postores
SELECT d.familia,
       COUNT(*) AS sin_adjudicacion,
       SUM(CASE WHEN ISNULL(po.n,0) = 0 THEN 1 ELSE 0 END) AS sin_postores,
       SUM(CASE WHEN ISNULL(po.n,0) > 0 THEN 1 ELSE 0 END) AS con_postores
FROM core.proceso p
JOIN core.procedimiento d ON d.procedimiento_id = p.procedimiento_id
LEFT JOIN (SELECT DISTINCT proceso_id FROM core.adjudicacion) a ON a.proceso_id = p.proceso_id
LEFT JOIN (SELECT proceso_id, COUNT(*) AS n FROM core.postor GROUP BY proceso_id) po ON po.proceso_id = p.proceso_id
WHERE a.proceso_id IS NULL
GROUP BY d.familia ORDER BY sin_adjudicacion DESC;

-- B4. Cobertura mensual: procesos y % sin adjudicacion (los meses recientes de 2025 estan inmaduros)
SELECT YEAR(p.fecha_publicacion) AS anio, MONTH(p.fecha_publicacion) AS mes,
       COUNT(*) AS procesos,
       SUM(CASE WHEN a.proceso_id IS NULL THEN 1 ELSE 0 END) AS sin_adjudicacion
FROM core.proceso p
LEFT JOIN (SELECT DISTINCT proceso_id FROM core.adjudicacion) a ON a.proceso_id = p.proceso_id
GROUP BY YEAR(p.fecha_publicacion), MONTH(p.fecha_publicacion)
ORDER BY anio, mes;

-- B5. Montos sin conversion a soles, por moneda (deben ser 0 filas salvo contratos sin tasa)
SELECT 'contrato' AS tabla, ISNULL(moneda,'(vacia)') AS moneda, COUNT(*) AS filas
FROM core.contrato WHERE monto_original IS NOT NULL AND monto_pen IS NULL GROUP BY moneda
UNION ALL
SELECT 'adjudicacion', ISNULL(moneda,'(vacia)'), COUNT(*)
FROM core.adjudicacion WHERE monto_original IS NOT NULL AND monto_pen IS NULL GROUP BY moneda;

-- B6. Moneda del monto final distinta de la del contrato (esperado 0)
SELECT COUNT(*) AS contratos_moneda_final_distinta
FROM stg.contracts
WHERE NULLIF(implementation_finalValue_currency,'') IS NOT NULL
  AND NULLIF(value_currency,'') IS NOT NULL
  AND implementation_finalValue_currency <> value_currency;

-- B7. Contratos firmados fuera del rango de la dimension fecha
SELECT COUNT(*) AS contratos_fuera_rango, MIN(fecha_firma) AS minima, MAX(fecha_firma) AS maxima
FROM core.contrato
WHERE fecha_firma < (SELECT MIN(fecha) FROM dw.dim_fecha) OR fecha_firma > (SELECT MAX(fecha) FROM dw.dim_fecha);

-- B8. Plazo publicacion -> "cierre de ofertas": 0 dias en ~89 % de los casos,
--     por eso esta etapa NO se mide (tenderPeriod coincide con la fecha de publicacion)
SELECT TOP 10 DATEDIFF(DAY, fecha_publicacion, fecha_fin_ofertas) AS dias, COUNT(*) AS procesos
FROM core.proceso GROUP BY DATEDIFF(DAY, fecha_publicacion, fecha_fin_ofertas) ORDER BY procesos DESC;

-- B9. Adjudicaciones con fecha anterior a la publicacion (dias negativos)
SELECT COUNT(*) AS adj_con_dias_negativos
FROM dw.fact_proceso WHERE tiene_adjudicacion = 1 AND dias_publicacion_adjudicacion IS NULL;

-- B10. Reconciliacion entre hechos: ambos deben sumar lo mismo
SELECT (SELECT SUM(monto_adjudicado_pen) FROM dw.fact_proceso) AS en_fact_proceso,
       (SELECT SUM(monto_pen) FROM dw.fact_adjudicacion)       AS en_fact_adjudicacion;

-- B11. Medianas de tiempos por familia (2025, sin procesos en curso, solo adjudicados)
SELECT DISTINCT p.familia,
       COUNT(*) OVER (PARTITION BY p.familia) AS procesos,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.dias_publicacion_adjudicacion) OVER (PARTITION BY p.familia) AS mediana_pub_adj,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.dias_adjudicacion_firma)       OVER (PARTITION BY p.familia) AS mediana_adj_firma
FROM dw.fact_proceso f
JOIN dw.dim_procedimiento p ON p.procedimiento_id = f.procedimiento_id
JOIN dw.dim_fecha d ON d.fecha_key = f.fecha_publicacion_key AND d.anio = 2025
WHERE f.en_curso = 0 AND f.tiene_adjudicacion = 1
ORDER BY mediana_pub_adj DESC;
