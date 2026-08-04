"""Real cmd.exe hook invocation tests -- used by test-codex-contract.sh Group 2.x.

Usage: python3 _cmd_test.py <hook_name> <cwd> [--no-python3 | --fake-python3]

Modes:
  (default)         Run hook with current PATH (real Python likely present).
  --no-python3      Strip python/python3/WindowsApps from PATH (no Python).
  --fake-python3    Simulate "py.exe exists but no Python installed": strip
                    real Python from PATH and prepend a temp dir containing
                    stub python3/python/py that print
                    "No installed Python found!" and exit 9009. Hook must
                    still produce valid JSON via the runtime probe falling
                    through to jq or powershell.

Prints one line per check:
  PASS|G5.XX test description|detail
  FAIL|G5.XX test description|detail
"""
import subprocess, json, sys, os, tempfile


def main():
    hook_name = sys.argv[1]
    cwd = sys.argv[2]
    mode_default = "--no-python3" not in sys.argv and "--fake-python3" not in sys.argv
    strip_python = "--no-python3" in sys.argv
    fake_python = "--fake-python3" in sys.argv
    root_dir = os.path.dirname(os.path.abspath(__file__))

    cmd_path = os.path.join(
        root_dir, "..", "..", "adapters", "codex", "hooks", f"{hook_name}.cmd"
    )
    stdin_data = (json.dumps({"cwd": cwd}) + "\n").encode("utf-8")

    env = None
    if strip_python or fake_python:
        env = os.environ.copy()
        path_sep = ";" if os.name == "nt" else ":"
        new_path_parts = []
        for part in env.get("PATH", "").split(path_sep):
            lower = part.lower()
            if (
                "python" in lower
                or "python3" in lower
                or "windowsapps" in lower
            ):
                continue
            new_path_parts.append(part)

        if fake_python:
            # Create a temp dir with stub python3/python/py that fail with
            # the exact "No installed Python found!" message that the real
            # WindowsApps py.exe shim produces. Prepend to PATH so they
            # are the FIRST match for `python3`/`python`/`py`.
            fake_dir = tempfile.mkdtemp(prefix="hc_fake_py_")
            ext = ".cmd" if os.name == "nt" else ""
            if os.name == "nt":
                stub = "@echo off\r\necho No installed Python found! 1>&2\r\nexit /b 9009\r\n"
            else:
                stub = "#!/bin/sh\necho 'No installed Python found!' >&2\nexit 127\n"
            for name in ("python3", "python", "py"):
                p = os.path.join(fake_dir, name + ext)
                with open(p, "w", encoding="utf-8", newline="") as f:
                    f.write(stub)
                if os.name != "nt":
                    os.chmod(p, 0o755)
            new_path_parts.insert(0, fake_dir)
        env["PATH"] = path_sep.join(new_path_parts)

    p = subprocess.run(
        ["cmd.exe", "/c", cmd_path],
        input=stdin_data,
        capture_output=True,
        timeout=15,
        env=env,
    )
    rc = p.returncode
    stdout = p.stdout.decode("utf-8", errors="replace").strip()
    stderr = p.stderr.decode("utf-8", errors="replace").strip()

    stderr_bytes = p.stderr
    has_cnf = (
        b"command not found" in stderr_bytes
        or b"not recognized" in stderr_bytes
        or b"No such file" in stderr_bytes
        or b"cannot find" in stderr_bytes.lower()
        or b"\xb2\xbb\xca\xc7\xc4\xda\xb2\xbf\xbb\xf2\xcd\xe2\xb2\xbf" in stderr_bytes
    )

    valid = False
    out = {}
    try:
        out = json.loads(stdout)
        valid = True
    except Exception:
        pass

    # -- G5.24: exit code 0 --
    yield (
        ("PASS" if rc == 0 else "FAIL"),
        f"G5.24 {hook_name}.cmd exit 0",
        f"rc={rc}" if rc != 0 else "",
    )

    # -- G5.25: no command-not-found on stderr --
    yield (
        ("PASS" if not has_cnf else "FAIL"),
        f"G5.25 {hook_name}.cmd stderr: no command-not-found",
        f"stderr={stderr[:120]}" if has_cnf else "",
    )

    # -- G5.26: stdout is valid JSON --
    yield (
        ("PASS" if valid else "FAIL"),
        f"G5.26 {hook_name}.cmd stdout is valid JSON",
        f"stdout={stdout[:100]}" if not valid else "",
    )

    # -- Hook-specific envelope checks --
    if hook_name == "session-start":
        hso = out.get("hookSpecificOutput", {}) if isinstance(out, dict) else {}
        has_ac = "additionalContext" in hso
        yield (
            ("PASS" if has_ac else "FAIL"),
            f"G5.27 {hook_name}.cmd hookSpecificOutput.additionalContext",
            "" if has_ac else f"keys={list(out.keys()) if isinstance(out, dict) else 'N/A'}",
        )

    elif hook_name == "stop-handoff":
        has_sm = "systemMessage" in out if isinstance(out, dict) else False
        has_cont = out.get("continue") == True if isinstance(out, dict) else False
        # If the cwd is the wip-violation fixture, we MUST have systemMessage;
        # otherwise continue-only is acceptable (no warnings to surface).
        is_wip_fixture = cwd.endswith("wip-violation")
        if is_wip_fixture:
            ok = has_sm
            label = f"G5.28 {hook_name}.cmd Stop envelope (systemMessage REQUIRED for WIP fixture)"
        else:
            ok = has_sm or has_cont
            label = f"G5.28 {hook_name}.cmd Stop envelope (systemMessage or continue)"
        yield (
            ("PASS" if ok else "FAIL"),
            label,
            "" if ok else f"keys={list(out.keys()) if isinstance(out, dict) else 'N/A'}",
        )

    elif hook_name == "pre-tool-use":
        is_cont = out.get("continue") == True if isinstance(out, dict) else False
        yield (
            ("PASS" if is_cont else "FAIL"),
            f"G5.29 {hook_name}.cmd continue=true",
            "" if is_cont else f"got={json.dumps(out)[:100]}",
        )


if __name__ == "__main__":
    for status, label, detail in main():
        print(f"{status}|{label}|{detail}")