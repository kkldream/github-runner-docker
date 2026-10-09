#!/usr/bin/env python3
"""Deterministic faults against the same sourceable helpers used by image smoke.

No Docker daemon, GitHub or image is contacted. All resources are JSON fixtures.
Artifacts stay in a unique run-* child of TMPDIR / FAULT_ARTIFACT_DIR.
"""
import ctypes
import json
import os
from pathlib import Path
import select
import signal
import sys
import uuid
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = Path(os.environ.get("FAULT_ARTIFACT_DIR") or os.environ["TMPDIR"])
BASE.mkdir(parents=True, exist_ok=True)
RUN = Path(tempfile.mkdtemp(prefix="run-", dir=BASE))
PREFIX = "hermes-issue2-smoke-fault-unique"
NAME = PREFIX + "-case"

# Deliberately small CLI: cleanup inventory/ownership/removal and readiness only.
# Every destructive call is recorded independently of the helper's exit status.
DOCKER = r'''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
from pathlib import Path
p = Path(os.environ['FAULT_STATE'])
s = json.loads(p.read_text())
a = sys.argv[1:]
s['calls'].append(a)
cmd = a[0]
if cmd == 'ps':
    s['queries'] += 1
    p.write_text(json.dumps(s))
    if s['fault'] in ('query1', 'query124') or (s['fault'] == 'readback' and s['queries'] > 1):
        print('injected daemon inventory failure', file=sys.stderr)
        sys.exit(124 if s['fault'] == 'query124' else 1)
    for name, owner in s['resources'].items():
        print('id-' + name + '\t' + name + '\t' + owner)  # Synthetic immutable ID.
elif cmd == 'inspect':
    p.write_text(json.dumps(s))
    if len(a) > 1 and a[1] == '--format':
        if '.Config.Labels' in a[2]:
            if s['fault'] in ('query1', 'query124'):
                sys.exit(124 if s['fault'] == 'query124' else 1)
            if a[-1] not in s['resources']: sys.exit(1)
            print(s['resources'][a[-1]])
        else:
            print('true')
    else:
        print('{}')
elif cmd == 'rm':
    if s['fault'] != 'rm-noop': s['resources'].pop(a[-1].removeprefix('id-'), None)
    p.write_text(json.dumps(s))
    if s['fault'] == 'rm-error': sys.exit(1)
elif cmd == 'logs':
    p.write_text(json.dumps(s))
    if s['fault'] == 'log-failure':
        print('injected logs failure', file=sys.stderr)
        sys.exit(1)
    first_log = sum(c[0] == 'logs' for c in s['calls']) == 1
    if s['fault'] == 'late-ready' and first_log: time.sleep(16)
    if s['fault'] == 'ignore-term' and first_log:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        # Child in the same controlled group also ignores TERM.
        child = subprocess.Popen([sys.executable, '-c',
            'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
            'print("READY",flush=True); time.sleep(300)'], stdout=subprocess.PIPE)
        assert child.stdout.readline() == b'READY\n'
        child.stdout.close()
        def identity(pid):
            # /proc field 22, parsing after ')' because comm can contain spaces.
            ticks = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
            return dict(pid=pid, start_ticks=ticks)
        record = dict(nonce=os.environ['FAULT_NONCE'],
                      processes=[identity(os.getpid()), identity(child.pid)])
        destination = Path(os.environ['FAULT_PIDS'])
        temporary = destination.with_suffix('.tmp')
        temporary.write_text(json.dumps(record))
        temporary.replace(destination)  # Ready only after both handlers exist.
        while True: time.sleep(1)
    print('FAKE_LISTENER_READY')
    print('FAKE_STDERR_EVIDENCE', file=sys.stderr)
elif cmd == 'top':
    p.write_text(json.dumps(s))
    print('/usr/bin/tini run.sh /actions-runner/run-helper.sh /actions-runner/bin/Runner.Listener')
elif cmd == 'exec':
    p.write_text(json.dumps(s))
else:
    raise SystemExit('unsupported fake Docker command: ' + repr(a))
'''

DRIVER = r'''set -euo pipefail
ROOT=$1
ARTIFACTS=$2
PREFIX=$3
NAME=$4
CONTAINERS=("${NAME}")
source "${FAULT_HELPER_PATH:-${ROOT}/tests/container_smoke_helpers.sh}"
case "$5" in
  cleanup) trap cleanup EXIT; exit "${6:-0}" ;;
  ready) trap cleanup EXIT; wait_ready ;;
  cli) dkr logs "${NAME}" ;;
  suite)
    # Shortened supervisor budget, otherwise the real CLI and cleanup helper.
    bounded_command 1 30 bash "$0" "$ROOT" "$ARTIFACTS" "$PREFIX" "$NAME" interrupt ;;
  interrupt) trap cleanup EXIT; trap 'exit 143' TERM; dkr logs "${NAME}" ;;
  term) trap cleanup EXIT; trap 'exit 143' TERM; dkr logs "${NAME}" ;;
  outside) CONTAINERS=(unrelated-canary); trap cleanup EXIT; exit 0 ;;
  supervisor-kill) bounded_command 1 1 docker logs "${NAME}" ;;
  cleanup-budget) CLEANUP_DEADLINE=$((SECONDS + 5)); dkr logs "${NAME}" ;;
  cleanup-exhausted) CLEANUP_DEADLINE=$SECONDS; dkr inspect "${NAME}" ;;
  supervisor-term)
    exec python3 "${ROOT}/tests/container_smoke_deadline.py" --timeout 30 --kill-after 30 \
      bash "$0" "$ROOT" "$ARTIFACTS" "$PREFIX" "$NAME" interrupt ;;
esac
'''


def process_stat(pid):
    """Return parent and immutable lifetime identity; zombies still count."""
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return int(fields[1]), fields[19]
    except (FileNotFoundError, ProcessLookupError):
        return None


def alive(record):
    stat = process_stat(record["pid"])
    return stat is not None and stat[1] == record["start_ticks"]


class FaultTests(unittest.TestCase):
    def setUp(self):
        self.path = RUN / self._testMethodName
        self.path.mkdir()  # Never admit case files from another suite invocation.
        self.command = None
        self.pidfds = {}
        self.guardian_fds = []
        self.nonce = uuid.uuid4().hex
        (self.path / "docker").write_text(DOCKER)
        (self.path / "docker").chmod(0o700)
        (self.path / "driver.sh").write_text(DRIVER)
        self.state = self.path / "state.json"
        self.pids = self.path / "pids"
        self.log = self.path / (NAME + ".log")
        self.log.write_text("VALID_ASSERTION_EVIDENCE\n")
        self.env = dict(os.environ, PATH=str(self.path) + ":" + os.environ["PATH"],
                        FAULT_STATE=str(self.state), FAULT_PIDS=str(self.pids),
                        FAULT_NONCE=self.nonce)

    def tearDown(self):
        self.kill_recorded()  # Only identity-verified, current-invocation fixtures.
        if self.command is not None and self.command.poll() is None:
            # Popen's unreaped direct child owns this session; PID cannot recycle.
            os.killpg(self.command.pid, signal.SIGKILL)
            self.command.communicate(timeout=5)
        for fd in self.pidfds.values():
            os.close(fd)

    def initialize(self, fault="none", resources=None):
        self.state.write_text(json.dumps(dict(fault=fault, queries=0, calls=[],
                                             resources={NAME: PREFIX} if resources is None else resources)))

    def data(self):
        return json.loads(self.state.read_text())

    def invoke(self, fault="none", mode="cleanup", resources=None, status=0, bound: float=30,
               crash_supervisor=False):
        self.initialize(fault, resources)
        for fd in self.pidfds.values():
            os.close(fd)
        self.pidfds.clear()
        self.pids.unlink(missing_ok=True)
        self.nonce = uuid.uuid4().hex  # Also isolate multiple calls in one case.
        self.env["FAULT_NONCE"] = self.nonce
        command = ["bash", str(self.path / "driver.sh"), str(ROOT), str(self.path),
                   PREFIX, NAME, mode, str(status)]
        start = time.monotonic()
        p = subprocess.Popen(command, env=self.env, start_new_session=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.command = p
        try:
            # Capture ownership before ANY ignoring-TERM fixture's supervisor
            # can die/reparent its detached CLI; watchdogs retain these pidfds.
            if fault == "ignore-term":
                self.await_pids(p)
            if mode in ("term", "supervisor-term"):
                p.send_signal(signal.SIGTERM)  # Signal the shell, not its CLI.
            if crash_supervisor:
                self.crash_cli_supervisor(p)
            output, _ = p.communicate(timeout=bound)
        except subprocess.TimeoutExpired:
            # Test watchdog is not proof of a harness bound; report FAIL below.
            self.kill_recorded()  # Verify ancestry before killing the leader.
            if p.poll() is None:
                os.killpg(p.pid, signal.SIGKILL)
            output, _ = p.communicate(timeout=5)
            (self.path / "output.log").write_bytes(output)
            self.fail(f"watchdog expired ({bound}s): controlled command lacked a hard bound")
        finally:
            elapsed = time.monotonic() - start
        (self.path / "output.log").write_bytes(output)
        (self.path / "result.json").write_text(json.dumps(dict(exit=p.returncode, elapsed=elapsed)))
        return p.returncode, elapsed, output.decode()

    def current_records(self):
        try:
            record = json.loads(self.pids.read_text())
            if not isinstance(record, dict) or record.get("nonce") != self.nonce:
                return []
            processes = record["processes"]
            if (not isinstance(processes, list) or len(processes) != 2 or any(
                    not isinstance(r, dict) or type(r.get("pid")) is not int or
                    r["pid"] <= 0 or not isinstance(r.get("start_ticks"), str) or
                    not r["start_ticks"].isdigit() for r in processes)):
                return []
            if processes[0]["pid"] == processes[1]["pid"]:
                return []
            return processes
        except (OSError, ValueError, KeyError, TypeError):
            return []  # Legacy numeric, malformed and foreign records cannot signal.

    def owned_pidfd(self, record, remember=True):
        key = (record["pid"], record["start_ticks"])
        if key in self.pidfds:
            fd = self.pidfds[key]  # A pidfd never retargets a recycled numeric PID.
            return fd if remember else os.dup(fd)
        pid = record["pid"]
        try:
            fd = os.pidfd_open(pid)
        except (OSError, OverflowError):
            return None
        accepted = False
        try:
            # Verify *after* opening: binds this start time to that exact pidfd.
            if not alive(record) or self.command is None:
                return None
            environ = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
            if f"FAULT_NONCE={self.nonce}".encode() not in environ:
                return None
            ancestor = pid
            while ancestor > 1 and ancestor != self.command.pid:
                stat = process_stat(ancestor)
                if stat is None:
                    return None
                ancestor = stat[0]
            if ancestor != self.command.pid:
                return None
            if remember:
                self.pidfds[key] = fd
            accepted = True
            return fd
        except (OSError, ProcessLookupError):
            return None
        finally:
            if not accepted:
                os.close(fd)

    def await_pids(self, p):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and p.poll() is None:
            records = self.current_records()
            if records and all(self.owned_pidfd(r) is not None for r in records):
                (self.path / "readiness.json").write_text(json.dumps(
                    dict(nonce=self.nonce, processes=records, leader=p.pid)))
                return
            time.sleep(0.02)
        self.fail("current owned ignoring-TERM fixture did not become ready")

    def kill_recorded(self):
        fds = set(self.pidfds.values())  # Retain verified ownership if a file is damaged.
        for record in self.current_records():
            fd = self.owned_pidfd(record)
            if fd is not None:
                fds.add(fd)
        for fd in fds:
            try:
                signal.pidfd_send_signal(fd, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def assert_no_descendants(self):
        records = self.current_records()
        self.assertEqual(len(records), 2, "missing current invocation PID identities")
        lingering = [r for r in records if alive(r)]
        self.kill_recorded()  # Cleanup can never target a recycled PID.
        self.assertEqual(lingering, [], "controlled descendants survived the deadline")

    def start_canary(self, owned=False):
        # Fresh subprocess, installed signal handlers and explicit readiness.
        signals = self.path / ("canary-signals-" + uuid.uuid4().hex + ".log")
        code = ("import signal,sys; from pathlib import Path; "
                f"p=Path({str(signals)!r}); "
                "handler=lambda s,f: p.open('a').write(str(s)+'\\n'); "
                "signal.signal(signal.SIGTERM,handler); "
                "signal.signal(signal.SIGINT,handler); "
                "print('READY',flush=True)\n"
                "for line in sys.stdin: print('ALIVE',flush=True)\n")
        canary = subprocess.Popen([sys.executable, "-c", code],
                                  env=self.env if owned else os.environ,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  start_new_session=True)
        def stop():
            if canary.poll() is None:
                canary.kill()  # Direct, unreaped child; never a PID-file target.
            canary.communicate(timeout=5)
        self.addCleanup(stop)
        assert canary.stdout is not None
        self.assertTrue(select.select([canary.stdout], [], [], 5)[0], "canary readiness")
        self.assertEqual(canary.stdout.readline(), b"READY\n")
        return canary, signals

    def assert_canary_untouched(self, canary, signals):
        # Round-trip after the operation prevents a delayed signal false-PASS.
        assert canary.stdin is not None and canary.stdout is not None
        canary.stdin.write(b"CHECK\n")
        canary.stdin.flush()
        self.assertTrue(select.select([canary.stdout], [], [], 5)[0], "canary liveness")
        self.assertEqual(canary.stdout.readline(), b"ALIVE\n")
        self.assertIsNone(canary.poll(), "unrelated canary was killed")
        self.assertFalse(signals.exists(), "unrelated canary received a signal")

    def test_repeated_artifact_base_uses_current_readiness(self):
        base = self.path / "repeated-base"
        target = "test_supervisor_term_cleans_up_nested_cli"
        legacy = base / target
        legacy.mkdir(parents=True)
        canary, signals = self.start_canary()
        (legacy / "pids").write_text(str(canary.pid))  # Old-format stale PID canary.
        runs = []
        for index in (1, 2):
            env = dict(os.environ, FAULT_ARTIFACT_DIR=str(base))
            result = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                                     "FaultTests." + target], env=env,
                                    capture_output=True, text=True, timeout=35)
            (self.path / f"repeat-{index}.log").write_text(result.stdout + result.stderr)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            run = Path(next(line.removeprefix("FAULT artifacts: ") for line in
                            result.stdout.splitlines() if line.startswith("FAULT artifacts: ")))
            self.assertEqual(run.parent, base)
            self.assertNotEqual(run, legacy)
            readiness = json.loads((run / target / "readiness.json").read_text())
            pids = json.loads((run / target / "pids").read_text())
            self.assertEqual(readiness["nonce"], pids["nonce"])
            self.assertEqual(readiness["processes"], pids["processes"])
            self.assertFalse(any(alive(r) for r in pids["processes"]))
            runs.append((run, pids["nonce"]))
            self.assert_canary_untouched(canary, signals)
        self.assertNotEqual(runs[0][0], runs[1][0])
        self.assertNotEqual(runs[0][1], runs[1][1])
        self.assertEqual((legacy / "pids").read_text(), str(canary.pid))

    def test_stale_and_unverified_pid_records_preserve_canary(self):
        canary, signals = self.start_canary()
        foreign_child, foreign_signals = self.start_canary(owned=True)
        self.command = canary
        stat, foreign_stat = process_stat(canary.pid), process_stat(foreign_child.pid)
        assert stat is not None and foreign_stat is not None
        identities = [dict(pid=canary.pid, start_ticks=stat[1]),
                      dict(pid=foreign_child.pid, start_ticks=foreign_stat[1])]
        for record in (str(canary.pid),
                       json.dumps(dict(nonce="previous-run", processes=identities)),
                       json.dumps(dict(nonce=self.nonce, processes=identities))):
            self.pids.write_text(record)
            self.kill_recorded()
            self.assert_canary_untouched(canary, signals)
            self.assert_canary_untouched(foreign_child, foreign_signals)
        self.assertEqual(self.pidfds, {})  # Nonce alone is not ancestry proof.
        self.command = None
        status, _, _ = self.invoke("ignore-term", "supervisor-term", bound=29)
        self.assertEqual(status, 143)  # A current fixture, not the stale file, admitted TERM.
        self.assert_no_descendants()
        self.assert_canary_untouched(canary, signals)
        self.assert_canary_untouched(foreign_child, foreign_signals)

    def test_recycled_pid_start_identity_is_not_signaled(self):
        canary, signals = self.start_canary(owned=True)
        second, second_signals = self.start_canary(owned=True)
        self.command = canary
        stat, second_stat = process_stat(canary.pid), process_stat(second.pid)
        assert stat is not None and second_stat is not None
        wrong_identity = dict(pid=canary.pid, start_ticks=str(int(stat[1]) + 1))
        self.pids.write_text(json.dumps(dict(nonce=self.nonce,
            processes=[wrong_identity, dict(pid=second.pid, start_ticks=second_stat[1])])))
        self.kill_recorded()
        self.assert_canary_untouched(canary, signals)
        self.assert_canary_untouched(second, second_signals)
        self.assertEqual(self.pidfds, {})
        # Remove the fixture leader from teardown: explicit canary cleanup owns it.
        self.command = None

    def assert_no_rm(self):
        self.assertFalse(any(c[0] == "rm" for c in self.data()["calls"]))

    def crash_cli_supervisor(self, p):
        # Fault-injection guardian handles must not provide production fallback
        # ownership: a missing early capture must still fail this regression.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and p.poll() is None:
            records = self.current_records()
            fds = [self.owned_pidfd(r, remember=False) for r in records]
            if records and all(fd is not None for fd in fds):
                self.guardian_fds = fds
                parent = process_stat(records[0]["pid"])
                assert parent is not None
                supervisor = process_stat(parent[0])
                assert supervisor is not None
                fd = self.owned_pidfd(dict(pid=parent[0], start_ticks=supervisor[1]))
                self.assertIsNotNone(fd, "cannot prove injected supervisor ownership")
                signal.pidfd_send_signal(fd, signal.SIGKILL)
                return
            for fd in fds:
                if fd is not None:
                    os.close(fd)
            time.sleep(0.02)
        self.fail("current owned fixture did not become ready for supervisor crash")

    def reap_fixture_children(self):
        # Only this regression opts in as a subreaper. Reap its adopted,
        # identity-verified fixtures, never Popen's direct command child.
        deadline = time.monotonic() + 2
        records = self.current_records()
        while time.monotonic() < deadline:
            for record in records:
                if not alive(record):
                    continue
                try:
                    os.waitpid(record["pid"], os.WNOHANG)
                except ChildProcessError:
                    pass
            if not any(alive(r) for r in records):
                return
            time.sleep(0.01)

    def test_supervisor_crash_watchdog_retains_fixture_ownership(self):
        libc = ctypes.CDLL(None, use_errno=True)
        old = ctypes.c_int()
        self.assertEqual(libc.prctl(37, ctypes.byref(old), 0, 0, 0), 0)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
        try:
            with self.assertRaisesRegex(AssertionError, "watchdog expired"):
                self.invoke("ignore-term", "cli", bound=0.2, crash_supervisor=True)
            self.reap_fixture_children()
            # Assert before guardian cleanup; watchdog failure is expected,
            # but surviving processes/zombies can never be a regression PASS.
            self.assert_no_descendants()
        finally:
            try:
                for fd in self.guardian_fds:
                    try:
                        signal.pidfd_send_signal(fd, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                self.reap_fixture_children()
                if self.command is not None:
                    self.command.communicate(timeout=5)
            finally:
                for fd in self.guardian_fds:
                    os.close(fd)
                self.assertEqual(libc.prctl(36, old.value, 0, 0, 0), 0)

    def test_deadline_pins_exited_leader_until_group_signal(self):
        probe = self.path / "pin_probe.py"
        probe.write_text(r'''import json, os, runpy, signal, sys
from pathlib import Path
supervisor = runpy.run_path(sys.argv[1])
real_killpg = os.killpg
observations = []
def checked_killpg(pid, signum):
    if signum == signal.SIGKILL:
        stat = Path(f'/proc/{pid}/stat')
        state = stat.read_text().rsplit(')', 1)[1].split()[0] if stat.exists() else None
        observations.append(dict(pid=pid, leader_state=state))
        Path(sys.argv[2]).write_text(json.dumps(observations))
        assert state == 'Z', 'leader was reaped before group signal; numeric PGID is unpinned'
    real_killpg(pid, signum)
os.killpg = checked_killpg
assert supervisor['run']([sys.executable, '-c', 'pass'], 2, 1) == 0
assert len(observations) == 1
assert not Path(f"/proc/{observations[0]['pid']}").exists()
''')
        result = subprocess.run([sys.executable, str(probe),
            str(ROOT / "tests/container_smoke_deadline.py"), str(self.path / "pinning.json")],
            capture_output=True, text=True, timeout=5, start_new_session=True)
        (self.path / "output.log").write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        record = json.loads((self.path / "pinning.json").read_text())
        self.assertEqual(record[0]["leader_state"], "Z")
        self.assertFalse(Path(f"/proc/{record[0]['pid']}").exists())

    def test_cleanup_success_readback(self):
        status, _, _ = self.invoke()
        self.assertEqual(status, 0)
        self.assertEqual(self.data()["resources"], {})
        self.assertGreaterEqual(self.data()["queries"], 2, "cleanup never read back inventory")
        self.assertIn("FAKE_LISTENER_READY", self.log.read_text())
        self.assertIn("FAKE_STDERR_EVIDENCE", self.log.read_text())

    def test_query_exit1_fails_closed(self):
        status, _, output = self.invoke("query1")
        self.assertNotEqual(status, 0)
        self.assert_no_rm()
        self.assertIn("cleanup", output.lower())

    def test_query_exit124_fails_closed(self):
        status, _, _ = self.invoke("query124")
        self.assertNotEqual(status, 0)
        self.assert_no_rm()

    def test_rm_exit0_but_resource_remains(self):
        status, _, _ = self.invoke("rm-noop")
        self.assertNotEqual(status, 0)
        self.assertIn(NAME, self.data()["resources"])

    def test_rm_error_after_resource_disappears(self):
        status, _, _ = self.invoke("rm-error")
        self.assertNotEqual(status, 0)
        self.assertEqual(self.data()["resources"], {})

    def test_readback_failure_is_not_success(self):
        status, _, _ = self.invoke("readback")
        self.assertNotEqual(status, 0)

    def test_log_failure_preserves_assertion_evidence(self):
        status, _, _ = self.invoke("log-failure")
        self.assertEqual(self.log.read_text(), "VALID_ASSERTION_EVIDENCE\n")
        self.assertNotEqual(status, 0)
        self.assertEqual(self.data()["resources"], {})
        self.assertTrue(list(self.path.glob("*.logs.error")))
        self.assertIn("injected logs failure", "".join(p.read_text() for p in self.path.glob("*.logs.error")))

    def test_genuinely_absent_succeeds(self):
        status, _, _ = self.invoke(resources={})
        self.assertEqual(status, 0)
        self.assert_no_rm()
        self.assertGreaterEqual(self.data()["queries"], 2)

    def test_ownership_mismatch_is_not_deleted(self):
        status, _, _ = self.invoke(resources={NAME: "unrelated-owner"})
        self.assertNotEqual(status, 0)
        self.assert_no_rm()
        self.assertEqual(self.data()["resources"], {NAME: "unrelated-owner"})

    def test_unrelated_names_are_not_deleted(self):
        resources = {NAME: PREFIX, "unrelated-canary": PREFIX,
                     PREFIX + "-not-recorded": PREFIX}
        status, _, _ = self.invoke(resources=resources)
        self.assertEqual(status, 0)
        self.assertEqual(self.data()["resources"], {k: v for k, v in resources.items() if k != NAME})
        self.assertEqual([c[-1] for c in self.data()["calls"] if c[0] == "rm"], ["id-" + NAME])

    def test_name_outside_unique_prefix_is_not_deleted(self):
        status, _, _ = self.invoke(mode="outside", resources={"unrelated-canary": PREFIX})
        self.assertNotEqual(status, 0)
        self.assert_no_rm()
        self.assertEqual(self.data()["resources"], {"unrelated-canary": PREFIX})

    def test_supervisor_kill_escalation_has_hard_bound(self):
        status, elapsed, _ = self.invoke("ignore-term", "supervisor-kill", bound=5)
        self.assertEqual(status, 124)
        self.assertLess(elapsed, 4)
        self.assert_no_descendants()

    def test_cleanup_budget_bounds_term_ignoring_cli(self):
        status, elapsed, _ = self.invoke("ignore-term", "cleanup-budget", bound=6)
        self.assertEqual(status, 124)
        self.assertLess(elapsed, 5.5)
        self.assert_no_descendants()

    def test_exhausted_cleanup_budget_starts_no_cli(self):
        status, _, output = self.invoke(mode="cleanup-exhausted")
        self.assertEqual(status, 124)
        self.assertEqual(self.data()["calls"], [])
        self.assertIn("cleanup deadline exhausted", output)

    def test_supervisor_term_cleans_up_nested_cli(self):
        status, elapsed, _ = self.invoke("ignore-term", "supervisor-term", bound=29)
        self.assertEqual(status, 143)
        self.assertLess(elapsed, 27)
        self.assertEqual(self.data()["resources"], {})
        self.assert_no_descendants()

    def test_original_error_status_is_preserved(self):
        status, _, _ = self.invoke("query1", status=7)
        self.assertEqual(status, 7)
        self.assert_no_rm()

    def test_late_ready_is_rejected_even_when_marker_present(self):
        status, _, output = self.invoke("late-ready", "ready", bound=22)
        self.assertNotEqual(status, 0)
        self.assertIn("readiness deadline", output)
        self.assertFalse(any(c[0] in ("top", "exec") for c in self.data()["calls"]))
        self.assertEqual(self.data()["resources"], {})

    def test_cli_term_ignore_is_killed_with_descendant(self):
        status, elapsed, _ = self.invoke("ignore-term", "cli", bound=25)
        self.assertNotEqual(status, 0)
        self.assertLess(elapsed, 24)
        self.assert_no_descendants()

    def test_suite_timeout_cleans_up_and_kills_nested_cli(self):
        status, elapsed, _ = self.invoke("ignore-term", "suite", bound=29)
        self.assertEqual(status, 124)
        self.assertLess(elapsed, 27)
        self.assertEqual(self.data()["resources"], {})
        self.assert_no_descendants()

    def test_shell_term_cleans_up_with_bounded_cli(self):
        status, elapsed, _ = self.invoke("ignore-term", "term", bound=29)
        self.assertEqual(status, 143)
        self.assertLess(elapsed, 27)
        self.assertEqual(self.data()["resources"], {})
        self.assert_no_descendants()


if __name__ == "__main__":
    print(f"FAULT artifacts: {RUN}", flush=True)
    unittest.main(verbosity=2)
