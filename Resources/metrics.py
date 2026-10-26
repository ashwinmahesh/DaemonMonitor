"""Local process counters and bounded SQLite history. Never controls a service."""
import ctypes
from contextlib import contextmanager
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shlex
import sqlite3
import subprocess
import time
import uuid

RANGES = {'5m': 300, '30m': 1800, '1h': 3600, '6h': 21600,
          '24h': 86400, '3d': 259200, '7d': 604800}
RETENTION = RANGES['7d']


class RUsage(ctypes.Structure):
    # Public Darwin rusage_info_v2 ABI (sys/resource.h).
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        'user', 'system', 'idle_wakeups', 'interrupt_wakeups', 'pageins', 'wired',
        'resident', 'footprint', 'started', 'exited', 'child_user', 'child_system',
        'child_idle', 'child_interrupts', 'child_pageins', 'child_elapsed', 'read', 'written')]


def process_usage(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    library.proc_pid_rusage.restype = ctypes.c_int
    info = RUsage()
    if library.proc_pid_rusage(pid, 2, ctypes.byref(info)):
        return None  # Process exited or its counters are inaccessible.
    return {'start': info.started, 'cpu': info.user + info.system, 'memory': info.footprint}


def process_table():
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,uid=,command='],
                            capture_output=True, text=True, check=True, timeout=5)
    table = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) == 4 and int(parts[2]) == os.getuid():
            table[int(parts[0])] = {'parent': int(parts[1]), 'command': parts[3]}
    return table


def parse_gpu_registry(rows):
    counters = {}
    available = False
    def walk(entries):
        nonlocal available
        for entry in entries:
            if entry.get('IOObjectClass') == 'AGXDeviceUserClient':
                usage_rows = entry.get('AppUsage')
                if not isinstance(usage_rows, list):
                    continue
                available = True
                match = re.match(r'pid (\d+),', entry.get('IOUserClientCreator', ''))
                if match:
                    pid = int(match[1])
                    for index, usage in enumerate(usage_rows):
                        if not isinstance(usage, dict):
                            continue
                        value = usage.get('accumulatedGPUTime')
                        if isinstance(value, (int, float)) and value >= 0:
                            key = str(entry['IORegistryEntryID']) + ':' + str(index)
                            counters.setdefault(pid, {})[key] = int(value)
            walk(entry.get('IORegistryEntryChildren', []))
    walk(rows)
    return available, counters


def gpu_counters():
    try:
        result = subprocess.run(['/usr/sbin/ioreg', '-r', '-c', 'AGXDeviceUserClient', '-a'],
                                capture_output=True, check=True, timeout=5)
        return parse_gpu_registry(plistlib.loads(result.stdout))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, plistlib.InvalidFileException):
        return False, {}


def service_processes(controller, table, include_roots=False):
    pairs = [(str(pid), row['command']) for pid, row in table.items()]
    roots = {}
    for identifier in (s['id'] for s in controller.config['services']):
        try:
            record = json.loads(controller.active_file(identifier).read_text())
        except FileNotFoundError:
            record = None
        candidates = [record['settings']] if record else []
        candidates.append(controller.desired(identifier))
        roots[identifier] = set()
        for item in candidates:
            normalized = pairs
            if identifier == 'bridge':
                binary = str(Path(item['binary']).expanduser().absolute())
                # ps prints argv without quoting. Preserve the bridge executable's spaces.
                normalized = [(pid, shlex.quote(binary) + command[len(binary):])
                              for pid, command in pairs if command.startswith(binary + ' ')]
            else:
                scripts = ('queue_api.py',) if identifier == 'image-queue' else ('queue_server.py',) if identifier == 'voice-queue' else ('server.py', 'launch.py')
                normalized = [(pid, command) for pid, command in pairs if any(script in command for script in scripts)]
            found = set(controller.owned_processes(item, normalized))
            if found:
                roots[identifier] = found
                break
    children = {}
    for pid, row in table.items():
        children.setdefault(row['parent'], []).append(pid)
    groups = {}
    for identifier, own in roots.items():
        boundaries = set().union(*(p for key, p in roots.items() if key != identifier))
        found, todo = set(), list(own)
        while todo:
            pid = todo.pop()
            if pid in found or pid in boundaries:
                continue
            found.add(pid)
            todo.extend(children.get(pid, []))
        groups[identifier] = found
    return (groups, roots) if include_roots else groups


class MetricsStore:
    def __init__(self, support):
        support = Path(support)
        support.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = support / 'metrics.sqlite3'

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=8)
        self.path.chmod(0o600)
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('PRAGMA synchronous=NORMAL')
        db.executescript('''
            CREATE TABLE IF NOT EXISTS samples (
                service TEXT NOT NULL, ts REAL NOT NULL, cpu REAL, memory REAL, gpu REAL,
                processes INTEGER NOT NULL, interval INTEGER NOT NULL,
                run TEXT NOT NULL DEFAULT '',
                PRIMARY KEY(service, ts));
            CREATE TABLE IF NOT EXISTS baselines (
                service TEXT NOT NULL, pid INTEGER NOT NULL, started TEXT NOT NULL,
                cpu INTEGER NOT NULL, gpu TEXT, uptime REAL NOT NULL,
                PRIMARY KEY(service,pid));
            CREATE INDEX IF NOT EXISTS samples_time ON samples(ts);
            CREATE TABLE IF NOT EXISTS runs (
                service TEXT PRIMARY KEY, token TEXT NOT NULL, roots TEXT NOT NULL);
        ''')
        if 'run' not in {row[1] for row in db.execute('PRAGMA table_info(samples)')}:
            db.execute("ALTER TABLE samples ADD COLUMN run TEXT NOT NULL DEFAULT ''")
            db.execute('DELETE FROM samples WHERE processes=0')
            db.commit()
        try:
            with db:
                yield db
        finally:
            db.close()

    def sample(self, controller, interval=60, now=None, uptime=None, table=None,
               usage_reader=process_usage, gpu_reader=gpu_counters):
        now = time.time() if now is None else now
        uptime = time.monotonic() if uptime is None else uptime
        table = process_table() if table is None else table
        groups, roots = service_processes(controller, table, include_roots=True)
        gpu_available, gpus = gpu_reader() if any(groups.values()) else (False, {})
        samples = []
        with self.connect() as db:
            for identifier, pids in groups.items():
                if not pids:
                    db.execute('DELETE FROM baselines WHERE service=?', (identifier,))
                    db.execute('DELETE FROM runs WHERE service=?', (identifier,))
                    continue
                previous = {row[0]: row[1:] for row in db.execute(
                    'SELECT pid,started,cpu,gpu,uptime FROM baselines WHERE service=?', (identifier,))}
                current, identities, cpu, memory, gpu = [], {}, 0.0, 0, 0.0
                cpu_known, memory_known, gpu_known = True, True, gpu_available
                for pid in sorted(pids):
                    value = usage_reader(pid)
                    if value is None:
                        cpu_known = memory_known = gpu_known = False
                        continue
                    identities[pid] = str(value['start'])
                    memory += value['memory']
                    prior = previous.get(pid)
                    elapsed = uptime - prior[3] if prior else 0
                    comparable = prior and str(value['start']) == prior[0] and 0 < elapsed <= 150
                    if comparable and value['cpu'] >= prior[1]:
                        cpu += (value['cpu'] - prior[1]) / (elapsed * 1e9) * 100
                    else:
                        cpu_known = False
                    counters = gpus.get(pid, {}) if gpu_available else None
                    old_gpu = json.loads(prior[2]) if comparable and prior[2] is not None else None
                    if counters:
                        if old_gpu is None:
                            gpu_known = False
                        else:
                            for key, total in counters.items():
                                if key not in old_gpu or total < old_gpu[key]:
                                    gpu_known = False
                                else:
                                    gpu += (total - old_gpu[key]) / (elapsed * 1e9) * 100
                    if old_gpu and counters is not None and set(old_gpu) - set(counters):
                        gpu_known = False
                    current.append((identifier, pid, str(value['start']), value['cpu'],
                                    json.dumps(counters) if counters is not None else None, uptime))
                signature = json.dumps([(pid, identities.get(pid)) for pid in sorted(roots[identifier])])
                run = db.execute('SELECT token,roots FROM runs WHERE service=?', (identifier,)).fetchone()
                token = run[0] if run and run[1] == signature else uuid.uuid4().hex
                db.execute('INSERT OR REPLACE INTO runs VALUES (?,?,?)', (identifier, token, signature))
                point = {'timestamp': now, 'cpu': cpu if cpu_known else None,
                         'memory': memory if memory_known else None,
                         'gpu': gpu if gpu_known else None, 'processes': len(pids), 'run': token}
                db.execute('INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?,?,?,?)',
                           (identifier, now, point['cpu'], point['memory'], point['gpu'], len(pids), interval, token))
                db.execute('DELETE FROM baselines WHERE service=?', (identifier,))
                db.executemany('INSERT INTO baselines VALUES (?,?,?,?,?,?)', current)
                samples.append({'id': identifier, **point})
            db.execute('DELETE FROM samples WHERE ts < ?', (now - RETENTION,))
        return {'ok': True, 'sampled_at': now, 'services': samples}

    def history(self, identifier, range_name, now=None):
        duration = RANGES[range_name]
        now = time.time() if now is None else now
        start = now - duration
        resolution = max(15, math.ceil(duration / 360 / 15) * 15)
        with self.connect() as db:
            rows = db.execute('''SELECT MAX(ts), AVG(cpu), AVG(memory), AVG(gpu), MAX(processes),
                CASE WHEN COUNT(DISTINCT run)=1 THEN MIN(run) ELSE 'mixed:' || MIN(ts) END
                FROM samples WHERE service=? AND ts>=? AND ts<=?
                GROUP BY CAST((ts-?)/? AS INTEGER) ORDER BY MAX(ts)''',
                (identifier, start, now, start, resolution)).fetchall()
            latest = db.execute('''SELECT ts,cpu,memory,gpu,processes,run FROM samples
                WHERE service=? AND ts>=? AND ts<=? ORDER BY ts DESC LIMIT 1''',
                (identifier, start, now)).fetchone()
            peaks = db.execute('SELECT MAX(cpu),MAX(memory),MAX(gpu) FROM samples WHERE service=? AND ts>=? AND ts<=?',
                               (identifier, start, now)).fetchone()
            first = db.execute('SELECT MIN(ts) FROM samples WHERE service=?', (identifier,)).fetchone()[0]
            running = db.execute('SELECT 1 FROM runs WHERE service=?', (identifier,)).fetchone() is not None
        def point(row):
            return dict(zip(('timestamp', 'cpu', 'memory', 'gpu', 'processes', 'run'), row)) if row else None
        return {'ok': True, 'id': identifier, 'range': range_name, 'start': start, 'end': now,
                'resolution': resolution, 'recording_since': first, 'running': running,
                'points': [point(row) for row in rows], 'latest': point(latest),
                'peaks': dict(zip(('cpu', 'memory', 'gpu'), peaks))}
