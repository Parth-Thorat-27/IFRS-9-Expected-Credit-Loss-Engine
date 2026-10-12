CREATE OR REPLACE PACKAGE pkg_params AS
  -- Loads config/ecl_parameters.xml into the PARAM_* tables and serves the
  -- values to the rest of the engine. Every business assumption (staging
  -- thresholds, multipliers, scenario weights, floors) comes from there;
  -- nothing in the PL/SQL is hardcoded.
  --
  -- The XSD has already checked structure and types (validate_xml.py). This
  -- package adds the checks that involve several values at once, and loads
  -- nothing unless every check passes.

  -- Read the file through the ECL_CONFIG_DIR directory object and load it.
  PROCEDURE load_from_xml(p_file_name      IN VARCHAR2 DEFAULT 'ecl_parameters.xml',
                          p_run_id         IN NUMBER   DEFAULT NULL,
                          p_reporting_date IN DATE     DEFAULT NULL);

  -- Same load from XML text: for tests, or when files can't be mounted.
  PROCEDURE load_from_clob(p_xml            IN CLOB,
                           p_source         IN VARCHAR2,
                           p_run_id         IN NUMBER DEFAULT NULL,
                           p_reporting_date IN DATE   DEFAULT NULL);

  -- Value of a PARAM_SETTING row; raises if the setting has not been loaded.
  FUNCTION get_number(p_name IN VARCHAR2) RETURN NUMBER;

  -- Called by the parameter audit triggers: writes one PARAM_AUDIT row when
  -- the value really changed (INSERT and DELETE always count as a change).
  PROCEDURE audit_change(p_table  IN VARCHAR2,
                         p_key    IN VARCHAR2,
                         p_column IN VARCHAR2,
                         p_action IN VARCHAR2,
                         p_old    IN NUMBER,
                         p_new    IN NUMBER);
END pkg_params;
/
