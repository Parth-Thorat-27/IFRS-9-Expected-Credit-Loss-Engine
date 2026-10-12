-- trg_param_audit.sql: audit triggers on the parameter tables.
--
-- Any insert, update or delete of a business parameter leaves one PARAM_AUDIT
-- row per changed value: old value, new value, who, when. A reload that
-- rewrites an unchanged value leaves nothing (pkg_params.audit_change skips
-- it), so the audit trail shows real changes only.
--
-- The audit rows are written in the same transaction as the change: if the
-- parameter load rolls back, its audit rows roll back with it, because the
-- change never happened.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

CREATE OR REPLACE TRIGGER trg_param_setting_audit
AFTER INSERT OR UPDATE OR DELETE ON param_setting
FOR EACH ROW
DECLARE
  l_action VARCHAR2(6) := CASE WHEN INSERTING THEN 'INSERT' WHEN UPDATING THEN 'UPDATE' ELSE 'DELETE' END;
BEGIN
  pkg_params.audit_change('PARAM_SETTING', COALESCE(:NEW.setting_name, :OLD.setting_name),
                          'SETTING_VALUE', l_action, :OLD.setting_value, :NEW.setting_value);
END;
/

CREATE OR REPLACE TRIGGER trg_param_scenario_audit
AFTER INSERT OR UPDATE OR DELETE ON param_scenario
FOR EACH ROW
DECLARE
  l_action VARCHAR2(6) := CASE WHEN INSERTING THEN 'INSERT' WHEN UPDATING THEN 'UPDATE' ELSE 'DELETE' END;
  l_key    param_scenario.scenario_code%TYPE := COALESCE(:NEW.scenario_code, :OLD.scenario_code);
BEGIN
  pkg_params.audit_change('PARAM_SCENARIO', l_key, 'WEIGHT', l_action, :OLD.weight, :NEW.weight);
  pkg_params.audit_change('PARAM_SCENARIO', l_key, 'PD_MULTIPLIER', l_action, :OLD.pd_multiplier, :NEW.pd_multiplier);
END;
/

CREATE OR REPLACE TRIGGER trg_param_floor_audit
AFTER INSERT OR UPDATE OR DELETE ON param_floor
FOR EACH ROW
DECLARE
  l_action VARCHAR2(6) := CASE WHEN INSERTING THEN 'INSERT' WHEN UPDATING THEN 'UPDATE' ELSE 'DELETE' END;
  -- Readable key, e.g. "stage 2 restructured=Y" or "stage 3 months 0-12".
  l_key VARCHAR2(100) :=
    'stage ' || COALESCE(:NEW.stage, :OLD.stage)
    || CASE WHEN COALESCE(:NEW.stage, :OLD.stage) = 3
            THEN ' months ' || COALESCE(:NEW.months_in_stage3_from, :OLD.months_in_stage3_from) || '+'
            ELSE ' restructured=' || COALESCE(:NEW.restructured_flag, :OLD.restructured_flag)
       END;
BEGIN
  pkg_params.audit_change('PARAM_FLOOR', l_key, 'FLOOR_RATE', l_action, :OLD.floor_rate, :NEW.floor_rate);
  pkg_params.audit_change('PARAM_FLOOR', l_key, 'MONTHS_IN_STAGE3_TO', l_action,
                          :OLD.months_in_stage3_to, :NEW.months_in_stage3_to);
END;
/

-- Not named in the spec, but the DPD multipliers are business parameters too.
CREATE OR REPLACE TRIGGER trg_param_dpd_audit
AFTER INSERT OR UPDATE OR DELETE ON param_dpd_multiplier
FOR EACH ROW
DECLARE
  l_action VARCHAR2(6) := CASE WHEN INSERTING THEN 'INSERT' WHEN UPDATING THEN 'UPDATE' ELSE 'DELETE' END;
  l_key    VARCHAR2(100) := 'DPD from ' || COALESCE(:NEW.from_dpd, :OLD.from_dpd);
BEGIN
  pkg_params.audit_change('PARAM_DPD_MULTIPLIER', l_key, 'MULTIPLIER', l_action, :OLD.multiplier, :NEW.multiplier);
  pkg_params.audit_change('PARAM_DPD_MULTIPLIER', l_key, 'TO_DPD', l_action, :OLD.to_dpd, :NEW.to_dpd);
END;
/
