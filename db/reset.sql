-- reset.sql: drop every object in the current schema, for a clean rebuild.
-- scripts/setup_db.sh --reset runs it as ECL. Safe on an empty schema.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  l_dropped PLS_INTEGER := 0;
BEGIN
  FOR o IN (SELECT object_name, object_type
              FROM user_objects
             WHERE object_type IN ('VIEW', 'TRIGGER', 'PACKAGE', 'PROCEDURE', 'FUNCTION',
                                   'TYPE', 'SYNONYM', 'SEQUENCE', 'TABLE')
               -- Sequences behind identity columns go with their table and
               -- can't be dropped on their own.
               AND object_name NOT LIKE 'ISEQ$$%'
               AND object_name NOT LIKE 'BIN$%'
             ORDER BY CASE object_type WHEN 'TABLE' THEN 2 ELSE 1 END, object_name) LOOP
    -- CASCADE CONSTRAINTS: foreign keys don't dictate the drop order.
    -- PURGE: nothing piles up in the recycle bin across resets.
    EXECUTE IMMEDIATE 'DROP ' || o.object_type || ' "' || o.object_name || '"'
                   || CASE o.object_type WHEN 'TABLE' THEN ' CASCADE CONSTRAINTS PURGE'
                                         WHEN 'TYPE'  THEN ' FORCE' END;
    l_dropped := l_dropped + 1;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('reset: dropped ' || l_dropped || ' objects');
END;
/
