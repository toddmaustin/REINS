"""Check release evidence fails closed and minimization preserves the actual target failure."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tools.campaign_report import ROOT, generate, coverage_report
from tools.minimize_replay import minimize
from tools.run_tests import source_digest


class CampaignChecks(unittest.TestCase):
    """Use isolated inputs with all outputs retained beneath the active test run."""

    def setUp(self):
        """Allocate retained case outputs and disposable input scratch; no parameters."""
        parent = Path(os.environ.get("REINS_TEST_OUTPUT_DIR", ROOT / "test-results")) / "campaign-regressions"
        parent.mkdir(parents=True,exist_ok=True)
        self.output = Path(tempfile.mkdtemp(prefix=self._testMethodName+"-",dir=parent))
        self.scratch = tempfile.TemporaryDirectory(prefix="reins-campaign-input-")
        self.addCleanup(self.scratch.cleanup)

    def test_minimizer_establishes_one_minimal_target_without_reordering(self):
        """Require both ordered target actions; unrelated actions must disappear; no parameters."""
        actions = ["noise", "first", "noise2", "second", "noise3"]
        result = minimize(actions,lambda candidate: "first" in candidate and "second" in candidate and candidate.index("first")<candidate.index("second"))
        self.assertEqual(result,["first","second"])

    def test_release_rejects_missing_tests_and_stale_source(self):
        """A green-looking empty or stale summary cannot establish current digital closure; no parameters."""
        directory = Path(self.scratch.name)
        (directory / "summary.json").write_text(json.dumps(dict(steps=[],source_digest="stale",suite="r11-release")))
        errors = generate(directory,self.output,"release",2,128)
        self.assertTrue(any("Source digest" in error for error in errors))
        self.assertTrue(any("Required release groups" in error for error in errors))
        self.assertTrue(any("fuzz" in error.lower() for error in errors))
        self.assertEqual(json.loads((self.output / "campaign.json").read_text())["status"],"failed")

    def test_source_coverage_unions_instances_but_retains_unexecuted_points(self):
        """Union actual coverage records, preserving a zero-count point instead of crediting a whole line; no parameters."""
        directory = Path(self.scratch.name) / "group/coverage"
        directory.mkdir(parents=True)
        prefix = "C '\x01f\x02rtl/reins_controller.sv\x01l\x02118\x01n\x021\x01o\x02block"
        (directory / "a.dat").write_text(prefix+"\x01h\x02instance-a' 0\n"+prefix.replace("n\x021","n\x022")+"' 0\n")
        (directory / "b.dat").write_text(prefix+"\x01h\x02instance-b' 7\n")
        report = coverage_report(Path(self.scratch.name))
        self.assertEqual((report["source_points"],report["hit_points"]),(2,1))
        self.assertEqual(len(report["uncovered"]),1)

    def test_executed_case_names_accept_success_and_duration_reporters(self):
        """Read the two actual doctest reporter formats used by software and RTL groups; no parameters."""
        for index,text in enumerate(["TEST CASE:  actual executed case\n", "0.000123 s: actual executed case\n"]):
            directory = Path(self.scratch.name) / str(index)
            directory.mkdir()
            log = directory / "output.log"
            log.write_text(text)
            summary = dict(suite="r11-directed",source_digest=source_digest(),steps=[dict(name="r11-directed",status="passed",log=str(log),executed_tests=1)])
            (directory / "summary.json").write_text(json.dumps(summary))
            output = self.output / str(index)
            self.assertEqual(generate(directory,output,"directed",2,128),[])
            self.assertEqual(json.loads((output / "campaign.json").read_text())["executed_tests"]["r11-directed"],["actual executed case"])

    def test_zero_budget_is_rejected_before_build(self):
        """Reject a zero-work campaign at its CLI boundary; no parameters."""
        result = subprocess.run([sys.executable,"-E","-s","-B",str(ROOT/"tools/run_campaigns.py"),"--profile","fuzz","--seeds","0"],capture_output=True,text=True)
        (self.output / "invalid-budget.log").write_text(result.stdout+result.stderr)
        self.assertEqual(result.returncode,2)
        self.assertIn("zero work is invalid",result.stderr)

    def test_attempt_rows_without_applied_readback_get_no_fault_credit(self):
        """Reject a claimed safe attempt when no actual target application/effect was observed."""
        directory=Path(self.scratch.name)
        group=directory / "r11-repeated-fault"
        group.mkdir()
        event=dict(event="campaign_fault",campaign="persistent_shared_read",site=22,attempt=0,
            duration_clocks=10,outcome="safely_tolerated",dangerous=False,bench=1,activation_clock=3)
        (group / "events.jsonl").write_text(json.dumps(event)+"\n")
        (directory / "summary.json").write_text(json.dumps(dict(suite="r11-fault",source_digest=source_digest(),
            steps=[dict(name="r11-repeated-fault",status="passed")])))
        errors=generate(directory,self.output,"fault",2,128)
        self.assertTrue(any("application/effect evidence" in error for error in errors))
        self.assertEqual(json.loads((self.output / "campaign.json").read_text())["faults"]["applied"],0)

    def test_requested_fuzz_budget_is_separate_from_default_suite_smoke(self):
        """Retain default smoke work without letting it replace or inflate separately requested seed runs; no parameters."""
        directory = Path(self.scratch.name)
        steps = []
        for group,seed in [("r11-spi",100),("r11-fuzz-0",100),("r11-fuzz-1",101)]:
            destination = directory / group
            destination.mkdir()
            (destination / "fuzz.trace").write_text("frame 0 ff\n")
            event = dict(event="campaign_fuzz",seed=seed,budget=4,executed=4,reproducer="fuzz.trace")
            (destination / "events.jsonl").write_text(json.dumps(event)+"\n")
            steps.append(dict(name=group,status="passed"))
        summary = dict(suite="r11-fuzz",source_digest=source_digest(),steps=steps)
        (directory / "summary.json").write_text(json.dumps(summary))
        self.assertEqual(generate(directory,self.output,"fuzz",2,4),[])
        data = json.loads((self.output / "campaign.json").read_text())["fuzz"]
        self.assertEqual(len(data["executions"]),3)
        self.assertEqual(data["requested_executed_iterations"],8)
        self.assertEqual(len(data["suite_smoke_executions"]),1)
        summary["steps"] = steps[:-1]
        (directory / "summary.json").write_text(json.dumps(summary))
        self.assertTrue(any("budget" in error for error in generate(directory,self.output / "missing","fuzz",2,4)))

    def test_unavailable_formal_tool_is_not_a_skip_pass(self):
        """A missing tool must record unavailable and return failure; no parameters."""
        environment = dict(os.environ,REINS_TEST_OUTPUT_DIR=str(self.output),YOSYS="/nonexistent/reins-yosys")
        result = subprocess.run([sys.executable,"-E","-s","-B",str(ROOT/"tools/qualification_checks.py"),"--check","formal"],env=environment,capture_output=True,text=True)
        (self.output / "unavailable.log").write_text(result.stdout+result.stderr)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(json.loads((self.output / "qualification.json").read_text())["status"],"unavailable")

    def test_minimization_runs_real_child_probes_and_reports_exhaustion(self):
        """Exercise a synthetic failing child to test tool mechanics, never label it a DUT defect; no parameters."""
        scratch = Path(self.scratch.name)
        binary = scratch / "synthetic-oracle"
        binary.write_text("#!/usr/bin/env python3\nimport os\nfrom pathlib import Path\ntext=Path(os.environ['REINS_R11_REPLAY']).read_text()\nif 'trigger' in text:\n print('ERROR: CHECK( synthetic_target ) is NOT correct!')\n raise SystemExit(1)\n")
        binary.chmod(0o700)
        trace = scratch / "input.trace"
        trace.write_text("noise\ntrigger\nnoise2\n")
        for budget,expected in [(30,"minimized"),(1,"failed")]:
            output = self.output / str(budget)
            environment = dict(os.environ,REINS_TEST_OUTPUT_DIR=str(output))
            result = subprocess.run([sys.executable,"-E","-s","-B",str(ROOT/"tools/minimize_replay.py"),"--input",str(trace),"--binary",str(binary),"--fingerprint","CHECK( synthetic_target )","--budget",str(budget)],env=environment,capture_output=True,text=True)
            (output / "tool.log").write_text(result.stdout+result.stderr)
            report = json.loads((output / "minimization.json").read_text())
            self.assertEqual(report["status"],expected)
            self.assertEqual(result.returncode,0 if expected=="minimized" else 1)
            self.assertLessEqual(report["executed_probes"],budget)
            if expected=="minimized":
                self.assertTrue(report["one_minimal"])
                self.assertEqual((output / "minimized.trace").read_text(),"trigger\n")


if __name__ == "__main__":
    unittest.main()
