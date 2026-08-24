#!/usr/bin/env python3
"""Extract schedule-shaped source files into compact JSON without mutating them."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import html.parser
import json
import mimetypes
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import zipfile
from xml.etree import ElementTree as ET


def scalar(value):
    if isinstance(value, (dt.datetime, dt.date, dt.time)):
        return value.isoformat()
    return "" if value is None else str(value).strip()


def tabular_records(rows, source, sheet=None):
    rows = [[scalar(cell) for cell in row] for row in rows]
    rows = [row for row in rows if any(row)]
    if not rows:
        return []
    headers = [cell or f"column_{index + 1}" for index, cell in enumerate(rows[0])]
    records = []
    for row_number, row in enumerate(rows[1:], start=2):
        values = row + [""] * max(0, len(headers) - len(row))
        record = {headers[index]: values[index] for index in range(len(headers)) if values[index] != ""}
        if record:
            record["_sourceRef"] = f"{source}#{sheet + ':' if sheet else ''}row-{row_number}"
            records.append(record)
    return records


def parse_csv(path):
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        sample = handle.read(8192)
        handle.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=",\t;|")
        except csv.Error:
            dialect = csv.excel_tab if path.suffix.lower() == ".tsv" else csv.excel
        return tabular_records(csv.reader(handle, dialect), path.name)


def parse_xlsx_openpyxl(path):
    import openpyxl
    workbook = openpyxl.load_workbook(path, read_only=True, data_only=True)
    records = []
    for worksheet in workbook.worksheets:
        records.extend(tabular_records(worksheet.iter_rows(values_only=True), path.name, worksheet.title))
    return records


def parse_xlsx_xml(path):
    ns = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    rel_ns = {"r": "http://schemas.openxmlformats.org/package/2006/relationships"}
    with zipfile.ZipFile(path) as archive:
        shared = []
        if "xl/sharedStrings.xml" in archive.namelist():
            root = ET.fromstring(archive.read("xl/sharedStrings.xml"))
            for item in root.findall("m:si", ns):
                shared.append("".join(node.text or "" for node in item.iterfind(".//m:t", ns)))
        workbook = ET.fromstring(archive.read("xl/workbook.xml"))
        relations = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
        relation_map = {node.attrib["Id"]: node.attrib["Target"] for node in relations.findall("r:Relationship", rel_ns)}
        records = []
        for sheet in workbook.findall("m:sheets/m:sheet", ns):
            relationship = sheet.attrib["{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"]
            target = relation_map[relationship].lstrip("/")
            if not target.startswith("xl/"):
                target = "xl/" + target
            root = ET.fromstring(archive.read(target))
            rows = []
            for row in root.findall(".//m:sheetData/m:row", ns):
                values = []
                for cell in row.findall("m:c", ns):
                    reference = cell.attrib.get("r", "A1")
                    letters = re.match(r"[A-Z]+", reference).group(0)
                    index = 0
                    for letter in letters:
                        index = index * 26 + ord(letter) - 64
                    while len(values) < index:
                        values.append("")
                    value_node = cell.find("m:v", ns)
                    value = value_node.text if value_node is not None else ""
                    if cell.attrib.get("t") == "s" and value:
                        value = shared[int(value)]
                    elif cell.attrib.get("t") == "inlineStr":
                        value = "".join(node.text or "" for node in cell.iterfind(".//m:t", ns))
                    values[index - 1] = value
                rows.append(values)
            records.extend(tabular_records(rows, path.name, sheet.attrib.get("name", "Sheet")))
        return records


def parse_xlsx(path, warnings):
    try:
        return parse_xlsx_openpyxl(path)
    except ImportError:
        warnings.append("openpyxl unavailable; used the built-in XLSX reader, so formula/date formatting may be reduced.")
        return parse_xlsx_xml(path)


def unfold_ics(text):
    lines = []
    for line in text.replace("\r\n", "\n").split("\n"):
        if line.startswith((" ", "\t")) and lines:
            lines[-1] += line[1:]
        else:
            lines.append(line)
    return lines


def decode_ics_text(value):
    return value.replace("\\n", "\n").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")


def ics_datetime(value, parameters):
    timezone = parameters.get("TZID")
    if parameters.get("VALUE") == "DATE" or re.fullmatch(r"\d{8}", value):
        return dt.datetime.strptime(value, "%Y%m%d").date().isoformat()
    is_utc = value.endswith("Z")
    clean = value.rstrip("Z")
    parsed = dt.datetime.strptime(clean, "%Y%m%dT%H%M%S" if len(clean) == 15 else "%Y%m%dT%H%M")
    if is_utc:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    result = parsed.isoformat()
    return {"value": result, "timezone": timezone} if timezone else result


def parse_ics(path):
    events, current, alarm = [], None, None
    for line in unfold_ics(path.read_text(encoding="utf-8-sig", errors="replace")):
        if line == "BEGIN:VEVENT":
            current = {"alerts": []}
            continue
        if line == "END:VEVENT" and current is not None:
            current["_sourceRef"] = f"{path.name}#{current.get('uid', len(events) + 1)}"
            if not current["alerts"]:
                current.pop("alerts")
            events.append(current)
            current = None
            continue
        if current is None:
            continue
        if line == "BEGIN:VALARM":
            alarm = {}
            continue
        if line == "END:VALARM":
            if alarm:
                current["alerts"].append(alarm)
            alarm = None
            continue
        if ":" not in line:
            continue
        left, value = line.split(":", 1)
        parts = left.split(";")
        key = parts[0].upper()
        parameters = dict(part.split("=", 1) for part in parts[1:] if "=" in part)
        target = alarm if alarm is not None else current
        if key in {"DTSTART", "DTEND", "DUE"}:
            target[key.lower()] = ics_datetime(value, parameters)
        elif key == "TRIGGER" and alarm is not None:
            alarm["trigger"] = value
        elif key in {"SUMMARY", "DESCRIPTION", "LOCATION", "URL", "UID", "RRULE", "STATUS"}:
            target[key.lower()] = decode_ics_text(value)
    return events


class VisibleHTML(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.hidden = 0
        self.text = []

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style", "noscript"}:
            self.hidden += 1

    def handle_endtag(self, tag):
        if tag in {"script", "style", "noscript"} and self.hidden:
            self.hidden -= 1
        if tag in {"p", "div", "tr", "li", "br", "h1", "h2", "h3"}:
            self.text.append("\n")

    def handle_data(self, data):
        if not self.hidden and data.strip():
            self.text.append(data.strip() + " ")


def parse_html(path):
    parser = VisibleHTML()
    parser.feed(path.read_text(encoding="utf-8", errors="replace"))
    text = re.sub(r"[ \t]+", " ", "".join(parser.text))
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    return [{"text": text, "_sourceRef": path.name}]


def parse_pdf(path, warnings):
    pages = []
    try:
        from pypdf import PdfReader
        reader = PdfReader(path)
        pages = [{"page": index + 1, "text": page.extract_text() or "", "_sourceRef": f"{path.name}#page-{index + 1}"} for index, page in enumerate(reader.pages)]
    except ImportError:
        executable = shutil.which("pdftotext")
        if executable:
            with tempfile.NamedTemporaryFile(suffix=".txt") as output:
                subprocess.run([executable, str(path), output.name], check=True)
                pages = [{"page": 1, "text": pathlib.Path(output.name).read_text(errors="replace"), "_sourceRef": path.name}]
        else:
            warnings.append("No local PDF text extractor is available; use PDF understanding.")
    return pages


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input")
    args = parser.parse_args()
    raw = args.input
    parsed_url = urllib.parse.urlparse(raw)
    if parsed_url.scheme in {"http", "https"}:
        print(json.dumps({"source": raw, "format": "url", "records": [], "warnings": [], "requiresModel": False, "requiresBrowser": True}, ensure_ascii=False, indent=2))
        return

    path = pathlib.Path(raw).expanduser().resolve()
    if not path.is_file():
        raise SystemExit(f"Input file does not exist: {path}")
    suffix = path.suffix.lower()
    warnings = []
    requires_model = False
    if suffix in {".csv", ".tsv"}:
        records, format_name = parse_csv(path), suffix[1:]
    elif suffix == ".xlsx":
        records, format_name = parse_xlsx(path, warnings), "xlsx"
    elif suffix == ".ics":
        records, format_name = parse_ics(path), "ics"
    elif suffix == ".json":
        payload = json.loads(path.read_text(encoding="utf-8"))
        records, format_name = payload if isinstance(payload, list) else [payload], "json"
    elif suffix in {".html", ".htm"}:
        records, format_name, requires_model = parse_html(path), "html", True
    elif suffix == ".pdf":
        records, format_name = parse_pdf(path, warnings), "pdf"
        requires_model = not records or any(not record.get("text", "").strip() for record in records)
    elif suffix in {".png", ".jpg", ".jpeg", ".heic", ".webp", ".gif"}:
        records, format_name, requires_model = [{"file": str(path), "mimeType": mimetypes.guess_type(path.name)[0], "_sourceRef": path.name}], "image", True
    else:
        records, format_name = [{"text": path.read_text(encoding="utf-8", errors="replace"), "_sourceRef": path.name}], "text"
    output = {
        "source": str(path),
        "format": format_name,
        "records": records,
        "warnings": warnings,
        "requiresModel": requires_model,
        "requiresBrowser": False,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
