"""Sync report (issue #27 part 3, ADR 0020): the drift report can compare desired/ of the configuration repository
with Dev. The start form offers the source (Live stays the default), the report page and the list name it."""

import re
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from m365ui.api_client import MockClient
from m365ui.main import create_app

from test_pages import MOCK_FILE, RecordingClient

NOW = datetime(2026, 11, 7, 12, 40, tzinfo=timezone.utc)
REPO_REPORT = "drift-20261107-113000"
LIVE_REPORT = "drift-20261107-120000"


@pytest.fixture()
def client():
    return RecordingClient(MockClient(MOCK_FILE))


@pytest.fixture()
def web(client):
    return TestClient(create_app(client, clock=lambda: NOW))


def test_drift_form_offers_the_source_with_live_as_default(web):
    html = web.get("/goals/align").text
    form = re.search(r'<form[^>]*>(?:(?!</form>).)*name="action" value="drift".*?</form>', html, re.S)
    assert form, "the drift form is missing"
    assert 'name="source" value="Live" checked' in form.group(0)
    assert 'name="source" value="Repository"' in form.group(0)


def test_repository_report_names_the_source_and_the_commit(web):
    html = web.get(f"/reports/{REPO_REPORT}").text
    assert "Configuration repository" in html
    assert ">3f9c2a7b1d4e<" in html
    assert 'title="3f9c2a7b1d4e5f60718293a4b5c6d7e8f9012345"' in html
    assert "only in the desired state" in html and "only in Prod" not in html
    assert '<th scope="col">Desired state</th>' in html


def test_live_report_still_says_prod(web):
    html = web.get(f"/reports/{LIVE_REPORT}").text
    assert "Prod (live)" in html
    assert "Configuration repository" not in html
    assert "only in Prod" in html


def test_report_list_tags_the_source_of_each_drift_report(web):
    html = web.get("/reports").text
    row = re.search(rf'<tr>(?:(?!</tr>).)*{REPO_REPORT}.*?</tr>', html, re.S)
    assert row and "Configuration repository" in row.group(0)
    row = re.search(rf'<tr>(?:(?!</tr>).)*{LIVE_REPORT}.*?</tr>', html, re.S)
    assert row and "Prod (live)" in row.group(0)
