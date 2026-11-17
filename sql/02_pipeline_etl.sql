/* ============================================================================
   02_pipeline_etl.sql  -  Pipeline ETL de ContratacionesPE

   Crea:
     etl.carga_log               bitacora de ejecuciones (con tiempos por etapa)
     etl.sp_cargar_staging       recrea stg y carga los CSV (carpeta como parametro)
     etl.sp_construir_modelo     reconstruye core y dw desde staging (transaccion)
     etl.sp_ejecutar_pipeline    maestro: staging + modelo

   Carpeta de datos: una subcarpeta por año con los 9 CSV, por ejemplo
     C:\datos_oece\2024\main.csv   C:\datos_oece\2025\main.csv   ...

   Uso:
     EXEC etl.sp_ejecutar_pipeline;                                   -- 2023, 2024 y 2025 (valores por defecto)
     EXEC etl.sp_ejecutar_pipeline @años=N'2024,2025', @desde='2024-01-01';   -- solo dos años
     EXEC etl.sp_ejecutar_pipeline @omitir_staging = 1;               -- solo reconstruye core y dw
   ============================================================================ */
USE ContratacionesPE;
GO
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl');
GO

IF OBJECT_ID('etl.carga_log') IS NULL
CREATE TABLE etl.carga_log (
  log_id       INT IDENTITY(1,1) CONSTRAINT PK_carga_log PRIMARY KEY,
  ejecucion_id UNIQUEIDENTIFIER NOT NULL,
  etapa        NVARCHAR(100) NOT NULL,
  inicio       DATETIME2(3) NOT NULL,
  fin          DATETIME2(3) NOT NULL,
  segundos     AS CAST(DATEDIFF(MILLISECOND, inicio, fin) / 1000.0 AS DECIMAL(10,1)),
  filas        BIGINT NULL,
  estado       NVARCHAR(10) NOT NULL,
  mensaje      NVARCHAR(2000) NULL
);
GO

/* ============================================================================
   1. STAGING (varios años)
      - Estructura esperada en disco:  <@carpeta>\<año>\<tabla>.csv
        por ejemplo C:\datos_oece\2024\main.csv y C:\datos_oece\2025\main.csv
      - Lee la CABECERA REAL de cada CSV y carga por nombre de columna, porque
        el orden de columnas cambia entre años (main.csv de 2024 vs 2025).
      - Cada fila queda marcada con archivo_origen (el año del archivo).
   ============================================================================ */
CREATE OR ALTER PROCEDURE etl.sp_cargar_staging
  @carpeta      NVARCHAR(260) = N'C:\datos_oece\',
  @anios        NVARCHAR(100) = N'2023,2024,2025',
  @ejecucion_id UNIQUEIDENTIFIER = NULL
AS
BEGIN
  SET NOCOUNT ON;
  IF @ejecucion_id IS NULL SET @ejecucion_id = NEWID();
  IF RIGHT(@carpeta, 1) <> N'\' SET @carpeta = @carpeta + N'\';

  DECLARE @tabla SYSNAME, @cols NVARCHAR(MAX), @anio NVARCHAR(10), @ruta NVARCHAR(400),
          @hdr NVARCHAR(MAX), @falta NVARCHAR(200), @msg NVARCHAR(600), @lista NVARCHAR(MAX),
          @sql NVARCHAR(MAX), @n BIGINT, @t DATETIME2(3), @i INT = 1, @max INT;

  -- Columnas esperadas por tabla (nombre de tabla = nombre del archivo CSV)
  DECLARE @archivos TABLE (orden INT IDENTITY(1,1), tabla SYSNAME, columnas NVARCHAR(MAX));
  INSERT @archivos (tabla, columnas) VALUES
   (N'main', N'id,tag,date,ocid,publishedDate,initiationType,buyer_id,buyer_name,tender_id,tender_hasTenderInformationProtectedByLaw,tender_title,tender_procurementMethodDetails,tender_additionalProcurementCategories,tender_description,tender_mainProcurementCategory,tender_datePublished,tender_procurementMethod,tender_value_amount,tender_value_currency,tender_value_amount_PEN,tender_value_currencyName,tender_tenderPeriod_endDate,tender_tenderPeriod_startDate,tender_procuringEntity_id,tender_procuringEntity_name,dataSegmentation_id,dataSegmentation_criteria,tender_numberOfTenderers,planning_budget_description,planning_budget_amount_amount,planning_budget_amount_currency,planning_budget_amount_currencyName,tender_enquiryPeriod_endDate,tender_enquiryPeriod_startDate,tender_enquiryPeriod_durationInDays,planning_budget_project,planning_budget_projectID'),
   (N'parties', N'id,name,roles,address_region,address_locality,address_department,address_countryName,address_streetAddress,identifier_id,identifier_scheme,identifier_legalName,main_ocid,main_id,contactPoint_email,contactPoint_telephone,contactPoint_url'),
   (N'tender_tenderers', N'id,name,main_ocid,main_id,tender_id'),
   (N'awards', N'id,date,value_amount,value_currency,value_currencyName,main_ocid,main_id'),
   (N'awards_suppliers', N'id,name,main_ocid,main_id,awards_id'),
   (N'contracts', N'id,awardID,title,dateSigned,description,value_amount,value_currency,value_currencyName,period_endDate,period_startDate,period_durationInDays,implementation_finalValue_amount,implementation_finalValue_currency,implementation_finalValue_currencyName,main_ocid,main_id,statusDetails,status,implementation_endDate'),
   (N'tender_items', N'id,description,status,position,quantity,statusDetails,unit_id,unit_name,unit_scheme,totalValue_amount,totalValue_currency,totalValue_currencyName,classification_id,classification_scheme,classification_description,main_ocid,main_id,tender_id'),
   (N'awards_value_exchangeRates', N'rate,currency,main_ocid,main_id,awards_id'),
   (N'contracts_value_exchangeRates', N'rate,currency,main_ocid,main_id,contracts_id');

  -- Una carga por cada combinacion año x archivo, en orden de año
  DECLARE @cargas TABLE (orden INT, anio NVARCHAR(10), tabla SYSNAME, columnas NVARCHAR(MAX));
  INSERT @cargas (orden, anio, tabla, columnas)
  SELECT ROW_NUMBER() OVER (ORDER BY y.anio, t.orden), y.anio, t.tabla, t.columnas
  FROM (SELECT LTRIM(RTRIM(value)) AS anio FROM STRING_SPLIT(@anios, N',') WHERE LTRIM(RTRIM(value)) <> N'') y
  CROSS JOIN @archivos t;

  SELECT @max = MAX(orden) FROM @cargas;

  BEGIN TRY
    IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
    IF @max IS NULL THROW 50020, N'Indica al menos un anio en @anios (por ejemplo N''2024,2025'').', 1;

    -- 1. Recrear las tablas finales de staging
    SET @t = SYSDATETIME();
    DECLARE @j INT = 1, @maxa INT = (SELECT MAX(orden) FROM @archivos);
    WHILE @j <= @maxa
    BEGIN
      SELECT @tabla = tabla, @cols = columnas FROM @archivos WHERE orden = @j;
      SET @sql = N'DROP TABLE IF EXISTS stg.' + QUOTENAME(@tabla) + N'; '
               + N'CREATE TABLE stg.' + QUOTENAME(@tabla)
               + N' (archivo_origen NVARCHAR(10) NOT NULL, ['
               + REPLACE(@cols, N',', N'] NVARCHAR(MAX) NULL, [') + N'] NVARCHAR(MAX) NULL);';
      EXEC sys.sp_executesql @sql;
      SET @j += 1;
    END
    INSERT etl.carga_log (ejecucion_id, etapa, inicio, fin, filas, estado)
    VALUES (@ejecucion_id, N'stg: estructura', @t, SYSDATETIME(), NULL, N'OK');

    -- 2. Cargar cada archivo
    WHILE @i <= @max
    BEGIN
      SELECT @anio = anio, @tabla = tabla, @cols = columnas FROM @cargas WHERE orden = @i;
      SET @t = SYSDATETIME();
      SET @ruta = @carpeta + @anio + N'\' + @tabla + N'.csv';

      DROP TABLE IF EXISTS stg._hdr, stg._landing;

      -- a) Leer la cabecera real del archivo (primera linea)
      CREATE TABLE stg._hdr (linea NVARCHAR(MAX) NULL);
      SET @sql = N'BULK INSERT stg._hdr FROM ''' + REPLACE(@ruta, N'''', N'''''') + N''''
               + N' WITH (FIELDTERMINATOR=''\t'', ROWTERMINATOR=''0x0a'', FIRSTROW=1, LASTROW=1, CODEPAGE=''65001'');';
      EXEC sys.sp_executesql @sql;
      SELECT @hdr = REPLACE(REPLACE(REPLACE(linea, NCHAR(65279), N''), CHAR(13), N''), CHAR(10), N'') FROM stg._hdr;
      IF @hdr IS NULL OR LEN(@hdr) = 0
      BEGIN
        SET @msg = N'No se pudo leer la cabecera de ' + @ruta;
        THROW 50022, @msg, 1;
      END

      -- b) Validar que estan todas las columnas esperadas
      SET @falta = NULL;
      SELECT TOP 1 @falta = value FROM STRING_SPLIT(@cols, N',')
      WHERE CHARINDEX(N',' + value + N',', N',' + @hdr + N',') = 0;
      IF @falta IS NOT NULL
      BEGIN
        SET @msg = N'El archivo ' + @ruta + N' no tiene la columna esperada: ' + @falta;
        THROW 50021, @msg, 1;
      END

      -- c) Cargar en una tabla de paso con las columnas EN EL ORDEN DEL ARCHIVO (los CSV usan salto LF = 0x0a)
      SET @sql = N'CREATE TABLE stg._landing ([' + REPLACE(@hdr, N',', N'] NVARCHAR(MAX) NULL, [') + N'] NVARCHAR(MAX) NULL);';
      EXEC sys.sp_executesql @sql;
      SET @sql = N'BULK INSERT stg._landing FROM ''' + REPLACE(@ruta, N'''', N'''''') + N''''
               + N' WITH (FORMAT=''CSV'', FIELDQUOTE=''"'', FIELDTERMINATOR='','', ROWTERMINATOR=''0x0a'','
               + N' FIRSTROW=2, CODEPAGE=''65001'', BATCHSIZE=50000, TABLOCK);';
      EXEC sys.sp_executesql @sql;

      -- d) Pasar a la tabla final por NOMBRE de columna
      SET @lista = N'[' + REPLACE(@cols, N',', N'],[') + N']';
      SET @sql = N'INSERT stg.' + QUOTENAME(@tabla) + N' (archivo_origen, ' + @lista + N') '
               + N'SELECT @anio, ' + @lista + N' FROM stg._landing;';
      EXEC sys.sp_executesql @sql, N'@anio NVARCHAR(10)', @anio = @anio;

      SELECT @n = COUNT_BIG(*) FROM stg._landing;
      INSERT etl.carga_log (ejecucion_id, etapa, inicio, fin, filas, estado)
      VALUES (@ejecucion_id, N'stg.' + @tabla + N' (' + @anio + N')', @t, SYSDATETIME(), @n, N'OK');

      DROP TABLE IF EXISTS stg._hdr, stg._landing;
      SET @i += 1;
    END
  END TRY
  BEGIN CATCH
    INSERT etl.carga_log (ejecucion_id, etapa, inicio, fin, filas, estado, mensaje)
    VALUES (@ejecucion_id, N'stg.' + ISNULL(@tabla, N'(inicio)') + ISNULL(N' (' + @anio + N')', N''),
            ISNULL(@t, SYSDATETIME()), SYSDATETIME(), NULL, N'ERROR', LEFT(ERROR_MESSAGE(), 2000));
    THROW;
  END CATCH
END
GO

/* ============================================================================
   2. MODELO (core + dw), todo dentro de una transaccion
   ============================================================================ */
CREATE OR ALTER PROCEDURE etl.sp_construir_modelo
  @desde          DATE = '2023-01-01',
  @hasta          DATE = '2026-01-01',
  @corte_en_curso DATE = '2025-10-01',
  @ejecucion_id   UNIQUEIDENTIFIER = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  IF @ejecucion_id IS NULL SET @ejecucion_id = NEWID();

  DECLARE @log TABLE (etapa NVARCHAR(100), inicio DATETIME2(3), fin DATETIME2(3), filas BIGINT);
  DECLARE @t DATETIME2(3), @etapa NVARCHAR(100), @n BIGINT, @diff DECIMAL(24,2);

  -- Rango de la dimension fecha: desde el 1 de enero del primer año hasta el fin del año
  -- o del ultimo año cargado, lo que sea mayor.
  DECLARE @ultimo_anio INT = YEAR(DATEADD(DAY, -1, @hasta));
  DECLARE @dim_ini DATE = DATEFROMPARTS(YEAR(@desde), 1, 1);
  DECLARE @dim_fin DATE = DATEFROMPARTS(CASE WHEN @ultimo_anio > YEAR(@desde) + 3 THEN @ultimo_anio ELSE YEAR(@desde) + 3 END, 12, 31);
  DECLARE @dim_fin_excl DATE = DATEADD(DAY, 1, @dim_fin);

  BEGIN TRY
    SET @etapa = N'validaciones previas'; SET @t = SYSDATETIME();
    IF @desde >= @hasta THROW 50001, N'@desde debe ser menor que @hasta.', 1;
    IF OBJECT_ID('stg.main') IS NULL THROW 50002, N'No existe stg.main. Ejecuta primero etl.sp_cargar_staging.', 1;
    IF NOT EXISTS (SELECT 1 FROM stg.main) THROW 50003, N'stg.main esta vacia. Ejecuta primero etl.sp_cargar_staging.', 1;
    IF OBJECT_ID('stg.awards_value_exchangeRates') IS NULL OR OBJECT_ID('stg.contracts_value_exchangeRates') IS NULL
       THROW 50004, N'Faltan las tablas de tipo de cambio en stg.', 1;

    IF SCHEMA_ID('core') IS NULL EXEC('CREATE SCHEMA core');
    IF SCHEMA_ID('dw')   IS NULL EXEC('CREATE SCHEMA dw');

    BEGIN TRAN;

    /* ------------------------------------------------------------------ */
    SET @etapa = N'core: estructura'; SET @t = SYSDATETIME();

    DROP TABLE IF EXISTS dw.fact_adjudicacion, dw.fact_proceso, dw.dim_fecha, dw.dim_entidad,
                         dw.dim_proveedor, dw.dim_procedimiento, dw.dim_categoria;
    DROP TABLE IF EXISTS core.item, core.contrato, core.adjudicacion, core.postor, core.proceso,
                         core.procedimiento, core.categoria, core.proveedor, core.entidad;

    CREATE TABLE core.entidad (
      entidad_id INT IDENTITY(1,1) CONSTRAINT PK_entidad PRIMARY KEY,
      entidad_key NVARCHAR(60) NOT NULL CONSTRAINT UQ_entidad_key UNIQUE,
      codigo_consucode NVARCHAR(20) NULL,
      nombre NVARCHAR(500) NOT NULL,
      departamento NVARCHAR(100) NULL,
      provincia NVARCHAR(100) NULL,
      distrito NVARCHAR(100) NULL,
      direccion NVARCHAR(500) NULL
    );
    CREATE TABLE core.proveedor (
      proveedor_id INT IDENTITY(1,1) CONSTRAINT PK_proveedor PRIMARY KEY,
      proveedor_key NVARCHAR(60) NOT NULL CONSTRAINT UQ_proveedor_key UNIQUE,
      ruc NVARCHAR(20) NULL,
      nombre NVARCHAR(500) NOT NULL,
      tipo_contribuyente NVARCHAR(30) NULL
    );
    CREATE TABLE core.categoria (
      categoria_id INT IDENTITY(1,1) CONSTRAINT PK_categoria PRIMARY KEY,
      categoria_key NVARCHAR(50) NOT NULL CONSTRAINT UQ_categoria_key UNIQUE,
      nombre NVARCHAR(100) NOT NULL
    );
    CREATE TABLE core.procedimiento (
      procedimiento_id INT IDENTITY(1,1) CONSTRAINT PK_procedimiento PRIMARY KEY,
      detalle NVARCHAR(200) NOT NULL CONSTRAINT UQ_procedimiento_detalle UNIQUE,
      familia NVARCHAR(100) NOT NULL
    );
    CREATE TABLE core.proceso (
      proceso_id INT IDENTITY(1,1) CONSTRAINT PK_proceso PRIMARY KEY,
      ocid NVARCHAR(200) NOT NULL CONSTRAINT UQ_proceso_ocid UNIQUE,
      main_id NVARCHAR(300) NOT NULL CONSTRAINT UQ_proceso_main_id UNIQUE,
      tender_id BIGINT NULL,
      entidad_id INT NULL CONSTRAINT FK_proceso_entidad REFERENCES core.entidad(entidad_id),
      categoria_id INT NULL CONSTRAINT FK_proceso_categoria REFERENCES core.categoria(categoria_id),
      procedimiento_id INT NULL CONSTRAINT FK_proceso_procedimiento REFERENCES core.procedimiento(procedimiento_id),
      metodo NVARCHAR(50) NULL,
      titulo NVARCHAR(1000) NULL,
      fecha_publicacion DATETIME2(0) NULL,
      fecha_inicio_ofertas DATETIME2(0) NULL,
      fecha_fin_ofertas DATETIME2(0) NULL,
      moneda NVARCHAR(3) NULL,
      monto_referencial_original DECIMAL(18,2) NULL,
      monto_referencial_pen DECIMAL(18,2) NULL,
      num_postores_declarado INT NULL,
      archivo_origen NVARCHAR(10) NULL
    );
    CREATE TABLE core.postor (
      proceso_id INT NOT NULL CONSTRAINT FK_postor_proceso REFERENCES core.proceso(proceso_id),
      proveedor_id INT NOT NULL CONSTRAINT FK_postor_proveedor REFERENCES core.proveedor(proveedor_id),
      CONSTRAINT PK_postor PRIMARY KEY (proceso_id, proveedor_id)
    );
    CREATE TABLE core.adjudicacion (
      adjudicacion_id INT IDENTITY(1,1) CONSTRAINT PK_adjudicacion PRIMARY KEY,
      proceso_id INT NOT NULL CONSTRAINT FK_adj_proceso REFERENCES core.proceso(proceso_id),
      award_key NVARCHAR(100) NOT NULL,
      proveedor_id INT NULL CONSTRAINT FK_adj_proveedor REFERENCES core.proveedor(proveedor_id),
      fecha_adjudicacion DATETIME2(0) NULL,
      moneda NVARCHAR(3) NULL,
      monto_original DECIMAL(18,2) NULL,
      monto_pen DECIMAL(18,2) NULL,
      es_duplicado BIT NOT NULL,
      pen_inferido BIT NOT NULL CONSTRAINT DF_adj_pen_inf DEFAULT 0
    );
    CREATE TABLE core.contrato (
      contrato_id INT IDENTITY(1,1) CONSTRAINT PK_contrato PRIMARY KEY,
      proceso_id INT NOT NULL CONSTRAINT FK_con_proceso REFERENCES core.proceso(proceso_id),
      contrato_key NVARCHAR(50) NOT NULL,
      award_key NVARCHAR(100) NULL,
      proveedor_id INT NULL CONSTRAINT FK_con_proveedor REFERENCES core.proveedor(proveedor_id),
      fecha_firma DATETIME2(0) NULL,
      fecha_inicio DATETIME2(0) NULL,
      fecha_fin DATETIME2(0) NULL,
      duracion_dias INT NULL,
      moneda NVARCHAR(3) NULL,
      monto_original DECIMAL(18,2) NULL,
      monto_pen DECIMAL(18,2) NULL,
      monto_final_original DECIMAL(18,2) NULL,
      monto_final_pen DECIMAL(18,2) NULL,
      estado NVARCHAR(50) NULL,
      estado_detalle NVARCHAR(100) NULL,
      es_duplicado BIT NOT NULL,
      pen_inferido BIT NOT NULL CONSTRAINT DF_con_pen_inf DEFAULT 0
    );
    CREATE TABLE core.item (
      item_id INT IDENTITY(1,1) CONSTRAINT PK_item PRIMARY KEY,
      proceso_id INT NOT NULL CONSTRAINT FK_item_proceso REFERENCES core.proceso(proceso_id),
      item_key NVARCHAR(50) NULL,
      posicion INT NULL,
      descripcion NVARCHAR(1000) NULL,
      cantidad DECIMAL(18,3) NULL,
      unidad NVARCHAR(200) NULL,
      moneda NVARCHAR(3) NULL,
      monto_original DECIMAL(18,2) NULL,
      monto_pen DECIMAL(18,2) NULL,
      clasificacion_id NVARCHAR(50) NULL,
      clasificacion_desc NVARCHAR(500) NULL
    );

    INSERT @log VALUES (@etapa, @t, SYSDATETIME(), NULL);

    /* ------------------------------------------------------------------ */
    SET @etapa = N'core: carga desde staging'; SET @t = SYSDATETIME();

    DROP TABLE IF EXISTS #proc, #tenderers, #prov_src, #aw, #aws;

    -- 1. Procesos del rango, tipados
    SELECT CAST(m.id AS NVARCHAR(300)) AS main_id,
           CAST(m.ocid AS NVARCHAR(200)) AS ocid,
           TRY_CAST(NULLIF(m.tender_id,'') AS BIGINT) AS tender_id,
           CAST(NULLIF(m.buyer_id,'') AS NVARCHAR(60)) AS buyer_id,
           CAST(NULLIF(m.buyer_name,'') AS NVARCHAR(500)) AS buyer_name,
           CAST(m.[date] AS NVARCHAR(60)) AS compilado,
           CAST(NULLIF(m.tender_mainProcurementCategory,'') AS NVARCHAR(50)) AS categoria,
           ISNULL(CAST(NULLIF(m.tender_procurementMethodDetails,'') AS NVARCHAR(200)), N'Sin dato') AS procedimiento,
           CAST(NULLIF(m.tender_procurementMethod,'') AS NVARCHAR(50)) AS metodo,
           CAST(LEFT(NULLIF(LTRIM(RTRIM(m.tender_title)),''), 1000) AS NVARCHAR(1000)) AS titulo,
           pub.f AS fecha_publicacion,
           CAST(TRY_CAST(NULLIF(m.tender_tenderPeriod_startDate,'') AS DATETIMEOFFSET) AS DATETIME2(0)) AS fecha_inicio_ofertas,
           CAST(TRY_CAST(NULLIF(m.tender_tenderPeriod_endDate,'') AS DATETIMEOFFSET) AS DATETIME2(0)) AS fecha_fin_ofertas,
           CAST(NULLIF(m.tender_value_currency,'') AS NVARCHAR(3)) AS moneda,
           TRY_CAST(NULLIF(m.tender_value_amount,'') AS DECIMAL(18,2)) AS monto_original,
           TRY_CAST(NULLIF(m.tender_value_amount_PEN,'') AS DECIMAL(18,2)) AS monto_pen,
           TRY_CAST(NULLIF(m.tender_numberOfTenderers,'') AS INT) AS num_postores,
           m.archivo_origen
    INTO #proc
    FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY ocid ORDER BY [date] DESC, archivo_origen DESC) AS rn
          FROM stg.main) m          -- una sola version por ocid (la compilada mas recientemente)
    CROSS APPLY (SELECT CAST(TRY_CAST(NULLIF(m.tender_datePublished,'') AS DATETIMEOFFSET) AS DATETIME2(0)) AS f) pub
    WHERE m.rn = 1 AND pub.f >= @desde AND pub.f < @hasta;

    CREATE UNIQUE CLUSTERED INDEX ix_proc ON #proc(main_id);

    -- 2. Entidades compradoras (region = departamento)
    INSERT core.entidad (entidad_key, codigo_consucode, nombre, departamento, provincia, distrito, direccion)
    SELECT id, cod, nombre, dep, prov, dist, dir
    FROM (
      SELECT CAST(p.id AS NVARCHAR(60)) AS id,
             CAST(NULLIF(p.identifier_id,'') AS NVARCHAR(20)) AS cod,
             CAST(LEFT(p.name,500) AS NVARCHAR(500)) AS nombre,
             CAST(NULLIF(p.address_department,'') AS NVARCHAR(100)) AS dep,
             CAST(NULLIF(p.address_region,'') AS NVARCHAR(100)) AS prov,
             CAST(NULLIF(p.address_locality,'') AS NVARCHAR(100)) AS dist,
             CAST(LEFT(NULLIF(p.address_streetAddress,''),500) AS NVARCHAR(500)) AS dir,
             ROW_NUMBER() OVER (PARTITION BY p.id ORDER BY pr.compilado DESC, pr.main_id) AS rn
      FROM stg.parties p
      JOIN #proc pr ON pr.main_id = CAST(p.main_id AS NVARCHAR(300)) AND pr.archivo_origen = p.archivo_origen
      WHERE p.roles LIKE '%buyer%' AND NULLIF(p.id,'') IS NOT NULL
    ) x
    WHERE rn = 1;

    INSERT core.entidad (entidad_key, nombre)
    SELECT pr.buyer_id, MAX(ISNULL(pr.buyer_name, pr.buyer_id))
    FROM #proc pr
    WHERE pr.buyer_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM core.entidad e WHERE e.entidad_key = pr.buyer_id)
    GROUP BY pr.buyer_id;

    -- 3. Categorias y procedimientos
    INSERT core.categoria (categoria_key, nombre)
    SELECT DISTINCT categoria,
           CASE categoria WHEN 'goods' THEN N'Bienes' WHEN 'services' THEN N'Servicios'
                          WHEN 'works' THEN N'Obras' WHEN 'consultingServices' THEN N'Consultoría de obras'
                          ELSE categoria END
    FROM #proc WHERE categoria IS NOT NULL;

    INSERT core.procedimiento (detalle, familia)
    SELECT DISTINCT procedimiento,
      CASE
          WHEN procedimiento LIKE N'Adjudicación Abreviada%' THEN N'Adjudicación Abreviada'
          WHEN procedimiento LIKE N'%Abreviad%' THEN N'Procedimientos abreviados (Ley 32069)'   -- regimen nuevo desde 22/04/2025
          WHEN procedimiento LIKE N'Adjudicación Simplificada%' THEN N'Adjudicación Simplificada'
          WHEN procedimiento LIKE N'Subasta Inversa%' THEN N'Subasta Inversa Electrónica'
          WHEN procedimiento LIKE N'Licitación Pública%' THEN N'Licitación Pública'
          WHEN procedimiento LIKE N'Concurso Público%' OR procedimiento LIKE N'Concurso de Proyectos%' THEN N'Concurso Público'
          WHEN procedimiento LIKE N'Comparación de Precios%' THEN N'Comparación de Precios'
          WHEN procedimiento LIKE N'Contratación Directa%' OR procedimiento LIKE N'Exoneración%' THEN N'Contratación Directa / Exoneración'
          WHEN procedimiento LIKE N'Adjudicación de Menor Cuantía%' OR procedimiento LIKE N'Adjudicación Directa%'
            OR procedimiento LIKE N'Adjudicación Selectiva%' THEN N'Régimen anterior'
          ELSE N'Otros / especiales'
      END
    FROM #proc;

    -- 4. Procesos
    INSERT core.proceso (ocid, main_id, tender_id, entidad_id, categoria_id, procedimiento_id, metodo, titulo,
                         fecha_publicacion, fecha_inicio_ofertas, fecha_fin_ofertas, moneda,
                         monto_referencial_original, monto_referencial_pen, num_postores_declarado, archivo_origen)
    SELECT pr.ocid, pr.main_id, pr.tender_id, e.entidad_id, c.categoria_id, d.procedimiento_id, pr.metodo, pr.titulo,
           pr.fecha_publicacion, pr.fecha_inicio_ofertas, pr.fecha_fin_ofertas, pr.moneda,
           pr.monto_original, pr.monto_pen, pr.num_postores, pr.archivo_origen
    FROM #proc pr
    LEFT JOIN core.entidad e ON e.entidad_key = pr.buyer_id
    LEFT JOIN core.categoria c ON c.categoria_key = pr.categoria
    LEFT JOIN core.procedimiento d ON d.detalle = pr.procedimiento;

    -- 5. Postores y proveedores
    SELECT CAST(t.main_id AS NVARCHAR(300)) AS main_id,
           CAST(t.id AS NVARCHAR(60)) AS prov_key,
           CAST(LEFT(NULLIF(LTRIM(RTRIM(UPPER(REPLACE(t.name, N'"', N'')))), N''), 500) AS NVARCHAR(500)) AS nombre
    INTO #tenderers
    FROM stg.tender_tenderers t
    JOIN #proc pr ON pr.main_id = CAST(t.main_id AS NVARCHAR(300)) AND pr.archivo_origen = t.archivo_origen
    WHERE NULLIF(t.id,'') IS NOT NULL;

    SELECT DISTINCT CAST(s.main_id AS NVARCHAR(300)) AS main_id,
           CAST(s.awards_id AS NVARCHAR(100)) AS award_key,
           CAST(s.id AS NVARCHAR(60)) AS prov_key,
           CAST(LEFT(NULLIF(LTRIM(RTRIM(UPPER(REPLACE(s.name, N'"', N'')))), N''), 500) AS NVARCHAR(500)) AS nombre
    INTO #aws
    FROM stg.awards_suppliers s
    JOIN #proc pr ON pr.main_id = CAST(s.main_id AS NVARCHAR(300)) AND pr.archivo_origen = s.archivo_origen
    WHERE NULLIF(s.id,'') IS NOT NULL;

    SELECT prov_key, nombre INTO #prov_src FROM #tenderers
    UNION ALL
    SELECT prov_key, nombre FROM #aws;

    ;WITH cnt AS (
      SELECT prov_key, nombre, COUNT(*) AS n FROM #prov_src GROUP BY prov_key, nombre
    ), r AS (
      SELECT prov_key, nombre, ROW_NUMBER() OVER (PARTITION BY prov_key ORDER BY n DESC, nombre) AS rn FROM cnt
    )
    INSERT core.proveedor (proveedor_key, ruc, nombre, tipo_contribuyente)
    SELECT prov_key,
           CASE WHEN prov_key LIKE 'PE-RUC-%' THEN SUBSTRING(prov_key, 8, 20) END,
           ISNULL(nombre, prov_key),
           CASE WHEN prov_key LIKE 'PE-RUC-20%' THEN N'Persona jurídica'
                WHEN prov_key LIKE 'PE-RUC-10%' THEN N'Persona natural'
                WHEN prov_key LIKE 'PE-RUC-L%' OR prov_key LIKE 'PE-RUC-99%' THEN N'Extranjero / sin RUC'
                WHEN prov_key LIKE 'PE-RUC-[0-9]%' THEN N'Consorcio'
                ELSE N'Otro' END
    FROM r WHERE rn = 1;

    INSERT core.postor (proceso_id, proveedor_id)
    SELECT DISTINCT p.proceso_id, v.proveedor_id
    FROM #tenderers t
    JOIN core.proceso p ON p.main_id = t.main_id
    JOIN core.proveedor v ON v.proveedor_key = t.prov_key;

    -- 6. Adjudicaciones
    SELECT CAST(a.main_id AS NVARCHAR(300)) AS main_id,
           CAST(a.id AS NVARCHAR(100)) AS award_key,
           CAST(TRY_CAST(NULLIF(a.[date],'') AS DATETIMEOFFSET) AS DATETIME2(0)) AS fecha,
           CAST(NULLIF(a.value_currency,'') AS NVARCHAR(3)) AS moneda,
           TRY_CAST(NULLIF(a.value_amount,'') AS DECIMAL(18,2)) AS monto
    INTO #aw
    FROM stg.awards a
    JOIN #proc pr ON pr.main_id = CAST(a.main_id AS NVARCHAR(300)) AND pr.archivo_origen = a.archivo_origen
    WHERE NULLIF(a.id,'') IS NOT NULL;

    INSERT core.adjudicacion (proceso_id, award_key, proveedor_id, fecha_adjudicacion, moneda, monto_original, monto_pen, es_duplicado)
    SELECT p.proceso_id, a.award_key, v.proveedor_id, a.fecha, a.moneda, a.monto,
           CASE WHEN a.moneda = 'PEN' THEN a.monto END,
           CASE WHEN ROW_NUMBER() OVER (PARTITION BY a.main_id, a.award_key, a.fecha, a.monto
                                        ORDER BY (SELECT NULL)) > 1 THEN 1 ELSE 0 END
    FROM #aw a
    JOIN core.proceso p ON p.main_id = a.main_id
    LEFT JOIN #aws s ON s.main_id = a.main_id AND s.award_key = a.award_key
    LEFT JOIN core.proveedor v ON v.proveedor_key = s.prov_key;

    -- 7. Contratos
    INSERT core.contrato (proceso_id, contrato_key, award_key, proveedor_id, fecha_firma, fecha_inicio, fecha_fin,
                          duracion_dias, moneda, monto_original, monto_pen, monto_final_original, monto_final_pen,
                          estado, estado_detalle, es_duplicado)
    SELECT p.proceso_id, x.contrato_key, x.award_key, v.proveedor_id, x.fecha_firma, x.fecha_inicio, x.fecha_fin,
           x.duracion, x.moneda, x.monto, CASE WHEN x.moneda = 'PEN' THEN x.monto END,
           x.monto_final, CASE WHEN x.moneda_final = 'PEN' THEN x.monto_final END,
           x.estado, x.estado_detalle,
           CASE WHEN ROW_NUMBER() OVER (PARTITION BY x.main_id, x.contrato_key ORDER BY (SELECT NULL)) > 1 THEN 1 ELSE 0 END
    FROM (
      SELECT CAST(c.main_id AS NVARCHAR(300)) AS main_id,
             CAST(c.id AS NVARCHAR(50)) AS contrato_key,
             CAST(NULLIF(c.awardID,'') AS NVARCHAR(100)) AS award_key,
             CASE WHEN CHARINDEX('-', c.awardID) > 0
                  THEN CAST('PE-RUC-' + SUBSTRING(c.awardID, CHARINDEX('-', c.awardID) + 1, 30) AS NVARCHAR(60)) END AS prov_key,
             CAST(TRY_CAST(NULLIF(c.dateSigned,'') AS DATETIMEOFFSET) AS DATETIME2(0)) AS fecha_firma,
             CAST(TRY_CAST(NULLIF(c.period_startDate,'') AS DATETIMEOFFSET) AS DATETIME2(0)) AS fecha_inicio,
             CAST(TRY_CAST(NULLIF(c.period_endDate,'') AS DATETIMEOFFSET) AS DATETIME2(0)) AS fecha_fin,
             TRY_CAST(NULLIF(c.period_durationInDays,'') AS INT) AS duracion,
             CAST(NULLIF(c.value_currency,'') AS NVARCHAR(3)) AS moneda,
             TRY_CAST(NULLIF(c.value_amount,'') AS DECIMAL(18,2)) AS monto,
             CAST(NULLIF(c.implementation_finalValue_currency,'') AS NVARCHAR(3)) AS moneda_final,
             TRY_CAST(NULLIF(c.implementation_finalValue_amount,'') AS DECIMAL(18,2)) AS monto_final,
             CAST(NULLIF(c.status,'') AS NVARCHAR(50)) AS estado,
             CAST(NULLIF(c.statusDetails,'') AS NVARCHAR(100)) AS estado_detalle
      FROM stg.contracts c
      JOIN #proc pr ON pr.main_id = CAST(c.main_id AS NVARCHAR(300)) AND pr.archivo_origen = c.archivo_origen
      WHERE NULLIF(c.id,'') IS NOT NULL
    ) x
    JOIN core.proceso p ON p.main_id = x.main_id
    LEFT JOIN core.proveedor v ON v.proveedor_key = x.prov_key;

    -- 8. Items
    INSERT core.item (proceso_id, item_key, posicion, descripcion, cantidad, unidad, moneda, monto_original, monto_pen,
                      clasificacion_id, clasificacion_desc)
    SELECT p.proceso_id,
           CAST(NULLIF(i.id,'') AS NVARCHAR(50)),
           TRY_CAST(NULLIF(i.position,'') AS INT),
           CAST(LEFT(NULLIF(i.description,''),1000) AS NVARCHAR(1000)),
           TRY_CAST(NULLIF(i.quantity,'') AS DECIMAL(18,3)),
           CAST(LEFT(NULLIF(i.unit_name,''),200) AS NVARCHAR(200)),
           CAST(NULLIF(i.totalValue_currency,'') AS NVARCHAR(3)),
           TRY_CAST(NULLIF(i.totalValue_amount,'') AS DECIMAL(18,2)),
           CASE WHEN i.totalValue_currency = 'PEN' THEN TRY_CAST(NULLIF(i.totalValue_amount,'') AS DECIMAL(18,2)) END,
           CAST(NULLIF(i.classification_id,'') AS NVARCHAR(50)),
           CAST(LEFT(NULLIF(i.classification_description,''),500) AS NVARCHAR(500))
    FROM stg.tender_items i
    JOIN core.proceso p ON p.main_id = CAST(i.main_id AS NVARCHAR(300)) AND p.archivo_origen = i.archivo_origen;

    SELECT @n = COUNT_BIG(*) FROM core.proceso;
    INSERT @log VALUES (@etapa, @t, SYSDATETIME(), @n);

    /* ------------------------------------------------------------------ */
    SET @etapa = N'core: tipos de cambio y proveedores faltantes'; SET @t = SYSDATETIME();

    -- Tasas oficiales del archivo
    UPDATE a SET a.monto_pen = a.monto_original * r.rate
    FROM core.adjudicacion a
    JOIN core.proceso p ON p.proceso_id = a.proceso_id
    JOIN (SELECT main_id, awards_id, archivo_origen, MAX(TRY_CAST(rate AS DECIMAL(18,8))) AS rate
          FROM stg.awards_value_exchangeRates WHERE currency = 'PEN'
          GROUP BY main_id, awards_id, archivo_origen) r
      ON r.main_id = p.main_id AND r.awards_id = a.award_key AND r.archivo_origen = p.archivo_origen
    WHERE a.moneda <> 'PEN' AND a.monto_original IS NOT NULL AND a.monto_pen IS NULL;

    UPDATE c SET c.monto_pen = c.monto_original * r.rate,
                 c.monto_final_pen = c.monto_final_original * r.rate
    FROM core.contrato c
    JOIN core.proceso p ON p.proceso_id = c.proceso_id
    JOIN (SELECT main_id, contracts_id, archivo_origen, MAX(TRY_CAST(rate AS DECIMAL(18,8))) AS rate
          FROM stg.contracts_value_exchangeRates WHERE currency = 'PEN'
          GROUP BY main_id, contracts_id, archivo_origen) r
      ON r.main_id = p.main_id AND r.contracts_id = c.contrato_key AND r.archivo_origen = p.archivo_origen
    WHERE c.moneda <> 'PEN' AND c.monto_original IS NOT NULL AND c.monto_pen IS NULL;

    -- Sin tasa en el archivo: tasa implicita del proceso
    UPDATE a SET a.monto_pen = a.monto_original * (CAST(p.monto_referencial_pen AS FLOAT) / p.monto_referencial_original),
                 a.pen_inferido = 1
    FROM core.adjudicacion a
    JOIN core.proceso p ON p.proceso_id = a.proceso_id
    WHERE a.monto_pen IS NULL AND a.monto_original IS NOT NULL AND a.moneda <> 'PEN'
      AND p.moneda = a.moneda AND p.monto_referencial_original > 0 AND p.monto_referencial_pen IS NOT NULL;

    UPDATE c SET c.monto_pen = c.monto_original * (CAST(p.monto_referencial_pen AS FLOAT) / p.monto_referencial_original),
                 c.monto_final_pen = c.monto_final_original * (CAST(p.monto_referencial_pen AS FLOAT) / p.monto_referencial_original),
                 c.pen_inferido = 1
    FROM core.contrato c
    JOIN core.proceso p ON p.proceso_id = c.proceso_id
    WHERE c.monto_pen IS NULL AND c.monto_original IS NOT NULL AND c.moneda <> 'PEN'
      AND p.moneda = c.moneda AND p.monto_referencial_original > 0 AND p.monto_referencial_pen IS NOT NULL;

    -- Proveedores que aparecen en adjudicaciones/contratos pero no en postores
    DROP TABLE IF EXISTS #faltan, #nom;
    SELECT prov_key INTO #faltan FROM (
      SELECT 'PE-RUC-' + SUBSTRING(award_key, CHARINDEX('-', award_key) + 1, 30) AS prov_key
      FROM core.adjudicacion WHERE proveedor_id IS NULL AND CHARINDEX('-', award_key) > 0
      UNION
      SELECT 'PE-RUC-' + SUBSTRING(award_key, CHARINDEX('-', award_key) + 1, 30)
      FROM core.contrato WHERE proveedor_id IS NULL AND award_key IS NOT NULL AND CHARINDEX('-', award_key) > 0
    ) k;

    SELECT f.prov_key, MAX(CAST(LEFT(NULLIF(LTRIM(RTRIM(UPPER(REPLACE(p.name, N'"', N'')))), N''), 500) AS NVARCHAR(500))) AS nombre
    INTO #nom
    FROM #faltan f
    JOIN stg.parties p ON p.id = f.prov_key
    GROUP BY f.prov_key;

    INSERT core.proveedor (proveedor_key, ruc, nombre, tipo_contribuyente)
    SELECT f.prov_key, SUBSTRING(f.prov_key, 8, 20), ISNULL(n.nombre, N'Sin nombre en la fuente'),
           CASE WHEN f.prov_key LIKE 'PE-RUC-20%' THEN N'Persona jurídica'
                WHEN f.prov_key LIKE 'PE-RUC-10%' THEN N'Persona natural'
                WHEN f.prov_key LIKE 'PE-RUC-L%' OR f.prov_key LIKE 'PE-RUC-99%' THEN N'Extranjero / sin RUC'
                WHEN f.prov_key LIKE 'PE-RUC-[0-9]%' THEN N'Consorcio'
                ELSE N'Otro' END
    FROM #faltan f
    LEFT JOIN #nom n ON n.prov_key = f.prov_key
    WHERE NOT EXISTS (SELECT 1 FROM core.proveedor v WHERE v.proveedor_key = f.prov_key);

    UPDATE a SET a.proveedor_id = v.proveedor_id
    FROM core.adjudicacion a
    JOIN core.proveedor v ON v.proveedor_key = 'PE-RUC-' + SUBSTRING(a.award_key, CHARINDEX('-', a.award_key) + 1, 30)
    WHERE a.proveedor_id IS NULL AND CHARINDEX('-', a.award_key) > 0;

    UPDATE c SET c.proveedor_id = v.proveedor_id
    FROM core.contrato c
    JOIN core.proveedor v ON v.proveedor_key = 'PE-RUC-' + SUBSTRING(c.award_key, CHARINDEX('-', c.award_key) + 1, 30)
    WHERE c.proveedor_id IS NULL AND c.award_key IS NOT NULL AND CHARINDEX('-', c.award_key) > 0;

    SELECT @n = COUNT_BIG(*) FROM core.proveedor;
    INSERT @log VALUES (@etapa, @t, SYSDATETIME(), @n);

    /* ------------------------------------------------------------------ */
    SET @etapa = N'dw: modelo estrella'; SET @t = SYSDATETIME();

    -- Dimensiones
    CREATE TABLE dw.dim_fecha (
      fecha_key INT NOT NULL CONSTRAINT PK_dim_fecha PRIMARY KEY,
      fecha DATE NOT NULL, anio SMALLINT NOT NULL, trimestre TINYINT NOT NULL,
      mes TINYINT NOT NULL, nombre_mes NVARCHAR(12) NOT NULL, anio_mes CHAR(7) NOT NULL,
      dia TINYINT NOT NULL, dia_semana TINYINT NOT NULL
    );
    ;WITH n AS (
      SELECT TOP (DATEDIFF(DAY, @dim_ini, @dim_fin) + 1) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
      FROM sys.all_objects a CROSS JOIN sys.all_objects b
    ), d AS (SELECT DATEADD(DAY, i, @dim_ini) AS f FROM n)
    INSERT dw.dim_fecha (fecha_key, fecha, anio, trimestre, mes, nombre_mes, anio_mes, dia, dia_semana)
    SELECT YEAR(f)*10000 + MONTH(f)*100 + DAY(f), f, YEAR(f), DATEPART(QUARTER, f), MONTH(f),
           CHOOSE(MONTH(f), N'Enero', N'Febrero', N'Marzo', N'Abril', N'Mayo', N'Junio', N'Julio', N'Agosto',
                            N'Setiembre', N'Octubre', N'Noviembre', N'Diciembre'),
           CONCAT(YEAR(f), '-', RIGHT('0' + CAST(MONTH(f) AS VARCHAR(2)), 2)),
           DAY(f), (DATEDIFF(DAY, '1900-01-01', f) % 7) + 1      -- 1 = lunes (1900-01-01 fue lunes)
    FROM d;

    CREATE TABLE dw.dim_entidad (
      entidad_id INT NOT NULL CONSTRAINT PK_dim_entidad PRIMARY KEY,
      codigo_consucode NVARCHAR(20) NULL, nombre NVARCHAR(500) NOT NULL,
      departamento NVARCHAR(100) NULL, provincia NVARCHAR(100) NULL, distrito NVARCHAR(100) NULL
    );
    INSERT dw.dim_entidad (entidad_id, codigo_consucode, nombre, departamento, provincia, distrito)
    SELECT entidad_id, codigo_consucode, nombre, ISNULL(departamento, N'Sin dato'), provincia, distrito FROM core.entidad;

    CREATE TABLE dw.dim_proveedor (
      proveedor_id INT NOT NULL CONSTRAINT PK_dim_proveedor PRIMARY KEY,
      ruc NVARCHAR(20) NULL, nombre NVARCHAR(500) NOT NULL, tipo_contribuyente NVARCHAR(30) NULL
    );
    INSERT dw.dim_proveedor (proveedor_id, ruc, nombre, tipo_contribuyente)
    SELECT proveedor_id, ruc, nombre, tipo_contribuyente FROM core.proveedor;

    CREATE TABLE dw.dim_procedimiento (
      procedimiento_id INT NOT NULL CONSTRAINT PK_dim_procedimiento PRIMARY KEY,
      detalle NVARCHAR(200) NOT NULL, familia NVARCHAR(100) NOT NULL
    );
    INSERT dw.dim_procedimiento (procedimiento_id, detalle, familia)
    SELECT procedimiento_id, detalle, familia FROM core.procedimiento;

    CREATE TABLE dw.dim_categoria (
      categoria_id INT NOT NULL CONSTRAINT PK_dim_categoria PRIMARY KEY,
      nombre NVARCHAR(100) NOT NULL
    );
    INSERT dw.dim_categoria (categoria_id, nombre) SELECT categoria_id, nombre FROM core.categoria;

    -- Hecho: una fila por proceso
    CREATE TABLE dw.fact_proceso (
      proceso_id INT NOT NULL CONSTRAINT PK_fact_proceso PRIMARY KEY,
      ocid NVARCHAR(200) NOT NULL,
      entidad_id INT NULL, categoria_id INT NULL, procedimiento_id INT NULL,
      fecha_publicacion_key INT NULL, fecha_adjudicacion_key INT NULL, fecha_firma_key INT NULL,
      monto_referencial_pen DECIMAL(18,2) NULL,
      monto_adjudicado_pen DECIMAL(18,2) NULL,
      monto_contratado_pen DECIMAL(18,2) NULL,
      monto_final_pen DECIMAL(18,2) NULL,
      n_postores INT NOT NULL, n_adjudicaciones INT NOT NULL, n_contratos INT NOT NULL,
      tiene_adjudicacion BIT NOT NULL, sin_postores BIT NOT NULL, un_solo_postor BIT NOT NULL,
      en_curso BIT NOT NULL, proxy_desierto BIT NOT NULL,
      dias_adjudicacion_firma INT NULL, dias_publicacion_firma INT NULL,
      firma_fuera_rango BIT NOT NULL CONSTRAINT DF_fp_firma DEFAULT 0,
      dias_publicacion_adjudicacion INT NULL
    );

    ;WITH po AS (SELECT proceso_id, COUNT(*) AS n FROM core.postor GROUP BY proceso_id),
    ad AS (SELECT proceso_id, COUNT(*) AS n, SUM(monto_pen) AS monto, MIN(fecha_adjudicacion) AS f
           FROM core.adjudicacion GROUP BY proceso_id),
    co AS (SELECT proceso_id, COUNT(*) AS n, SUM(monto_pen) AS monto,
                  SUM(ISNULL(monto_final_pen, monto_pen)) AS monto_final, MIN(fecha_firma) AS f
           FROM core.contrato WHERE es_duplicado = 0 GROUP BY proceso_id)
    INSERT dw.fact_proceso
      (proceso_id, ocid, entidad_id, categoria_id, procedimiento_id,
       fecha_publicacion_key, fecha_adjudicacion_key, fecha_firma_key,
       monto_referencial_pen, monto_adjudicado_pen, monto_contratado_pen, monto_final_pen,
       n_postores, n_adjudicaciones, n_contratos,
       tiene_adjudicacion, sin_postores, un_solo_postor, en_curso, proxy_desierto,
       dias_adjudicacion_firma, dias_publicacion_firma, firma_fuera_rango, dias_publicacion_adjudicacion)
    SELECT p.proceso_id, p.ocid, p.entidad_id, p.categoria_id, p.procedimiento_id,
           YEAR(p.fecha_publicacion)*10000 + MONTH(p.fecha_publicacion)*100 + DAY(p.fecha_publicacion),
           CASE WHEN v.fa IS NOT NULL THEN YEAR(v.fa)*10000 + MONTH(v.fa)*100 + DAY(v.fa) END,
           CASE WHEN v.ff IS NOT NULL THEN YEAR(v.ff)*10000 + MONTH(v.ff)*100 + DAY(v.ff) END,
           p.monto_referencial_pen, ad.monto, co.monto, co.monto_final,
           ISNULL(po.n,0), ISNULL(ad.n,0), ISNULL(co.n,0),
           CASE WHEN ad.proceso_id IS NOT NULL THEN 1 ELSE 0 END,
           CASE WHEN ISNULL(po.n,0) = 0 THEN 1 ELSE 0 END,
           CASE WHEN ISNULL(po.n,0) = 1 THEN 1 ELSE 0 END,
           CASE WHEN p.fecha_publicacion >= @corte_en_curso THEN 1 ELSE 0 END,
           CASE WHEN ad.proceso_id IS NULL AND p.fecha_publicacion < @corte_en_curso THEN 1 ELSE 0 END,
           CASE WHEN v.ff IS NOT NULL AND DATEDIFF(DAY, ad.f, co.f) >= 0 THEN DATEDIFF(DAY, ad.f, co.f) END,
           CASE WHEN v.ff IS NOT NULL AND DATEDIFF(DAY, p.fecha_publicacion, co.f) >= 0 THEN DATEDIFF(DAY, p.fecha_publicacion, co.f) END,
           CASE WHEN co.f IS NOT NULL AND v.ff IS NULL THEN 1 ELSE 0 END,
           CASE WHEN DATEDIFF(DAY, p.fecha_publicacion, ad.f) >= 0 THEN DATEDIFF(DAY, p.fecha_publicacion, ad.f) END
    FROM core.proceso p
    LEFT JOIN po ON po.proceso_id = p.proceso_id
    LEFT JOIN ad ON ad.proceso_id = p.proceso_id
    LEFT JOIN co ON co.proceso_id = p.proceso_id
    CROSS APPLY (SELECT CASE WHEN ad.f >= @dim_ini AND ad.f < @dim_fin_excl THEN ad.f END AS fa,
                        CASE WHEN co.f >= @dim_ini AND co.f < @dim_fin_excl THEN co.f END AS ff) v;

    -- Hecho: una fila por adjudicacion
    CREATE TABLE dw.fact_adjudicacion (
      adjudicacion_id INT NOT NULL CONSTRAINT PK_fact_adjudicacion PRIMARY KEY,
      proceso_id INT NOT NULL, entidad_id INT NULL, proveedor_id INT NULL,
      categoria_id INT NULL, procedimiento_id INT NULL, fecha_key INT NULL,
      fecha_publicacion_key INT NULL,      -- fecha de publicacion del proceso (misma base que fact_proceso)
      moneda_original NVARCHAR(3) NULL, monto_pen DECIMAL(18,2) NULL, pen_inferido BIT NOT NULL
    );
    INSERT dw.fact_adjudicacion
      (adjudicacion_id, proceso_id, entidad_id, proveedor_id, categoria_id, procedimiento_id, fecha_key,
       fecha_publicacion_key, moneda_original, monto_pen, pen_inferido)
    SELECT a.adjudicacion_id, a.proceso_id, p.entidad_id, a.proveedor_id, p.categoria_id, p.procedimiento_id,
           CASE WHEN a.fecha_adjudicacion >= @dim_ini AND a.fecha_adjudicacion < @dim_fin_excl
                THEN YEAR(a.fecha_adjudicacion)*10000 + MONTH(a.fecha_adjudicacion)*100 + DAY(a.fecha_adjudicacion) END,
           CASE WHEN p.fecha_publicacion >= @dim_ini AND p.fecha_publicacion < @dim_fin_excl
                THEN YEAR(p.fecha_publicacion)*10000 + MONTH(p.fecha_publicacion)*100 + DAY(p.fecha_publicacion) END,
           a.moneda, a.monto_pen, a.pen_inferido
    FROM core.adjudicacion a
    JOIN core.proceso p ON p.proceso_id = a.proceso_id;

    -- Control de integridad: ambos hechos deben sumar lo mismo
    SELECT @diff = ISNULL((SELECT SUM(monto_adjudicado_pen) FROM dw.fact_proceso), 0)
                 - ISNULL((SELECT SUM(monto_pen) FROM dw.fact_adjudicacion), 0);
    IF ABS(@diff) > 0.01 THROW 50010, N'Reconciliacion fallida: fact_proceso y fact_adjudicacion no suman lo mismo.', 1;

    SELECT @n = COUNT_BIG(*) FROM dw.fact_proceso;
    INSERT @log VALUES (@etapa, @t, SYSDATETIME(), @n);

    /* ------------------------------------------------------------------ */
    SET @etapa = N'claves foraneas dw'; SET @t = SYSDATETIME();

    -- Se crean al final de la carga (más rapido) y validan integridad referencial del modelo estrella.
    ALTER TABLE dw.fact_proceso ADD
      CONSTRAINT FK_fp_entidad FOREIGN KEY (entidad_id)             REFERENCES dw.dim_entidad(entidad_id),
      CONSTRAINT FK_fp_categ   FOREIGN KEY (categoria_id)           REFERENCES dw.dim_categoria(categoria_id),
      CONSTRAINT FK_fp_proced  FOREIGN KEY (procedimiento_id)       REFERENCES dw.dim_procedimiento(procedimiento_id),
      CONSTRAINT FK_fp_fpub    FOREIGN KEY (fecha_publicacion_key)  REFERENCES dw.dim_fecha(fecha_key),
      CONSTRAINT FK_fp_fadj    FOREIGN KEY (fecha_adjudicacion_key) REFERENCES dw.dim_fecha(fecha_key),
      CONSTRAINT FK_fp_ffirma  FOREIGN KEY (fecha_firma_key)        REFERENCES dw.dim_fecha(fecha_key);

    ALTER TABLE dw.fact_adjudicacion ADD
      CONSTRAINT FK_fa_proceso FOREIGN KEY (proceso_id)             REFERENCES dw.fact_proceso(proceso_id),
      CONSTRAINT FK_fa_entidad FOREIGN KEY (entidad_id)             REFERENCES dw.dim_entidad(entidad_id),
      CONSTRAINT FK_fa_prov    FOREIGN KEY (proveedor_id)           REFERENCES dw.dim_proveedor(proveedor_id),
      CONSTRAINT FK_fa_categ   FOREIGN KEY (categoria_id)           REFERENCES dw.dim_categoria(categoria_id),
      CONSTRAINT FK_fa_proced  FOREIGN KEY (procedimiento_id)       REFERENCES dw.dim_procedimiento(procedimiento_id),
      CONSTRAINT FK_fa_fecha   FOREIGN KEY (fecha_key)              REFERENCES dw.dim_fecha(fecha_key),
      CONSTRAINT FK_fa_fpub    FOREIGN KEY (fecha_publicacion_key)  REFERENCES dw.dim_fecha(fecha_key);

    INSERT @log VALUES (@etapa, @t, SYSDATETIME(), NULL);

    /* ------------------------------------------------------------------ */
    SET @etapa = N'indices de rendimiento'; SET @t = SYSDATETIME();

    CREATE NONCLUSTERED INDEX IX_postor_proveedor ON core.postor (proveedor_id);
    CREATE NONCLUSTERED INDEX IX_adjudicacion_proveedor_fecha ON core.adjudicacion (proveedor_id, fecha_adjudicacion)
           INCLUDE (monto_pen, proceso_id);
    CREATE NONCLUSTERED INDEX IX_adjudicacion_proceso ON core.adjudicacion (proceso_id);
    CREATE NONCLUSTERED INDEX IX_proceso_entidad_fecha ON core.proceso (entidad_id, fecha_publicacion)
           INCLUDE (monto_referencial_pen);
    CREATE NONCLUSTERED INDEX IX_item_proceso ON core.item (proceso_id) INCLUDE (clasificacion_desc, monto_pen);
    CREATE NONCLUSTERED INDEX IX_contrato_proceso ON core.contrato (proceso_id);

    INSERT @log VALUES (@etapa, @t, SYSDATETIME(), NULL);

    COMMIT TRAN;

    INSERT etl.carga_log (ejecucion_id, etapa, inicio, fin, filas, estado)
    SELECT @ejecucion_id, etapa, inicio, fin, filas, N'OK' FROM @log;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRAN;

    -- Las etapas ya terminadas quedaron revertidas junto con la transaccion
    INSERT etl.carga_log (ejecucion_id, etapa, inicio, fin, filas, estado)
    SELECT @ejecucion_id, etapa, inicio, fin, filas, N'REVERTIDA' FROM @log;

    INSERT etl.carga_log (ejecucion_id, etapa, inicio, fin, filas, estado, mensaje)
    VALUES (@ejecucion_id, ISNULL(@etapa, N'(inicio)'), ISNULL(@t, SYSDATETIME()), SYSDATETIME(),
            NULL, N'ERROR', LEFT(ERROR_MESSAGE(), 2000));
    THROW;
  END CATCH
END
GO

/* ============================================================================
   3. MAESTRO
   ============================================================================ */
CREATE OR ALTER PROCEDURE etl.sp_ejecutar_pipeline
  @desde          DATE = '2023-01-01',
  @hasta          DATE = '2026-01-01',
  @corte_en_curso DATE = '2025-10-01',
  @carpeta        NVARCHAR(260) = N'C:\datos_oece\',
  @anios          NVARCHAR(100) = N'2023,2024,2025',
  @omitir_staging BIT = 0
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @ej UNIQUEIDENTIFIER = NEWID(), @t0 DATETIME2(3) = SYSDATETIME();

  BEGIN TRY
    IF @omitir_staging = 0
      EXEC etl.sp_cargar_staging @carpeta = @carpeta, @anios = @anios, @ejecucion_id = @ej;

    EXEC etl.sp_construir_modelo @desde = @desde, @hasta = @hasta,
                                 @corte_en_curso = @corte_en_curso, @ejecucion_id = @ej;

    INSERT etl.carga_log (ejecucion_id, etapa, inicio, fin, filas, estado)
    VALUES (@ej, N'PIPELINE COMPLETO', @t0, SYSDATETIME(), NULL, N'OK');
  END TRY
  BEGIN CATCH
    INSERT etl.carga_log (ejecucion_id, etapa, inicio, fin, filas, estado, mensaje)
    VALUES (@ej, N'PIPELINE COMPLETO', @t0, SYSDATETIME(), NULL, N'ERROR', LEFT(ERROR_MESSAGE(), 2000));
    THROW;
  END CATCH

  SELECT etapa, segundos, filas, estado, mensaje
  FROM etl.carga_log WHERE ejecucion_id = @ej ORDER BY log_id;
END
GO

/* ============================================================================
   Bitacora de la ultima ejecucion
   ============================================================================
SELECT etapa, segundos, filas, estado, mensaje
FROM etl.carga_log
WHERE ejecucion_id = (SELECT TOP 1 ejecucion_id FROM etl.carga_log ORDER BY log_id DESC)
ORDER BY log_id;
*/
