"""deploy_orchestrator 参数解析与默认值（不连 AWS、不跑 flutter）。"""
import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _load_orchestrator():
    path = ROOT / "ops" / "code" / "deploy_orchestrator.py"
    spec = importlib.util.spec_from_file_location("deploy_orchestrator", path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class TestDeployOrchestratorParser(unittest.TestCase):
    def test_aws_defaults(self):
        m = _load_orchestrator()
        p = m._build_parser()
        ns = p.parse_args(["aws"])
        self.assertEqual(ns.cmd, "aws")
        self.assertEqual(ns.flutter_mode, "release")
        self.assertFalse(ns.db)
        self.assertFalse(ns.rsync_no_delete)
        self.assertFalse(ns.no_start)

    def test_local_defaults(self):
        m = _load_orchestrator()
        p = m._build_parser()
        ns = p.parse_args(["local"])
        self.assertEqual(ns.flutter_mode, "release")
        self.assertFalse(ns.no_start)

    def test_db_aliases(self):
        m = _load_orchestrator()
        p = m._build_parser()
        ns = p.parse_args(["aws", "-db"])
        self.assertTrue(ns.db)


if __name__ == "__main__":
    unittest.main()
