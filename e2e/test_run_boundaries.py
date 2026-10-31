"""What a run may do through the tools the model calls, with no model in the loop: a run is held
before its first model call and `test.runTool` runs a tool call through the same entry the agent
loop uses. Model behaviour is tested only against the real provider (test_run.py)."""
import json
import os
import unittest

import bs
from appcase import AppCase, LOG_DIR, url

NOT_WEB = ["file:///etc/hosts", "FILE:///etc/hosts", "data:text/html,<p>local secret</p>",
           "javascript:alert(1)", "about:blank", "chrome://version/", "http:///no-host", ""]


class RunAddressTests(AppCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = bs.Fixtures(LOG_DIR).start()
        cls.data_dir = f"/tmp/bs-rb-{os.getpid()}"
        cls.host = bs.DeadHost().start()
        cls.app = bs.App(cls.data_dir, LOG_DIR, label=cls.__name__,
                         env=bs.provider_env(cls.host.url)).start()

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        cls.host.stop()

    def test_a_run_opens_only_web_pages_and_nothing_else_reaches_the_provider(self):
        self.call("test.holdModel", {"on": True})
        self.addCleanup(self.call, "test.holdModel", {"on": False})
        run = self.call("run.start", {"prompt": "open pages", "origin": "mac"})
        self.addCleanup(self.call, "run.stop", {"runId": run["runId"]})
        before = self.tab_ids()
        outputs = []
        for address in NOT_WEB:
            output = self.open_tab(run, address)
            outputs.append(output)
            self.assertIn("only http and https", json.loads(output)["error"], address)
        self.assertEqual(self.tab_ids(), before)

        page = url("act.html")
        opened = self.open_tab(run, page)
        outputs.append(opened)
        self.assertEqual(json.loads(opened)["url"], page)
        new = [t for t in self.tabs() if t["id"] not in before]
        self.assertEqual([t["url"] for t in new], [page])
        listed = next(r for r in self.call("run.list")["runs"] if r["runId"] == run["runId"])
        self.assertEqual(listed["tabId"], new[0]["id"])

        for local in ("broadcasthost", "local secret"):
            self.assertNotIn(local, "".join(outputs))
        self.assertEqual([m for m, _ in self.host.requests if m == "POST"], [])
        stopped = self.call("run.stop", {"runId": run["runId"]})
        self.assertEqual(stopped["state"], "stopped")

    def open_tab(self, run, address):
        return self.call("test.runTool", {
            "runId": run["runId"], "name": "open_tab", "arguments": {"url": address}})["output"]


if __name__ == "__main__":
    unittest.main()
