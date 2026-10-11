#!/usr/bin/env python3
"""Bound a test command and its process group, including TERM-ignoring children.

Each nested Docker call gets its own supervisor. The suite signals those
supervisors too; they escalate their own detached groups before suite cleanup.
This is harness-only, not a production runner signal policy.
"""
import argparse
import ctypes
import os
import signal
import subprocess
import sys
import time


def run(command, seconds, kill_after):
    # Linux subreaper: reap killed CLI grandchildren ourselves instead of
    # relying on the host/container PID 1 to collect orphan zombies.
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), "could not enable deadline subreaper")
    interrupted = 0

    def on_signal(signum, _frame):
        nonlocal interrupted
        if not interrupted:
            interrupted = signum

    # Install before spawning: a suite TERM must never strand a detached CLI.
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    child = subprocess.Popen(command, start_new_session=True)

    def send(signum):
        try:
            os.killpg(child.pid, signum)
        except ProcessLookupError:
            pass

    deadline = time.monotonic() + seconds
    stop_at = None
    timed_out = False
    while True:
        now = time.monotonic()
        if stop_at is None and (interrupted or now >= deadline):
            timed_out = not interrupted
            if timed_out:
                print(f"deadline exceeded ({seconds:g}s): {command[0]}", file=sys.stderr)
            send(signal.SIGTERM)
            stop_at = now + kill_after
        exited = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        if exited is not None:
            # Keep the exited leader unreaped until group signaling finishes.
            # Its zombie pins this PID/PGID against unrelated numeric reuse.
            send(signal.SIGKILL)
            result = child.wait()
            break
        if stop_at is not None and now >= stop_at:
            send(signal.SIGKILL)
            result = child.wait()
            break
        time.sleep(0.02)
    # Adopted, killed grandchildren must also be reaped. Never wait forever
    # for an unexpected escaped child; failure remains visible/nonzero.
    reap_deadline = time.monotonic() + 0.5
    reaped = True
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            break
        if pid:
            continue
        if time.monotonic() >= reap_deadline:
            print("deadline descendant reap did not complete within 0.5s", file=sys.stderr)
            reaped = False
            break
        time.sleep(0.01)
    if timed_out:
        return 124
    if interrupted:
        return 128 + interrupted
    if not reaped:
        return 1
    return result if result >= 0 else 128 - result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--kill-after", type=float, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.timeout <= 0 or args.kill_after <= 0 or not args.command:
        parser.error("positive bounds and a command are required")
    return run(args.command, args.timeout, args.kill_after)


if __name__ == "__main__":
    sys.exit(main())
