# Rendimiento

## Pipeline

| Corrida            | Tiempo total            |
| ------------------ | ----------------------- |
| 2024 + 2025        | 684.3 s (core: 110.6 s) |
| 2023 + 2024 + 2025 | 918 s (core: 144.7 s)   |

## Índices (script `05_indices_antes_despues.sql`)

Medición con caché fría (`DBCC DROPCLEANBUFFERS`, `FREEPROCCACHE`), 3 años de datos
(2023–2025), parámetros fijos: el proveedor con más participaciones y la entidad con
más procesos. Métrica principal: lecturas lógicas (páginas leídas), que es estable
entre corridas; el tiempo depende del estado del disco y la caché.

| Consulta                                       | Lecturas lógicas antes | Lecturas lógicas después | Mejora | Tiempo antes | Tiempo después |
| ---------------------------------------------- | ---------------------: | -----------------------: | -----: | -----------: | -------------: |
| Q1 Historial de participación de un proveedor  |                 14,245 |                      838 | −94.1% |       299 ms |         211 ms |
| Q2 Adjudicaciones de un proveedor en 2025      |                  1,944 |                        3 | −99.8% |        26 ms |           1 ms |
| Q3 Procesos de una entidad, 1.er semestre 2025 |                  9,035 |                        5 | −99.9% |        16 ms |         < 1 ms |
| Q4 Ítems por clasificación de una entidad      |                 24,573 |                    3,268 | −86.7% |  13,893 ms\* |         120 ms |
| Q5 Ranking global de proveedores               |                  6,956 |                   84,962 | +12.2× |       237 ms |         317 ms |

\* El tiempo de Q4 "antes" (13.9 s) está dominado por lectura de disco con caché fría:
la CPU fue de solo 278 ms. Por eso la comparación fiable es la de lecturas lógicas.

**Lectura de resultados**

- Q1–Q4 son búsquedas selectivas (un proveedor o una entidad). El plan pasa de
  recorrer la tabla completa (_scan_) a buscar directamente por el índice (_seek_):
  entre 87% y 99.9% menos páginas leídas.
- **Q5 empeora con los índices.** Es un ranking global que recorre todos los
  proveedores; con los índices el optimizador eligió buscar por cada proveedor
  (26,820 búsquedas sobre `core.adjudicacion`), lo que lee más páginas que un solo
  recorrido. Un índice acelera búsquedas puntuales, no agregaciones sobre toda la
  tabla, y no es gratis: ocupa espacio y se mantiene en cada carga.
- Prueba sintética (200 ejecuciones seguidas de Q2): antes 4,418 ms; después _[completar]_ ms.
- Tamaño de índices (`sp_spaceused`): sin índices de rendimiento 57,432 KB; con ellos _[completar]_ KB.
  El tamaño total de la base (31,760 MB) no cambia porque el archivo de datos está preasignado.

## Respaldo / restauración

Ver `sql/06_respaldo_restauracion.sql`. Los `.bak` no se versionan (ver `.gitignore`).
