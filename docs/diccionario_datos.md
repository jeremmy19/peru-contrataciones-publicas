# Diccionario de datos (dw)

## fact_proceso

| Columna | Descripción |
|
| proceso_id / ocid | Clave interna / identificador OCDS |
| entidad_id, categoria_id, procedimiento_id | Claves a dimensiones |
| fecha_publicacion_key, fecha_adjudicacion_key, fecha_firma_key | Fechas (yyyymmdd) |
| monto_referencial_pen, monto_adjudicado_pen, monto_contratado_pen, monto_final_pen | Montos en soles |
| n_postores, n_adjudicaciones, n_contratos | Conteos |
| tiene_adjudicacion, sin_postores, un_solo_postor, en_curso, proxy_desierto | Banderas |
| dias_publicacion_adjudicacion, dias_adjudicacion_firma, dias_publicacion_firma | Plazos en días |
| firma_fuera_rango | Firma con fecha fuera de rango esperado |

## fact_adjudicacion

| Columna | Descripción |
|
| adjudicacion_id, proceso_id | Claves |
| entidad_id, proveedor_id, categoria_id, procedimiento_id | Dimensiones |
| fecha_key, fecha_publicacion_key | Fecha de adjudicación / publicación del proceso |
| moneda_original, monto_pen, pen_inferido | Moneda y monto en PEN |

## Dimensiones

- **dim_fecha**: fecha_key, fecha, anio, trimestre, mes, nombre_mes, anio_mes, dia, dia_semana.
- **dim_entidad**: entidad_id, codigo_consucode, nombre, departamento, provincia, distrito.
- **dim_proveedor**: proveedor_id, ruc, nombre, tipo_contribuyente.
- **dim_procedimiento**: procedimiento_id, detalle, familia.
- **dim_categoria**: categoria_id, nombre (bienes, servicios, obras, consultoría de obra).
