#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import json
from pathlib import Path
import xml.etree.ElementTree as ET

from .logging_utils import fatal


def load_json_text(text: str, source: str = "input"):
    if text is None or text == "":
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        fatal(f"Invalid JSON in {source}: {exc}")


def read_json_file(path: str):
    file_path = Path(path)
    if not file_path.is_file():
        fatal(f"JSON config file not set or not found: {path}")
    try:
        with file_path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except json.JSONDecodeError as exc:
        fatal(f"Invalid JSON in {path}: {exc}")


def parse_xml_config(path: str):
    file_path = Path(path)
    if not file_path.is_file():
        fatal(f"Config file not found: {path}")
    try:
        tree = ET.parse(file_path)
        return tree.getroot()
    except ET.ParseError as exc:
        fatal(f"Failed to parse XML config at {path}: {exc}")


def xml_text(root: ET.Element, *path_parts: str) -> str:
    query = "/".join(path_parts)
    element = root.find(query)
    if element is not None and element.text is not None:
        return element.text.strip()
    for candidate in root.iter(path_parts[-1]):
        if candidate.text is not None:
            return candidate.text.strip()
    return ""
