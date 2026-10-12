"""Validate the ECL parameter XML against its XSD.

The monthly batch runs this before PKG_PARAMS loads the file, so a typo in
the XML stops the run with a line number instead of reaching the database.

Usage: python python/ecl/validate_xml.py [XML] [--xsd XSD]
       defaults: config/ecl_parameters.xml and config/ecl_parameters.xsd
Exit code 0 when valid, 1 when not.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from lxml import etree

CONFIG_DIR = Path(__file__).resolve().parents[2] / "config"


def validate(xml_path: str | Path, xsd_path: str | Path) -> list[str]:
    """Return a list of problems; empty means the file is valid."""
    # No entity expansion and no network access: a config file has no reason
    # to pull in anything from outside itself.
    parser = etree.XMLParser(resolve_entities=False, no_network=True)
    schema = etree.XMLSchema(etree.parse(str(xsd_path), parser))
    try:
        doc = etree.parse(str(xml_path), parser)
    except etree.XMLSyntaxError as exc:
        return [f"not well-formed XML: {exc}"]
    except OSError as exc:
        return [f"cannot read the file: {exc}"]
    if schema.validate(doc):
        return []
    return [f"line {e.line}: {e.message}" for e in schema.error_log]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("xml", nargs="?", default=CONFIG_DIR / "ecl_parameters.xml")
    parser.add_argument("--xsd", default=CONFIG_DIR / "ecl_parameters.xsd")
    args = parser.parse_args()

    problems = validate(args.xml, args.xsd)
    if problems:
        print(f"INVALID {args.xml} against {args.xsd}:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    print(f"valid: {args.xml} passes {Path(args.xsd).name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
