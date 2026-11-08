"""Plan from the configuration repository (issue #27 part 2, ADR 0019): the plan forms offer the source of the
desired state, the plan page names it and the commit; the interface only passes the choice to the API."""

from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from m365ui import view
from m365ui.api_client import MockClient
from m365ui.main import create_app

from test_pages import MOCK_FILE, RecordingClient

NOW = datetime(2026, 11, 7, 12, 40, tzinfo=timezone.utc)
REPO_PLAN = "apply-plan-20261107-121000"
LIVE_PLAN = "apply-plan-20261107-120000"


@pytest.fixture()
def web():
    return TestClient(create_app(RecordingClient(MockClient(MOCK_FILE)), clock=lambda: NOW))


@pytest.mark.parametrize("page", ["/goals/align", "/areas/intune"])
def test_plan_forms_offer_the_source_with_live_as_default(web, page):
    html = web.get(page).text
    assert 'name="source" value="Live" checked' in html
    assert 'name="source" value="Repository"' in html
    assert "Configuration repository" in html


def test_plan_page_names_the_repository_and_the_commit(web):
    html = web.get(f"/plans/{REPO_PLAN}").text
    assert "Desired state" in html and "Configuration repository" in html
    assert ">a1b2c3d4e5f6<" in html
    assert 'title="a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"' in html
    assert "reads the configuration repository and Dev again" in html


def test_plan_page_of_a_live_plan_says_prod(web):
    html = web.get(f"/plans/{LIVE_PLAN}").text
    assert "Prod (live)" in html
    assert "Configuration repository" not in html


def test_job_request_passes_the_source_of_plan_apply_only():
    assert view.job_request({"action": "plan-apply", "area": "All", "source": "Repository"}) == {
        "action": "plan-apply", "area": "All", "source": "Repository"}
    assert view.job_request({"action": "drift", "source": "Repository"}) == {"action": "drift"}
    with pytest.raises(view.FormError):
        view.job_request({"action": "plan-apply", "source": "Prod"})
