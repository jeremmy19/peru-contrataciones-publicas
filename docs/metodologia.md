# Metodología y limitaciones

## Carga
- 9 CSV aplanados OCDS por año, relacionados por `main_id` / `archivo_origen`.
- `BULK INSERT` a `stg` con todas las columnas `NVARCHAR(MAX)`, mapeo por nombre de columna (cabecera). Terminador de fila `0x0a`.
- Deduplicación: una versión por `ocid` (mayor `date`, luego `archivo_origen`).

## Reglas de negocio
- **Gasto** = monto adjudicado (tabla de adjudicaciones). No se suman contratos unidos a adjudicaciones.
- **Año** = año de publicación del proceso (`fecha_publicacion_key`), idéntico en todas las páginas.
- **Comparación 2023–2025**: ene–jun, porque 2025 está incompleto.
- **en_curso**: procesos publicados desde 2025-10-01.
- **Desierto (proxy)**: proceso competitivo, no en curso, sin adjudicación.
- **Un solo postor**: solo familias competitivas.
- **Ahorro**: `1 − adjudicado/referencial` en procesos con ambos montos > 0.
- **Moneda**: montos convertidos a PEN; `pen_inferido` marca los casos inferidos.

## Familias de procedimiento
Adjudicación Abreviada · Procedimientos abreviados (Ley 32069) · Adjudicación Simplificada · Subasta Inversa · Licitación Pública · Concurso Público · Comparación de Precios · Contratación Directa/Exoneración · Régimen anterior · Otros/especiales.

## Calidad de proveedores
- Nombres: mayúsculas, sin comillas, recortados.
- `tipo_contribuyente`: RUC 20 = persona jurídica; 10 = natural; `L` o `99` = "Extranjero / sin RUC"; otro numérico = Consorcio.
- RUC genérico `99999999999`: 3,425 adjudicaciones, S/ 2.8 mil M (2.0%); se excluye del ranking Top 10.

## Contexto regulatorio
Ley 32069 (publicada 24/06/2024); Reglamento DS 009-2025-EF (publicado 22/01/2025, vigente desde 22/04/2025). En los datos, las adjudicaciones simplificadas pasan de 1,174 procesos el 21/04/2025 a 21 el 22/04/2025. Se presenta como **coincidencia temporal**, no como causalidad demostrada.

## Limitaciones
- 2025 incompleto; no comparar totales anuales.
- Desierto es aproximación.
- Calidad de origen (nombres, RUC genéricos, advertencias de publicación del OECE sobre postores duplicados y vínculos adjudicación–contrato).
- Los resultados dependen de la fecha de descarga de los CSV.
