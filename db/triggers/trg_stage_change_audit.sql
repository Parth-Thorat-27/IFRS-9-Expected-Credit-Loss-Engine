-- trg_stage_change_audit.sql: record every change of a loan's stage.
--
-- Why on LOAN_STAGE_CURRENT and not on ECL_RESULT: a row-level trigger that
-- reads the table it is defined on hits the mutating-table error (ORA-04091).
-- Detecting a change on ECL_RESULT would mean reading last month's row of
-- ECL_RESULT from inside ECL_RESULT's own trigger. On LOAN_STAGE_CURRENT the
-- old and new stage are simply :OLD.stage and :NEW.stage, so the trigger
-- never has to query its own table.
--
-- The WHEN clause is evaluated by the SQL engine, so for the vast majority of
-- rows (stage unchanged) the trigger body never runs.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

CREATE OR REPLACE TRIGGER trg_stage_change_audit
AFTER UPDATE OF stage ON loan_stage_current
FOR EACH ROW
WHEN (NEW.stage <> OLD.stage)
BEGIN
  INSERT INTO stage_change_audit (loan_id, reporting_date, old_stage, new_stage,
                                  old_reason, new_reason, changed_by)
  VALUES (:NEW.loan_id, :NEW.reporting_date, :OLD.stage, :NEW.stage,
          :OLD.reason_code, :NEW.reason_code, SYS_CONTEXT('USERENV', 'SESSION_USER'));
END;
/
