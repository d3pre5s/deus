"""Collect one network sample from a local Claude Desktop Code session on macOS."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from egress_probe import git, ssh, trace


def process_tree():
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,comm="], text=True)
    processes = {}
    for line in output.splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3:
            processes[int(fields[0])] = (int(fields[1]), fields[2])
    names = []
    seen = set()
    pid = os.getpid()
    while pid in processes and pid not in seen:
        seen.add(pid)
        pid, path = processes[pid]
        names.append(path)
    return names


def main(output, tree):
    probes = {
        "curl": lambda: trace(["/usr/bin/curl"]),
        "ssh": lambda: ssh("/usr/bin/ssh"),
        "git": git,
    }
    with ThreadPoolExecutor(max_workers=len(probes)) as pool:
        jobs = {key: pool.submit(probe) for key, probe in probes.items()}
        result = {key: job.result() for key, job in jobs.items()}
    result["processes"] = tree
    tmp = output.with_suffix(".tmp")
    tmp.write_text(json.dumps(result, ensure_ascii=False))
    tmp.replace(output)
    print(result["curl"], flush=True)


if __name__ == "__main__":
    tree = process_tree()
    have_desktop = any(path.startswith("/Applications/Claude.app/Contents/") for path in tree)
    have_local_code = any("/Library/Application Support/Claude/claude-code/" in path for path in tree)
    if not (have_desktop and have_local_code):
        raise SystemExit("Проба должна быть потомком локальной Code-сессии в Claude Desktop")
    folder = Path(sys.argv[1])
    main(folder / "up.json", tree)
    for phase in ("down", "restored"):
        for _ in range(240):
            if (folder / (phase + ".request")).exists():
                break
            time.sleep(0.25)
        else:
            sys.exit("Закончилось время ожидания фазы " + phase)
        main(folder / (phase + ".json"), tree)
