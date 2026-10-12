-- check_install.sql: fail the install if anything is left invalid.
--
-- SQL*Plus treats "created with compilation errors" as a warning, not an
-- error, so without this check a broken package would install "successfully"
-- and only fail at 6 a.m. in the batch.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

-- Objects created before something they depend on start out invalid;
-- recompile those first so only real errors remain.
BEGIN
  DBMS_UTILITY.COMPILE_SCHEMA(schema => USER, compile_all => FALSE);
END;
/

DECLARE
  l_invalid VARCHAR2(4000);
  l_errors  VARCHAR2(4000);
BEGIN
  SELECT LISTAGG(object_type || ' ' || object_name, ', ') WITHIN GROUP (ORDER BY object_name)
    INTO l_invalid
    FROM user_objects
   WHERE status = 'INVALID';

  IF l_invalid IS NOT NULL THEN
    SELECT SUBSTR(LISTAGG(name || ' line ' || line || ': ' || text, ' | ')
                    WITHIN GROUP (ORDER BY name, type, sequence), 1, 3000)
      INTO l_errors
      FROM user_errors
     WHERE attribute = 'ERROR';
    RAISE_APPLICATION_ERROR(-20001, 'invalid objects: ' || l_invalid || ' -- ' || l_errors);
  END IF;
  DBMS_OUTPUT.PUT_LINE('install check passed: no invalid objects');
END;
/
