import os
import subprocess
from pathlib import Path
import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
DEPLOY_SH = REPO_ROOT / "hub" / "deploy.sh"


def run_deploy(args, env=None, cwd=REPO_ROOT):
    full_env = os.environ.copy()
    if env:
        full_env.update(env)
    cmd = ["bash", str(DEPLOY_SH)] + args
    return subprocess.run(cmd, capture_output=True, text=True, env=full_env, cwd=cwd)


def parse_plan(stdout: str) -> dict:
    plan = {}
    for line in stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            plan[k.strip()] = v.strip()
    return plan


def test_deploy_non_demo_plan():
    res = run_deploy(["--print-plan"])
    assert res.returncode == 0
    plan = parse_plan(res.stdout)
    assert plan.get("DEMO") == "false"
    assert plan.get("DEPLOY_IMAGE") == ""
    assert plan.get("COLLECTOR_SRC") == ""


def test_deploy_case1_explicit_collector_src(tmp_path):
    mock_src = tmp_path / "custom-collector"
    mock_src.mkdir()
    res = run_deploy(
        ["--demo", "--collector-src", str(mock_src), "--print-plan"],
        env={"COLLECTOR_IMAGE": "should-be-overridden:v1"},
    )
    assert res.returncode == 0
    plan = parse_plan(res.stdout)
    assert plan.get("DEMO") == "true"
    assert plan.get("COLLECTOR_SRC") == str(mock_src)
    assert plan.get("DEPLOY_IMAGE") == "jammy-collector:local"


def test_deploy_case2_collector_image_env_skips_autodetect():
    res = run_deploy(
        ["--demo", "--print-plan"],
        env={"COLLECTOR_IMAGE": "myregistry.io/jammy-collector:v3.2.1"},
    )
    assert res.returncode == 0
    plan = parse_plan(res.stdout)
    assert plan.get("DEMO") == "true"
    assert plan.get("COLLECTOR_SRC") == ""
    assert plan.get("DEPLOY_IMAGE") == "myregistry.io/jammy-collector:v3.2.1"


def test_deploy_case3_autodetect_when_default_exists(tmp_path):
    # Simulate a workspace structure where ../jammy-collector exists
    fake_workspace = tmp_path / "workspace"
    fake_hub = fake_workspace / "hub"
    fake_hub.mkdir(parents=True)
    fake_deploy = fake_hub / "deploy.sh"
    fake_deploy.write_text(DEPLOY_SH.read_text(encoding="utf-8"), encoding="utf-8")

    mock_collector = tmp_path / "jammy-collector"
    mock_collector.mkdir()

    cmd = ["bash", str(fake_deploy), "--demo", "--print-plan"]
    # Ensure COLLECTOR_IMAGE is empty
    env = os.environ.copy()
    env.pop("COLLECTOR_IMAGE", None)
    res = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=fake_workspace)

    assert res.returncode == 0, f"STDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}"
    plan = parse_plan(res.stdout)
    assert plan.get("DEMO") == "true"
    assert Path(plan.get("COLLECTOR_SRC")).resolve() == mock_collector.resolve()
    assert plan.get("DEPLOY_IMAGE") == "jammy-collector:local"


def test_deploy_case3_fails_when_neither_provided_nor_autodetected(tmp_path):
    # In an isolated directory where ../jammy-collector does not exist
    fake_workspace = tmp_path / "isolated-repo"
    fake_hub = fake_workspace / "hub"
    fake_hub.mkdir(parents=True)
    fake_deploy = fake_hub / "deploy.sh"
    fake_deploy.write_text(DEPLOY_SH.read_text(encoding="utf-8"), encoding="utf-8")

    cmd = ["bash", str(fake_deploy), "--demo", "--print-plan"]
    env = os.environ.copy()
    env.pop("COLLECTOR_IMAGE", None)
    res = subprocess.run(cmd, capture_output=True, text=True, env=env, cwd=fake_workspace)

    assert res.returncode == 1
    assert "Error: Demo mode requires either --collector-src" in res.stderr


def test_deploy_fails_on_missing_collector_src_dir(tmp_path):
    non_existent = tmp_path / "does-not-exist"
    res = run_deploy(["--demo", "--collector-src", str(non_existent)])
    assert res.returncode == 1
    assert "Collector source directory does not exist" in res.stderr


def test_deploy_missing_option_arguments():
    for opt in ["--host", "--collector-src", "--ssh-user"]:
        res = run_deploy([opt])
        assert res.returncode == 2, f"Option {opt} without argument should exit with 2"
        assert f"Error: {opt} requires an argument" in res.stderr
        assert "Usage: deploy.sh" in res.stderr


def test_deploy_unknown_option():
    res = run_deploy(["--invalid-flag"])
    assert res.returncode == 2
    assert "Error: Unknown option '--invalid-flag'" in res.stderr
    assert "Usage: deploy.sh" in res.stderr
