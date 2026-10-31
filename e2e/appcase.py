"""Neutral base for e2e tests that drive one real app: launch, fresh state and page helpers."""
import json
import os
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

import bs

LOG_DIR = os.environ.get("BS_E2E_LOGDIR") or tempfile.mkdtemp(prefix="bs-e2e-logs-")


def url(page):
    return f"{bs.FIXTURE_URL}/{page}"


def save(name, value):
    with open(os.path.join(LOG_DIR, name), "w") as out:
        json.dump(value, out, indent=2, sort_keys=True)


class AppCase(unittest.TestCase):
    """One app per class, started on a blank tab."""

    start_url = None

    @classmethod
    def setUpClass(cls):
        cls.fixtures = bs.Fixtures(LOG_DIR).start()
        cls.data_dir = f"/tmp/bs-win-{os.getpid()}-{cls.__name__[:8]}"
        cls.app = bs.App(cls.data_dir, LOG_DIR, label=cls.__name__, url=cls.start_url).start()

    @classmethod
    def tearDownClass(cls):
        cls.app.stop()

    def call(self, method, params=None):
        return self.app.call(method, params)

    def ui(self):
        return self.call("test.ui")

    def chrome(self):
        return self.ui()["chrome"]

    def key(self, key, *modifiers):
        self.call("test.key", {"key": key, "modifiers": list(modifiers)})

    def tabs(self):
        return self.call("tabs")["tabs"]

    def tab_ids(self):
        return [tab["id"] for tab in self.tabs()]

    def active_id(self):
        return self.ui()["activeTabId"]

    def wait_loaded(self, page_url, tab_id=None):
        def ready():
            for tab in self.tabs():
                if (tab_id is None or tab["id"] == tab_id) and tab["url"] == page_url \
                        and not tab["loading"]:
                    return tab
        return bs.wait_until(ready, what=f"{page_url} loaded")

    def open_page(self, page, activate=True):
        tab = self.call("open_tab", {"url": url(page), "activate": activate})
        return self.wait_loaded(url(page), tab["id"])

    def navigate(self, tab_id, page_url):
        """Loads a URL in an existing tab, so it gains a history entry."""
        self.call("test.devtools", {"tabId": tab_id, "method": "Page.navigate",
                                    "params": {"url": page_url}})
        return self.wait_loaded(page_url, tab_id)

    def evaluate(self, expression, tab_id=None):
        params = {"method": "Runtime.evaluate",
                  "params": {"expression": expression, "returnByValue": True}}
        if tab_id:
            params["tabId"] = tab_id
        return self.call("test.devtools", params)["result"].get("value")

    def beacons(self, since):
        return [parse_qs(urlsplit(line.split()[1]).query)
                for line in self.fixtures.log(since) if "/__beacon?" in line]

    def launcher_open(self):
        return self.ui()["launcher"]["open"]

    def wait_launcher(self, open_, what=None):
        bs.wait_until(lambda: self.launcher_open() == open_,
                      what=what or ("the launcher to open" if open_ else "the launcher to close"))

    def reset_to_one_blank_tab(self):
        first, *rest = self.tab_ids()
        for tab_id in rest:
            self.call("test.closeTab", {"tabId": tab_id})
        self.call("test.activateTab", {"tabId": first})
        return first
