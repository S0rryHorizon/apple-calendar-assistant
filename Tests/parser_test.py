import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PARSER = ROOT / "skill/apple-calendar-assistant/scripts/parse_schedule.py"


class ParserTests(unittest.TestCase):
    def run_parser(self, path):
        output = subprocess.check_output([sys.executable, str(PARSER), str(path)], text=True)
        return json.loads(output)

    def test_csv(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "schedule.csv"
            path.write_text("日期,课程,开始\n2026-09-01,数据库,09:00\n", encoding="utf-8")
            result = self.run_parser(path)
            self.assertEqual(result["records"][0]["课程"], "数据库")
            self.assertEqual(result["format"], "csv")

    def test_ics(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "schedule.ics"
            path.write_text(
                "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:course-1\nSUMMARY:Math\n"
                "DTSTART;TZID=Asia/Singapore:20260901T090000\n"
                "DTEND;TZID=Asia/Singapore:20260901T100000\n"
                "BEGIN:VALARM\nTRIGGER:-PT60M\nEND:VALARM\n"
                "END:VEVENT\nEND:VCALENDAR\n",
                encoding="utf-8",
            )
            result = self.run_parser(path)
            self.assertEqual(result["records"][0]["summary"], "Math")
            self.assertEqual(result["records"][0]["alerts"][0]["trigger"], "-PT60M")

    def test_xlsx(self):
        try:
            import openpyxl
        except ImportError:
            self.skipTest("openpyxl is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "schedule.xlsx"
            workbook = openpyxl.Workbook()
            sheet = workbook.active
            sheet.title = "课程"
            sheet.append(["日期", "课程", "开始"])
            sheet.append(["2026-09-01", "数据库", "09:00"])
            workbook.save(path)
            result = self.run_parser(path)
            self.assertEqual(result["records"][0]["课程"], "数据库")
            self.assertIn("课程:row-2", result["records"][0]["_sourceRef"])

    def test_url_requires_browser(self):
        result = self.run_parser("https://example.com/schedule")
        self.assertTrue(result["requiresBrowser"])


if __name__ == "__main__":
    unittest.main()
