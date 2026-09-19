"""Run with python3; exercises capture validation and resource-clock semantics."""

from pathlib import Path
import runpy
import tempfile
import unittest

summarize = runpy.run_path(
    str(Path(__file__).with_name("analyze-pipeline-samples.py"))
)["summarize"]


class CaptureTests(unittest.TestCase):
    def capture(self, rows, resources=False, units=1000, extra=""):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "capture.csv"
        metadata = (f"# capacity,{len(rows)}\n# recorded,{len(rows)}\n"
                    "# dropped,0\n# recorder-replaced,nil\n")
        if resources:
            metadata += f"# cpu-units-per-second,{units}\n"
        header = "stage,us,cpu,gc_cpu,consed" if resources else "stage,us"
        path.write_text(metadata + extra + header + "\n" + "\n".join(rows) + "\n")
        return path

    def test_plain_capture_keeps_existing_summary(self):
        result = summarize(self.capture(["keystroke,17001", "keystroke,20000"]))
        self.assertNotIn("redisplay_resources", result)
        self.assertEqual(result["stages"]["keystroke"], {
            "count": 2, "min_us": 17001, "p50_us": 17001,
            "p95_us": 20000, "max_us": 20000,
        })

    def test_gc_cpu_is_not_treated_as_elapsed_pause(self):
        result = summarize(self.capture([
            "queue-wait,0,100,10,1000",
            "command,400,105,10,1100",
            "redisplay,2000,125,25,1300",
            "keystroke,2400,125,25,1300",
            "queue-wait,0,130,25,1300",
            "command,10,135,25,1400",
            "redisplay,1000,145,25,1500",
        ], resources=True))["redisplay_resources"]
        self.assertEqual((result["paired"], result["unpaired"]), (2, 0))
        self.assertEqual(result["slowest"][0], {
            "paint": 1, "wall_us": 2000, "cpu_us": 20000,
            "gc_cpu_us": 15000, "allocated_bytes": 200,
        })
        self.assertEqual(result["groups"]["with_gc"]["wall_us"]["p50_us"], 2000)
        self.assertEqual(result["groups"]["without_gc"]["wall_us"]["p50_us"], 1000)

    def test_unpaired_redraw_does_not_invent_a_resource_delta(self):
        result = summarize(self.capture([
            "redisplay,1000,100,0,1000",
            "command,10,110,0,1100",
            "queue-wait,0,120,0,1200",
            "redisplay,1000,130,0,1300",
        ], resources=True))["redisplay_resources"]
        self.assertEqual((result["paired"], result["unpaired"]), (0, 2))
        self.assertEqual(result["slowest"], [])

    def test_invalid_resources_are_rejected(self):
        for counters in ("9,5,100", "10,4,100", "10,5,99", "-1,5,100"):
            with self.subTest(counters=counters):
                with self.assertRaises(ValueError):
                    summarize(self.capture([
                        "command,0,10,5,100", "redisplay,10," + counters,
                    ], resources=True))
        for units in (0, -1):
            with self.assertRaises(ValueError):
                summarize(self.capture(["command,0,10,5,100"], resources=True, units=units))
        with self.assertRaises(ValueError):
            summarize(self.capture(["command,0,10,5"], resources=True))

    def test_resource_capture_still_rejects_loss_and_replacement(self):
        for extra in ("# dropped,1\n", "# recorder-replaced,t\n"):
            with self.assertRaises(ValueError):
                summarize(self.capture(["command,0,10,5,100"], resources=True, extra=extra))


if __name__ == "__main__":
    unittest.main()
