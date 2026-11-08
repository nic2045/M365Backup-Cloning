"""Wrapper of the IntuneCD backup (issue #68, ADR 0014). IntuneCD's own parser is used; its start() is replaced, so
nothing signs in and nothing is read from a tenant."""

from __future__ import annotations

import io
import subprocess
import sys
from pathlib import Path

import pytest

import intunecd_backup as wrapper

TOKEN = "fake.token.for.tests"
WRAPPER = Path(wrapper.__file__)


class FakeStart:
    def __init__(self, fail: BaseException | None = None):
        self.args = None
        self.token_seen = None
        self.fail = fail

    def __call__(self, args):
        self.args = args
        self.token_seen = args.token
        if self.fail:
            raise self.fail


def run(tmp_path: Path, start: FakeStart, *extra: str, token: str = TOKEN) -> int:
    from IntuneCD.run_backup import get_parser

    return wrapper.run(["--path", str(tmp_path), *extra], io.StringIO(token + "\n"), start=start, get_parser=get_parser)


def test_backup_only_read_only_options_and_token_in_memory(tmp_path):
    start = FakeStart()
    assert run(tmp_path, start) == 0
    a = start.args
    assert start.token_seen == TOKEN and a.token is None  # handed over, then dropped
    assert a.output == "json" and a.path == str(tmp_path) + "/"
    assert a.ignore_omasettings and a.skip_archive
    assert not a.entrabackup and not a.autopilot and not a.activationlock and not a.audit and not a.append_id
    assert not a.certauth and not a.interactiveauth and a.localauth is None
    assert set(wrapper.DEFAULT_EXCLUDE) <= set(a.exclude)


def test_more_types_can_be_left_out(tmp_path):
    start = FakeStart()
    assert run(tmp_path, start, "--exclude", "PowershellScripts", "ShellScripts") == 0
    assert {"PowershellScripts", "ShellScripts", "ConditionalAccess"} <= set(start.args.exclude)


def test_scripts_are_left_out_by_default(tmp_path):
    start = FakeStart()
    assert run(tmp_path, start) == 0
    assert set(wrapper.SCRIPT_TYPES) <= set(start.args.exclude)


def test_scripts_can_be_included_on_purpose(tmp_path):
    start = FakeStart()
    assert run(tmp_path, start, "--include-scripts") == 0
    assert not set(wrapper.SCRIPT_TYPES) & set(start.args.exclude)
    assert set(wrapper.DEFAULT_EXCLUDE) <= set(start.args.exclude)  # Conditional Access stays out


def test_script_types_are_known_to_intunecd(tmp_path):
    # an unknown name would make IntuneCD's parser refuse every run
    start = FakeStart()
    assert run(tmp_path, start, "--exclude", *wrapper.SCRIPT_TYPES) == 0


def test_an_unknown_type_is_refused_by_intunecd(tmp_path, capsys):
    assert run(tmp_path, FakeStart(), "--exclude", "NoSuchType") == 2
    assert "does not know" in capsys.readouterr().err


@pytest.mark.parametrize("token", ["", "two words", "x" * (wrapper.MAX_TOKEN_CHARS + 1)])
def test_a_missing_or_bad_token_is_refused(tmp_path, token):
    start = FakeStart()
    assert run(tmp_path, start, token=token) == 2
    assert start.args is None


def test_the_folder_must_exist_and_be_empty(tmp_path):
    (tmp_path / "old.json").write_text("{}", encoding="utf-8")
    assert run(tmp_path, FakeStart()) == 2
    assert run(tmp_path / "missing", FakeStart()) == 2


def test_a_failure_of_intunecd_never_shows_the_token(tmp_path, capsys):
    start = FakeStart(fail=RuntimeError(f"401 for token {TOKEN}"))
    assert run(tmp_path, start) == 4
    err = capsys.readouterr().err
    assert TOKEN not in err and "***" in err


def test_system_exit_of_intunecd_is_a_failure(tmp_path):
    assert run(tmp_path, FakeStart(fail=SystemExit(1))) == 4


def test_the_update_of_intunecd_is_never_imported():
    text = WRAPPER.read_text(encoding="utf-8")
    assert "run_update" not in text and "startupdate" not in text.lower()


def test_the_token_is_not_on_the_command_line(tmp_path):
    """Started as a process (as the PowerShell core does): no token on stdin gives exit code 2, and the help names
    no token argument."""
    done = subprocess.run([sys.executable, str(WRAPPER), "--path", str(tmp_path)], input="", capture_output=True, text=True, timeout=60)
    assert done.returncode == 2
    help_text = subprocess.run([sys.executable, str(WRAPPER), "--help"], capture_output=True, text=True, timeout=60).stdout
    assert "--token" not in help_text
