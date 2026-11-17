/* ============================================================================
   04_consultas_analiticas.sql
   Consultas analiticas con CTE y funciones de ventana sobre el esquema dw.
   Solo lectura. Sin filtros fijos de año: se usan variables.

   Reglas de lectura (ver README):
   - Gasto = monto ADJUDICADO (fact_adjudicacion); nunca sumar contratos unidos a adjudicaciones.
   - "Cohorte" = procesos segun su año de PUBLICACION.
   - El ultimo periodo esta inmaduro (procesos en curso): comparar ventanas iguales (ene-jun).
   - "Desierto" es un proxy (sin adjudicacion y no en curso), no un estado oficial.
   ============================================================================ */
USE ContratacionesPE;
GO

/* Q1. Comparacion interanual en la misma ventana (enero-junio de cada año) */
SELECT d.anio,
       COUNT(*)                                             AS procesos,
       SUM(CAST(f.tiene_adjudicacion AS INT))               AS adjudicados,
       CAST(100.0*SUM(CAST(f.tiene_adjudicacion AS INT))/COUNT(*) AS DECIMAL(5,1)) AS pct_adjudicados,
       SUM(f.monto_adjudicado_pen)                          AS gasto_pen,
       SUM(f.monto_adjudicado_pen)/NULLIF(SUM(CAST(f.tiene_adjudicacion AS INT)),0) AS gasto_por_adjudicado
FROM dw.fact_proceso f
JOIN dw.dim_fecha d ON d.fecha_key = f.fecha_publicacion_key
WHERE d.mes BETWEEN 1 AND 6
GROUP BY d.anio ORDER BY d.anio;

/* Q2. Gasto mensual por cohorte de publicacion + variacion contra el mes anterior */
WITH m AS (
  SELECT d.anio_mes, SUM(f.monto_adjudicado_pen) AS gasto, COUNT(*) AS procesos
  FROM dw.fact_proceso f JOIN dw.dim_fecha d ON d.fecha_key = f.fecha_publicacion_key
  GROUP BY d.anio_mes)
SELECT anio_mes, procesos, gasto,
       LAG(gasto) OVER (ORDER BY anio_mes) AS gasto_mes_anterior,
       CAST(100.0*(gasto - LAG(gasto) OVER (ORDER BY anio_mes))
            / NULLIF(LAG(gasto) OVER (ORDER BY anio_mes),0) AS DECIMAL(7,1)) AS var_pct,
       AVG(gasto) OVER (ORDER BY anio_mes ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS media_movil_3m
FROM m ORDER BY anio_mes;

/* Q3. Top 10 entidades por gasto en un año con participacion y acumulado */
DECLARE @anio INT = 2025;
WITH g AS (
  SELECT e.nombre, e.departamento, SUM(a.monto_pen) AS gasto, COUNT(DISTINCT a.proceso_id) AS procesos
  FROM dw.fact_adjudicacion a
  JOIN dw.dim_entidad e ON e.entidad_id = a.entidad_id
  JOIN dw.dim_fecha d   ON d.fecha_key = a.fecha_key
  WHERE d.anio = @anio
  GROUP BY e.nombre, e.departamento)
SELECT TOP 10 RANK() OVER (ORDER BY gasto DESC) AS ranking, nombre, departamento, procesos, gasto,
       CAST(100.0*gasto/SUM(gasto) OVER () AS DECIMAL(5,2)) AS pct_total,
       CAST(100.0*SUM(gasto) OVER (ORDER BY gasto DESC ROWS UNBOUNDED PRECEDING)/SUM(gasto) OVER () AS DECIMAL(5,2)) AS pct_acumulado
FROM g ORDER BY gasto DESC;

/* Q4. Gasto por departamento (de la entidad compradora) y su posicion */
WITH g AS (
  SELECT ISNULL(e.departamento,'(sin dato)') AS departamento, SUM(a.monto_pen) AS gasto
  FROM dw.fact_adjudicacion a
  JOIN dw.dim_entidad e ON e.entidad_id = a.entidad_id
  JOIN dw.dim_fecha d   ON d.fecha_key = a.fecha_key
  WHERE d.anio = @anio
  GROUP BY e.departamento)
SELECT DENSE_RANK() OVER (ORDER BY gasto DESC) AS pos, departamento, gasto,
       CAST(100.0*gasto/SUM(gasto) OVER () AS DECIMAL(5,2)) AS pct
FROM g ORDER BY gasto DESC;

/* Q5. Concentracion de proveedores: top 20 y cuota del top 10 / 1 % de proveedores */
WITH g AS (
  SELECT p.proveedor_id, p.nombre, SUM(a.monto_pen) AS gasto, COUNT(DISTINCT a.proceso_id) AS procesos
  FROM dw.fact_adjudicacion a
  JOIN dw.dim_proveedor p ON p.proveedor_id = a.proveedor_id
  JOIN dw.dim_fecha d     ON d.fecha_key = a.fecha_key
  WHERE d.anio = @anio AND a.monto_pen IS NOT NULL
  GROUP BY p.proveedor_id, p.nombre),
r AS (
  SELECT *, ROW_NUMBER() OVER (ORDER BY gasto DESC) AS rn,
         COUNT(*) OVER () AS n, SUM(gasto) OVER () AS total
  FROM g)
SELECT rn AS ranking, nombre, procesos, gasto,
       CAST(100.0*gasto/total AS DECIMAL(5,2)) AS pct_total,
       CAST(100.0*SUM(gasto) OVER (ORDER BY rn)/total AS DECIMAL(5,2)) AS pct_acumulado,
       NTILE(100) OVER (ORDER BY gasto DESC) AS percentil
FROM r WHERE rn <= 20 ORDER BY rn;

/* Q6. Competencia por familia (solo familias competitivas): un solo postor y proxy de desierto */
SELECT p.familia,
       COUNT(*) AS procesos,
       CAST(100.0*SUM(CAST(f.un_solo_postor AS INT))/COUNT(*) AS DECIMAL(5,1)) AS pct_un_solo_postor,
       CAST(100.0*SUM(CAST(f.proxy_desierto AS INT))/COUNT(*) AS DECIMAL(5,1)) AS pct_proxy_desierto
FROM dw.fact_proceso f
JOIN dw.dim_procedimiento p ON p.procedimiento_id = f.procedimiento_id
JOIN dw.dim_fecha d ON d.fecha_key = f.fecha_publicacion_key
WHERE d.anio = @anio AND f.en_curso = 0
  AND p.familia IN (N'Adjudicación Simplificada', N'Subasta Inversa Electrónica',
                    N'Licitación Pública', N'Concurso Público', N'Comparación de Precios',
                    N'Procedimientos abreviados (Ley 32069)')
GROUP BY p.familia ORDER BY procesos DESC;

/* Q7. Tiempos: medianas por familia (publicacion->adjudicacion, adjudicacion->firma) */
SELECT DISTINCT p.familia,
       COUNT(*) OVER (PARTITION BY p.familia) AS procesos,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.dias_publicacion_adjudicacion) OVER (PARTITION BY p.familia) AS mediana_pub_adj,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CASE WHEN f.firma_fuera_rango = 0 THEN f.dias_adjudicacion_firma END)
         OVER (PARTITION BY p.familia) AS mediana_adj_firma
FROM dw.fact_proceso f
JOIN dw.dim_procedimiento p ON p.procedimiento_id = f.procedimiento_id
JOIN dw.dim_fecha d ON d.fecha_key = f.fecha_publicacion_key
WHERE d.anio = @anio AND f.en_curso = 0 AND f.tiene_adjudicacion = 1
ORDER BY mediana_pub_adj DESC;

/* Q8. Ahorro frente al valor referencial */
SELECT d.anio, p.familia,
       SUM(f.monto_referencial_pen) AS referencial, SUM(f.monto_adjudicado_pen) AS adjudicado,
       CAST(100.0*(1 - SUM(f.monto_adjudicado_pen)/NULLIF(SUM(f.monto_referencial_pen),0)) AS DECIMAL(6,2)) AS ahorro_pct
FROM dw.fact_proceso f
JOIN dw.dim_procedimiento p ON p.procedimiento_id = f.procedimiento_id
JOIN dw.dim_fecha d ON d.fecha_key = f.fecha_publicacion_key
WHERE f.tiene_adjudicacion = 1 AND f.monto_referencial_pen > 0 AND f.monto_adjudicado_pen IS NOT NULL
GROUP BY d.anio, p.familia ORDER BY d.anio, ahorro_pct DESC;
GO
