"""XML parameters: the XSD catches malformed files, PL/SQL catches weights that
don't sum to 1, the tables match the file, and changes leave audit rows.

Broken copies are fed to PKG_PARAMS as CLOBs (load_from_clob), so the tests
never write files into config/. Every test that changes parameters reloads
the real file at the end, so the engine is never left with test values.
"""
from __future__ import annotations

from decimal import Decimal
from pathlib import Path

import oracledb
import pytest
from lxml import etree

from conftest import ROOT, scalar
from ecl.validate_xml import validate

XML = ROOT / "config" / "ecl_parameters.xml"
XSD = ROOT / "config" / "ecl_parameters.xsd"


def load_clob(cur, xml_text: str, source: str = "pytest") -> None:
    cur.callproc("pkg_params.load_from_clob", [xml_text, source])


def reload_real_file(cur) -> None:
    cur.callproc("pkg_params.load_from_xml", ["ecl_parameters.xml"])


def with_scenario_weights(base: str, downside: str) -> str:
    text = XML.read_text(encoding="utf-8")
    text = text.replace('code="BASE" weight="0.60"', f'code="BASE" weight="{base}"')
    return text.replace('code="DOWNSIDE" weight="0.30"', f'code="DOWNSIDE" weight="{downside}"')


def test_real_file_passes_xsd():
    assert validate(XML, XSD) == []


def test_non_numeric_rate_fails_xsd(tmp_path: Path):
    bad = tmp_path / "bad_rate.xml"
    bad.write_text(XML.read_text(encoding="utf-8").replace('rate="0.0500"', 'rate="five percent"', 1),
                   encoding="utf-8")
    problems = validate(bad, XSD)
    assert problems and any("rate" in p for p in problems), problems


def test_missing_required_attribute_fails_xsd(tmp_path: Path):
    bad = tmp_path / "no_weight.xml"
    bad.write_text(XML.read_text(encoding="utf-8").replace(' weight="0.10"', "", 1), encoding="utf-8")
    assert validate(bad, XSD)


def test_duplicate_scenario_code_fails_xsd(tmp_path: Path):
    bad = tmp_path / "dup_code.xml"
    bad.write_text(XML.read_text(encoding="utf-8").replace('code="SEVERE"', 'code="DOWNSIDE"', 1),
                   encoding="utf-8")
    assert validate(bad, XSD)


def test_weights_summing_to_1_1_pass_xsd_but_fail_plsql(cur, tmp_path: Path):
    text = with_scenario_weights("0.70", "0.30")  # 0.70 + 0.30 + 0.10 = 1.1
    copy = tmp_path / "weights_1_1.xml"
    copy.write_text(text, encoding="utf-8")
    assert validate(copy, XSD) == [], "each weight is within 0-1, so the XSD accepts the file"

    before = scalar(cur, "SELECT SUM(weight) FROM param_scenario")
    with pytest.raises(oracledb.DatabaseError, match="ORA-20010.*weights sum to 1.1"):
        load_clob(cur, text)
    # Rejected before anything was written: the loaded weights are unchanged.
    assert scalar(cur, "SELECT SUM(weight) FROM param_scenario") == before == 1


def test_tables_match_the_file(cur):
    reload_real_file(cur)
    doc = etree.parse(str(XML))

    cur.execute("SELECT setting_name, setting_value FROM param_setting")
    assert dict(cur.fetchall()) == {
        s.get("name"): float(s.get("value")) for s in doc.iterfind("settings/setting")}

    cur.execute("SELECT scenario_code, weight, pd_multiplier FROM param_scenario")
    assert {r[0]: (r[1], r[2]) for r in cur.fetchall()} == {
        s.get("code"): (float(s.get("weight")), float(s.get("pdMultiplier")))
        for s in doc.iterfind("scenarios/scenario")}

    cur.execute("SELECT from_dpd, to_dpd, multiplier FROM param_dpd_multiplier")
    assert sorted(cur.fetchall()) == sorted(
        (int(b.get("fromDpd")), int(b.get("toDpd")), float(b.get("multiplier")))
        for b in doc.iterfind("dpdMultipliers/band"))

    cur.execute("SELECT stage, restructured_flag, months_in_stage3_from, months_in_stage3_to, floor_rate "
                "FROM param_floor")
    expected = []
    for f in doc.iterfind("floors/floor"):
        to = f.get("monthsInStage3To")
        expected.append((int(f.get("stage")), f.get("restructured", "*"),
                         int(f.get("monthsInStage3From", 0)), int(to) if to else None,
                         float(f.get("rate"))))
    assert sorted(cur.fetchall(), key=str) == sorted(expected, key=str)


def test_reload_audits_only_the_values_that_changed(cur):
    reload_real_file(cur)
    start = scalar(cur, "SELECT NVL(MAX(audit_id), 0) FROM param_audit")
    try:
        load_clob(cur, with_scenario_weights("0.65", "0.25"))
        cur.execute("""SELECT param_key, column_name, action, old_value, new_value
                         FROM param_audit WHERE audit_id > :first_id ORDER BY param_key""", first_id=start)
        assert cur.fetchall() == [
            ("BASE", "WEIGHT", "UPDATE", "0.6", "0.65"),
            ("DOWNSIDE", "WEIGHT", "UPDATE", "0.3", "0.25"),
        ]
    finally:
        reload_real_file(cur)
    # Changing back is audited too, and leaves the original weights loaded.
    assert scalar(cur, "SELECT COUNT(*) FROM param_audit WHERE audit_id > :first_id", first_id=start) == 4
    assert scalar(cur, "SELECT weight FROM param_scenario WHERE scenario_code = 'BASE'") == 0.6


def test_get_number_reads_a_setting_and_rejects_unknown_names(cur):
    reload_real_file(cur)
    assert scalar(cur, "SELECT pkg_params.get_number('STAGE2_DPD') FROM dual") == 30
    with pytest.raises(oracledb.DatabaseError, match="ORA-20011"):
        scalar(cur, "SELECT pkg_params.get_number('NO_SUCH_SETTING') FROM dual")
