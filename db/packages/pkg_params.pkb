CREATE OR REPLACE PACKAGE BODY pkg_params AS

  -- Settings the engine reads. A file without any of them is rejected now,
  -- not when some later step first asks for the missing value.
  c_required_settings CONSTANT VARCHAR2(400) :=
    'STAGE2_DPD,STAGE3_DPD,SICR_RELATIVE,SICR_ABSOLUTE,CURE_MONTHS,'
    || 'PD_FLOOR,PD_CAP,LGD_MIN_DEFAULTS,DQ_MAX_REJECT_SHARE';

  PROCEDURE reject(p_message IN VARCHAR2) IS
  BEGIN
    RAISE_APPLICATION_ERROR(-20010, 'parameter file rejected: ' || p_message);
  END reject;

  -- Readable number text for the audit trail: 0.6 rather than Oracle's ".6".
  FUNCTION fmt(p_value IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN RTRIM(TO_CHAR(p_value, 'FM9999999990.9999999999'), '.');
  END fmt;

  ----------------------------------------------------------------------------
  -- Checks the XSD can't express. They all run before anything is written,
  -- so a bad file never leaves a half-loaded parameter set behind.
  ----------------------------------------------------------------------------
  PROCEDURE check_rules(p_xml IN XMLTYPE) IS
    l_sum   NUMBER;
    l_list  VARCHAR2(4000);
  BEGIN
    -- Scenario weights are probabilities, so they must add up to exactly 1.
    SELECT SUM(x.weight) INTO l_sum
      FROM XMLTABLE('/eclParameters/scenarios/scenario' PASSING p_xml
                    COLUMNS weight NUMBER PATH '@weight') x;
    IF l_sum IS NULL OR ABS(l_sum - 1) > 1e-9 THEN
      reject('scenario weights sum to ' || fmt(l_sum) || ', not 1');
    END IF;

    SELECT LISTAGG(r.name, ', ') WITHIN GROUP (ORDER BY r.name) INTO l_list
      FROM (SELECT REGEXP_SUBSTR(c_required_settings, '[^,]+', 1, LEVEL) AS name
              FROM dual
           CONNECT BY LEVEL <= REGEXP_COUNT(c_required_settings, ',') + 1) r
     WHERE r.name NOT IN (SELECT x.name
                            FROM XMLTABLE('/eclParameters/settings/setting' PASSING p_xml
                                          COLUMNS name VARCHAR2(40) PATH '@name') x);
    IF l_list IS NOT NULL THEN
      reject('missing settings: ' || l_list);
    END IF;

    -- Stages 1 and 2 are split by restructured status, Stage 3 by time in Stage 3.
    SELECT LISTAGG('stage ' || f.stage, ', ') WITHIN GROUP (ORDER BY f.stage) INTO l_list
      FROM XMLTABLE('/eclParameters/floors/floor' PASSING p_xml
                    COLUMNS stage        NUMBER      PATH '@stage',
                            restructured VARCHAR2(1) PATH '@restructured',
                            m_from       NUMBER      PATH '@monthsInStage3From') f
     WHERE (f.stage IN (1, 2) AND (f.restructured IS NULL OR f.m_from IS NOT NULL))
        OR (f.stage = 3 AND (f.m_from IS NULL OR f.restructured IS NOT NULL));
    IF l_list IS NOT NULL THEN
      reject('floor rows with the wrong attributes for their stage: ' || l_list
             || ' (stages 1-2 need restructured, stage 3 needs monthsInStage3From)');
    END IF;

    -- Every loan must find a floor: each stage 1/2 case, and a Stage 3 band from month 0.
    SELECT LISTAGG(c.case_name, ', ') WITHIN GROUP (ORDER BY c.case_name) INTO l_list
      FROM (SELECT 1 stage, 'N' flag, 'stage 1 not restructured' case_name FROM dual UNION ALL
            SELECT 1, 'Y', 'stage 1 restructured' FROM dual UNION ALL
            SELECT 2, 'N', 'stage 2 not restructured' FROM dual UNION ALL
            SELECT 2, 'Y', 'stage 2 restructured' FROM dual UNION ALL
            SELECT 3, NULL, 'stage 3 from month 0' FROM dual) c
     WHERE NOT EXISTS (
             SELECT 1
               FROM XMLTABLE('/eclParameters/floors/floor' PASSING p_xml
                             COLUMNS stage        NUMBER      PATH '@stage',
                                     restructured VARCHAR2(1) PATH '@restructured',
                                     m_from       NUMBER      PATH '@monthsInStage3From') f
              WHERE f.stage = c.stage
                AND (   (c.stage IN (1, 2) AND f.restructured = c.flag)
                     OR (c.stage = 3 AND f.m_from = 0)));
    IF l_list IS NOT NULL THEN
      reject('no floor for: ' || l_list);
    END IF;

    -- DPD bands must start at 0 and must not overlap, or a loan could get two multipliers.
    SELECT LISTAGG(b.from_dpd || '-' || b.to_dpd, ', ') WITHIN GROUP (ORDER BY b.from_dpd) INTO l_list
      FROM (SELECT x.from_dpd, x.to_dpd,
                   LAG(x.to_dpd) OVER (ORDER BY x.from_dpd) AS prev_to,
                   ROW_NUMBER() OVER (ORDER BY x.from_dpd)  AS rn
              FROM XMLTABLE('/eclParameters/dpdMultipliers/band' PASSING p_xml
                            COLUMNS from_dpd NUMBER PATH '@fromDpd',
                                    to_dpd   NUMBER PATH '@toDpd') x) b
     WHERE b.to_dpd < b.from_dpd
        OR b.from_dpd <= b.prev_to
        OR (b.rn = 1 AND b.from_dpd <> 0);
    IF l_list IS NOT NULL THEN
      reject('DPD bands overlap, are reversed or do not start at 0: ' || l_list);
    END IF;
  END check_rules;

  ----------------------------------------------------------------------------
  -- Load: MERGE each part into its table, then delete rows the file no longer
  -- has. The audit triggers record every value that actually changed.
  ----------------------------------------------------------------------------
  PROCEDURE load_xml(p_xml            IN XMLTYPE,
                     p_source         IN VARCHAR2,
                     p_run_id         IN NUMBER,
                     p_reporting_date IN DATE) IS
    l_step   NUMBER;
    l_floors_source param_floor.source%TYPE;
    l_rows   PLS_INTEGER := 0;
    l_counts VARCHAR2(200);
  BEGIN
    l_step := pkg_batch_log.start_step(NVL(p_run_id, pkg_batch_log.new_run_id),
                                       p_reporting_date, 'LOAD_PARAMS');
    check_rules(p_xml);

    MERGE INTO param_setting t
    USING (SELECT x.name, x.value, x.description
             FROM XMLTABLE('/eclParameters/settings/setting' PASSING p_xml
                           COLUMNS name        VARCHAR2(40)  PATH '@name',
                                   value       NUMBER        PATH '@value',
                                   description VARCHAR2(200) PATH '@description') x) s
       ON (t.setting_name = s.name)
     WHEN MATCHED THEN UPDATE SET t.setting_value = s.value, t.description = s.description,
                                  t.source_file = p_source, t.loaded_ts = SYSTIMESTAMP
     WHEN NOT MATCHED THEN INSERT (setting_name, setting_value, description, source_file)
                           VALUES (s.name, s.value, s.description, p_source);
    l_rows := l_rows + SQL%ROWCOUNT;
    DELETE FROM param_setting
     WHERE setting_name NOT IN (SELECT x.name FROM XMLTABLE('/eclParameters/settings/setting' PASSING p_xml
                                                            COLUMNS name VARCHAR2(40) PATH '@name') x);

    MERGE INTO param_scenario t
    USING (SELECT x.code, x.weight, x.pd_multiplier
             FROM XMLTABLE('/eclParameters/scenarios/scenario' PASSING p_xml
                           COLUMNS code          VARCHAR2(20) PATH '@code',
                                   weight        NUMBER       PATH '@weight',
                                   pd_multiplier NUMBER       PATH '@pdMultiplier') x) s
       ON (t.scenario_code = s.code)
     WHEN MATCHED THEN UPDATE SET t.weight = s.weight, t.pd_multiplier = s.pd_multiplier,
                                  t.loaded_ts = SYSTIMESTAMP
     WHEN NOT MATCHED THEN INSERT (scenario_code, weight, pd_multiplier)
                           VALUES (s.code, s.weight, s.pd_multiplier);
    l_rows := l_rows + SQL%ROWCOUNT;
    DELETE FROM param_scenario
     WHERE scenario_code NOT IN (SELECT x.code FROM XMLTABLE('/eclParameters/scenarios/scenario' PASSING p_xml
                                                             COLUMNS code VARCHAR2(20) PATH '@code') x);

    MERGE INTO param_dpd_multiplier t
    USING (SELECT x.from_dpd, x.to_dpd, x.multiplier
             FROM XMLTABLE('/eclParameters/dpdMultipliers/band' PASSING p_xml
                           COLUMNS from_dpd   NUMBER PATH '@fromDpd',
                                   to_dpd     NUMBER PATH '@toDpd',
                                   multiplier NUMBER PATH '@multiplier') x) s
       ON (t.from_dpd = s.from_dpd)
     WHEN MATCHED THEN UPDATE SET t.to_dpd = s.to_dpd, t.multiplier = s.multiplier,
                                  t.loaded_ts = SYSTIMESTAMP
     WHEN NOT MATCHED THEN INSERT (from_dpd, to_dpd, multiplier)
                           VALUES (s.from_dpd, s.to_dpd, s.multiplier);
    l_rows := l_rows + SQL%ROWCOUNT;
    DELETE FROM param_dpd_multiplier
     WHERE from_dpd NOT IN (SELECT x.from_dpd FROM XMLTABLE('/eclParameters/dpdMultipliers/band' PASSING p_xml
                                                            COLUMNS from_dpd NUMBER PATH '@fromDpd') x);

    SELECT x.source INTO l_floors_source
      FROM XMLTABLE('/eclParameters/floors' PASSING p_xml
                    COLUMNS source VARCHAR2(200) PATH '@source') x;

    -- Stage 3 rows have no restructured flag ("*" = any) and Stage 1/2 rows
    -- no time band (from month 0), so every row still has a full natural key.
    MERGE INTO param_floor t
    USING (SELECT x.stage,
                  NVL(x.restructured, '*') AS restructured_flag,
                  NVL(x.m_from, 0)         AS months_from,
                  x.m_to                   AS months_to,
                  x.rate
             FROM XMLTABLE('/eclParameters/floors/floor' PASSING p_xml
                           COLUMNS stage        NUMBER      PATH '@stage',
                                   restructured VARCHAR2(1) PATH '@restructured',
                                   m_from       NUMBER      PATH '@monthsInStage3From',
                                   m_to         NUMBER      PATH '@monthsInStage3To',
                                   rate         NUMBER      PATH '@rate') x) s
       ON (    t.stage = s.stage
           AND t.restructured_flag = s.restructured_flag
           AND t.months_in_stage3_from = s.months_from)
     WHEN MATCHED THEN UPDATE SET t.months_in_stage3_to = s.months_to, t.floor_rate = s.rate,
                                  t.source = l_floors_source, t.loaded_ts = SYSTIMESTAMP
     WHEN NOT MATCHED THEN INSERT (stage, restructured_flag, months_in_stage3_from,
                                   months_in_stage3_to, floor_rate, source)
                           VALUES (s.stage, s.restructured_flag, s.months_from,
                                   s.months_to, s.rate, l_floors_source);
    l_rows := l_rows + SQL%ROWCOUNT;
    DELETE FROM param_floor t
     WHERE NOT EXISTS (
             SELECT 1
               FROM XMLTABLE('/eclParameters/floors/floor' PASSING p_xml
                             COLUMNS stage        NUMBER      PATH '@stage',
                                     restructured VARCHAR2(1) PATH '@restructured',
                                     m_from       NUMBER      PATH '@monthsInStage3From') x
              WHERE x.stage = t.stage
                AND NVL(x.restructured, '*') = t.restructured_flag
                AND NVL(x.m_from, 0) = t.months_in_stage3_from);

    SELECT (SELECT COUNT(*) FROM param_setting) || ' settings, '
        || (SELECT COUNT(*) FROM param_dpd_multiplier) || ' DPD bands, '
        || (SELECT COUNT(*) FROM param_scenario) || ' scenarios, '
        || (SELECT COUNT(*) FROM param_floor) || ' floors'
      INTO l_counts FROM dual;

    COMMIT;
    pkg_batch_log.end_step(l_step, 'SUCCESS', l_rows, p_source || ': ' || l_counts);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      IF l_step IS NOT NULL THEN
        pkg_batch_log.end_step(l_step, 'FAILED', NULL, p_source || ': ' || pkg_batch_log.error_text);
      END IF;
      RAISE;
  END load_xml;

  PROCEDURE load_from_xml(p_file_name      IN VARCHAR2 DEFAULT 'ecl_parameters.xml',
                          p_run_id         IN NUMBER   DEFAULT NULL,
                          p_reporting_date IN DATE     DEFAULT NULL) IS
  BEGIN
    -- BFILENAME points at the file through the directory object; XMLTYPE
    -- reads and parses it, assuming UTF-8 as the XML declaration says.
    load_xml(XMLTYPE(BFILENAME('ECL_CONFIG_DIR', p_file_name), NLS_CHARSET_ID('AL32UTF8')),
             p_file_name, p_run_id, p_reporting_date);
  END load_from_xml;

  PROCEDURE load_from_clob(p_xml            IN CLOB,
                           p_source         IN VARCHAR2,
                           p_run_id         IN NUMBER DEFAULT NULL,
                           p_reporting_date IN DATE   DEFAULT NULL) IS
  BEGIN
    load_xml(XMLTYPE(p_xml), p_source, p_run_id, p_reporting_date);
  END load_from_clob;

  FUNCTION get_number(p_name IN VARCHAR2) RETURN NUMBER IS
    l_value param_setting.setting_value%TYPE;
  BEGIN
    SELECT setting_value INTO l_value FROM param_setting WHERE setting_name = UPPER(p_name);
    RETURN l_value;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20011, 'parameter ' || p_name
                              || ' is not loaded: run pkg_params.load_from_xml first');
  END get_number;

  PROCEDURE audit_change(p_table  IN VARCHAR2,
                         p_key    IN VARCHAR2,
                         p_column IN VARCHAR2,
                         p_action IN VARCHAR2,
                         p_old    IN NUMBER,
                         p_new    IN NUMBER) IS
    -- fmt is private to this body, and SQL can only call functions declared
    -- in the package spec, so the text is built here in PL/SQL first.
    l_old param_audit.old_value%TYPE := fmt(p_old);
    l_new param_audit.new_value%TYPE := fmt(p_new);
  BEGIN
    -- A reload rewrites every row; only a value that differs is a change.
    -- (Null-safe: "=" alone would treat null-to-null as different.)
    IF p_action = 'UPDATE'
       AND (p_old = p_new OR (p_old IS NULL AND p_new IS NULL)) THEN
      RETURN;
    END IF;
    INSERT INTO param_audit (table_name, param_key, column_name, action, old_value, new_value, changed_by)
    VALUES (p_table, p_key, p_column, p_action, l_old, l_new,
            SYS_CONTEXT('USERENV', 'SESSION_USER'));
  END audit_change;

END pkg_params;
/
