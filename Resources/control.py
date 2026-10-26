#!/usr/bin/env python3
"""Local-only lifecycle adapter. No third-party packages or shell evaluation."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import copy
import fcntl
import http.client
import json
import os
from pathlib import Path
import plistlib
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time

IDS = ('bridge', 'image', 'image-queue', 'voice', 'voice-queue')
NAMES = ('ai-bridge', 'Image gen service', 'Image gen queue', 'Voice gen service', 'Voice gen queue')
IMAGE_MODELS = ('z-image-turbo', 'chroma1-hd', 'chroma1-flash')
VOICE_MODELS = ('voxcpm2', 'qwen3', 'chatterbox', 'indextts', 'moss', 'fish', 'higgs')
LABEL = 'local.ai-bridge.api'
DEFAULT_SUPPORT = Path.home() / 'Library/Application Support/DaemonMonitor'


def defaults():
    image = '~/Documents/models/ImageGen-Service'
    voice = '~/Documents/models/VoiceGen-Service'
    return {'services': [
        dict(id='bridge', name=NAMES[0], port=8765, root='~/Library/Application Support/AI Bridge',
             binary='~/Library/Application Support/AI Bridge/bin/ai-bridge', log_file_only=True, environment=''),
        dict(id='image', name=NAMES[1], port=5732, root=image, model='z-image-turbo', llm=True, loras=True, environment=''),
        dict(id='image-queue', name=NAMES[2], port=55302, root=image, environment=''),
        dict(id='voice', name=NAMES[3], port=5743, root=voice, model='higgs', llm=True, environment=''),
        dict(id='voice-queue', name=NAMES[4], port=55205, root=voice, environment='')
    ]}


def path(value):
    return Path(value).expanduser().absolute()


def atomic_json(destination, value):
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=destination.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            json.dump(value, handle, indent=2)
            handle.write('\n')
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def read_json(filename, fallback=None):
    try: return json.loads(filename.read_text())
    except FileNotFoundError: return copy.deepcopy(fallback)


def environment(text):
    result = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'): continue
        key, separator, value = line.partition('=')
        if not separator or not key or not key.replace('_', 'a').isalnum() or key[0].isdigit():
            raise ValueError('Environment overrides must use KEY=value, one per line.')
        if key in ('HOME', 'PATH', 'MODEL', 'IMAGE_MODEL', 'MODEL_BACKEND', 'PORT', 'QUEUE_PORT', 'NO_LLM', 'NO_LORAS', 'NONINTERACTIVE'):
            raise ValueError('Use the named controls for ' + key + '; HOME and PATH are managed by the app.')
        result[key] = value
    return result


def validate(config):
    services = config['services']
    if [s['id'] for s in services] != list(IDS): raise ValueError('Expected exactly the five configured services.')
    ports = []
    for item in services:
        if type(item['port']) is not int or not 1024 <= item['port'] <= 65535:
            raise ValueError('Ports must be between 1024 and 65535.')
        ports.append(item['port'])
        if not item['root'].startswith(('/', '~/')): raise ValueError('Project/state paths must be absolute or start with ~/.')
        environment(item.get('environment', ''))
        for flag in ('llm', 'loras', 'log_file_only'):
            if flag in item and type(item[flag]) is not bool: raise ValueError(flag + ' must be a boolean.')
    if len(set(ports)) != len(ports): raise ValueError('Each service needs a different port.')
    if services[1]['model'] not in IMAGE_MODELS or services[3]['model'] not in VOICE_MODELS:
        raise ValueError('Choose a supported model.')
    for a, b in ((1, 2), (3, 4)):
        if path(services[a]['root']) != path(services[b]['root']):
            raise ValueError('A generator and its queue must use the same project folder.')
    if not services[0]['binary'].startswith(('/', '~/')): raise ValueError('Executable path must be absolute or start with ~/.')
    return config


class Controller:
    def __init__(self, support=DEFAULT_SUPPORT):
        self.support = Path(support)
        self.config_file = self.support / 'services.json'
        self.config = validate(read_json(self.config_file, defaults()))
        self.health_errors = {}

    def item(self, identifier):
        return next(s for s in self.config['services'] if s['id'] == identifier)

    def active_file(self, identifier):
        return self.support / (identifier + '.active.json')

    def result_file(self, identifier):
        return self.support / (identifier + '.last-result.json')

    def desired(self, identifier):
        item = copy.deepcopy(self.item(identifier))
        if identifier in ('image', 'voice'):
            item['queue_port'] = self.item(identifier + '-queue')['port']
        return item

    @contextmanager
    def lock(self, name):
        self.support.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.support / (name + '.lock')).open('a') as handle:
            try: fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError: raise ValueError('Another operation is in progress for this service. Try again shortly.')
            yield

    def request(self, item, endpoint='/health', method='GET', body=None):
        connection = http.client.HTTPConnection('127.0.0.1', item['port'], timeout=1.5)
        headers = {}
        if item['id'] == 'bridge':
            headers['Authorization'] = 'Bearer ' + (path(item['root']) / 'token').read_text().strip()
        data = None if body is None else json.dumps(body).encode()
        if data is not None: headers['Content-Type'] = 'application/json'
        try:
            connection.request(method, endpoint, body=data, headers=headers)
            response = connection.getresponse()
            raw = response.read(2 * 1024 * 1024)
            if response.status != 200:
                message = 'Health/control request returned HTTP ' + str(response.status)
                try:
                    value = json.loads(raw)
                    detail = value.get('detail') or value.get('error')
                    if isinstance(detail, str): message += ': ' + detail[:500]
                except (ValueError, AttributeError): pass
                raise ValueError(message)
            return json.loads(raw)
        finally: connection.close()

    def matches(self, item, state):
        if not isinstance(state, dict): return False
        identifier, root = item['id'], str(path(item['root']).resolve())
        if identifier == 'bridge':
            return state.get('ok') is True and state.get('capabilities', {}).get('multi_project') is True
        if identifier.startswith('image'):
            return state.get('project_dir') == root and (state.get('service') == 'imagegen-queue' if identifier.endswith('queue') else state.get('model') in IMAGE_MODELS)
        return state.get('project') == root and (state.get('service') == 'voicegen-queue' and state.get('role') == 'queue-crud' if identifier.endswith('queue') else state.get('service') in VOICE_MODELS)

    def health(self, item):
        key = (item['id'], item['root'], item['port'])
        try:
            state = self.request(item)
            if self.matches(item, state):
                self.health_errors.pop(key, None)
                return state
            self.health_errors[key] = 'The health endpoint belongs to a different service or project.'
        except (OSError, ValueError, http.client.HTTPException) as error:
            self.health_errors[key] = 'Health check failed: ' + str(error)
        return None

    @staticmethod
    def processes():
        result = subprocess.run(['/bin/ps', '-axo', 'pid=,command='], capture_output=True, text=True, timeout=4)
        return [line.strip().split(None, 1) for line in result.stdout.splitlines() if len(line.strip().split(None, 1)) == 2]

    @staticmethod
    def fingerprint(pid):
        result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart=,command='], capture_output=True, text=True, timeout=3)
        return result.stdout.strip()

    @staticmethod
    def cwd_matches(pid, root):
        result = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'], capture_output=True, text=True, timeout=4)
        return 'n' + str(root.resolve()) in result.stdout.splitlines()

    def owned_processes(self, item, processes=None):
        root, identifier = path(item['root']), item['id']
        script = ('queue_api.py' if identifier == 'image-queue' else 'queue_server.py' if identifier == 'voice-queue' else 'server.py')
        result = []
        for pid, command in processes if processes is not None else self.processes():
            try: words = shlex.split(command)
            except ValueError: continue
            if not words: continue
            if identifier == 'bridge':
                if words[0] == str(path(item['binary'])) and 'serve' in words and '--port' in words and words[words.index('--port') + 1] == str(item['port']): result.append(int(pid))
                continue
            if 'python' not in Path(words[0]).name.lower(): continue
            # Other development threads may use this checkout on isolated test ports.
            # Such a process must never light up or stop the production toggle.
            if '--port' in words:
                offset = words.index('--port') + 1
                if offset >= len(words) or words[offset] != str(item['port']): continue
            elif item['port'] != next(s['port'] for s in defaults()['services'] if s['id'] == identifier):
                continue
            scripts = [script] + (['launch.py'] if identifier == 'image' else [])
            if not any(str(root / name) in words or name in words for name in scripts): continue
            if self.cwd_matches(pid, root): result.append(int(pid))
        return result

    @staticmethod
    def port_open(port):
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.25): return True
        except OSError: return False

    @staticmethod
    def health_problem(state):
        reasons = []
        for key in ('asset_errors', 'runtime_errors', 'last_error', 'error', 'detail'):
            value = state.get(key)
            for reason in value if isinstance(value, list) else [value]:
                if reason and str(reason) not in reasons: reasons.append(str(reason))
        error = state.get('queue', {}).get('error')
        if error and str(error) not in reasons: reasons.append(str(error))
        if not reasons:
            stage = str(state.get('status', 'unknown'))
            if stage == 'loading': return 'Starting: loading the model.'
            if state.get('downloaded') is False: return 'Required model assets are missing or unavailable.'
            return 'Health check reports: ' + stage + '.'
        return '\n'.join(reasons)[:1400]

    def inspect(self, item, processes=None, record=None):
        state = self.health(item)
        pids = self.owned_processes(item, processes)
        launcher = bool(record and record.get('launcher_pid') and record.get('fingerprint') and self.fingerprint(record['launcher_pid']) == record['fingerprint'])
        running = state is not None or bool(pids) or launcher
        healthy = False
        detail = 'Not started.'
        if state is not None:
            if item['id'] == 'bridge': healthy = True
            elif item['id'].endswith('queue'): healthy = state.get('status') == 'ready'
            elif item['id'] == 'image': healthy = state.get('status') == 'ready' and not state.get('queue', {}).get('error')
            else:
                healthy = bool(state.get('downloaded')) and not state.get('asset_errors') and not state.get('runtime_errors') and state.get('status') != 'error' and not state.get('last_error')
            detail = ('Healthy' if healthy else 'Needs attention') + ' · ' + str(state.get('status', 'ready'))
            if not healthy: detail = self.health_problem(state)
            if state.get('busy'): detail += ' · Busy'
            if state.get('model'): detail += ' · ' + state['model']
            elif item['id'] == 'voice': detail += ' · ' + state.get('service', '')
        elif running:
            detail = 'Starting: waiting for the health endpoint.' if launcher and not record.get('ready') else 'Service is running, but its health endpoint is not responding.'
            if not (launcher and not record.get('ready')):
                failure = self.health_errors.get((item['id'], item['root'], item['port']))
                if failure: detail += '\n' + failure
        elif self.port_open(item['port']):
            detail = self.health_errors.get((item['id'], item['root'], item['port']), 'Port is occupied by an unrecognized service')
        else:
            previous = read_json(self.result_file(item['id']), {})
            if previous.get('action') == 'start' and previous.get('error') and previous.get('settings') == item:
                detail = 'Last start failed: ' + previous['error']
            elif record and record.get('launcher_pid'):
                errors = [line for line in self.log_tail(self.log_path(item['id'])).splitlines()
                          if any(word in line.lower() for word in ('error', 'exception', 'failed', 'missing'))]
                detail = 'Service exited: ' + errors[-1] if errors else 'Not running. The service has exited.'
        return dict(id=item['id'], name=item['name'], running=running, healthy=healthy,
                    detail=detail, port=item['port'], state=state, pids=pids)

    def resolve(self, identifier, processes=None):
        record = read_json(self.active_file(identifier))
        if record:
            status = self.inspect(record['settings'], processes, record)
            if status['running']: return record['settings'], status
            if record['settings'] == self.desired(identifier): return record['settings'], status
        item = self.desired(identifier)
        status = self.inspect(item, processes)
        return item, status

    def snapshot(self):
        processes = self.processes()
        with ThreadPoolExecutor(max_workers=5) as pool:
            statuses = list(pool.map(lambda identifier: self.resolve(identifier, processes)[1], IDS))
        return {'ok': True, 'services': [{k: s[k] for k in ('id', 'name', 'running', 'healthy', 'detail', 'port')} for s in statuses]}

    def save(self, patch):
        with self.lock('configuration'):
            self.config = validate(read_json(self.config_file, defaults()))
            proposed = copy.deepcopy(self.config)
            identifier = patch['id']
            original = self.item(identifier)
            allowed = set(original) - {'id', 'name'}
            if set(patch) - allowed - {'id', 'queue_port'}: raise ValueError('Unknown setting.')
            target = next(s for s in proposed['services'] if s['id'] == identifier)
            target.update({k: v for k, v in patch.items() if k in allowed})
            if identifier in ('image', 'voice', 'image-queue', 'voice-queue'):
                family = identifier.split('-')[0]
                for s in proposed['services']:
                    if s['id'].split('-')[0] == family: s['root'] = target['root']
                if 'queue_port' in patch:
                    next(s for s in proposed['services'] if s['id'] == family + '-queue')['port'] = patch['queue_port']
            validate(proposed)
            # Preserve actual endpoints/settings, including user-started processes, until they stop.
            for service_id in IDS:
                settings, status = self.resolve(service_id)
                if status['running']:
                    record = read_json(self.active_file(service_id), {})
                    if record.get('settings') != settings:
                        atomic_json(self.active_file(service_id), {'settings': settings})
            atomic_json(self.config_file, proposed)
            self.config = proposed
        return {'ok': True}

    def start_command(self, item):
        identifier = item['id']
        env = dict(os.environ)
        env['PATH'] = str(Path.home() / '.local/bin') + ':/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        env.update(environment(item.get('environment', '')))
        env['PYTHONUNBUFFERED'] = '1'
        root = path(item['root'])
        if identifier == 'bridge':
            command = [str(path(item['binary'])), '--home', str(root), '--port', str(item['port'])]
            if item['log_file_only']: command.append('--log-file-only')
            return command + ['serve'], env
        command = ['/usr/bin/make', 'queue' if identifier.endswith('queue') else 'serve', 'NONINTERACTIVE=1']
        if identifier.endswith('queue'): command += ['QUEUE_PORT=' + str(item['port'])]
        else:
            command += ['MODEL=' + item['model'], 'PORT=' + str(item['port']), 'QUEUE_PORT=' + str(item['queue_port']), 'NO_LLM=' + str(int(not item['llm']))]
            if identifier == 'image': command += ['NO_LORAS=' + str(int(not item['loras']))]
        return command, env

    def start_bridge(self, item):
        plist = Path.home() / ('Library/LaunchAgents/' + LABEL + '.plist')
        if not plist.is_file(): raise ValueError('The ai-bridge login service is missing. Install ai-bridge first.')
        value = plistlib.loads(plist.read_bytes())
        command, env = self.start_command(item)
        if not Path(command[0]).is_file(): raise ValueError('ai-bridge executable was not found.')
        domain = 'gui/' + str(os.getuid())
        target = domain + '/' + LABEL
        loaded = subprocess.run(['/bin/launchctl', 'print', target], capture_output=True).returncode == 0
        # Track only monitor-managed overrides so deleting an override also takes
        # effect, while preserving the launch agent's pre-existing environment.
        applied_file = self.support / 'bridge-applied-environment.json'
        baseline = dict(value.get('EnvironmentVariables', {}))
        previous = read_json(applied_file, {})
        for key, entry in previous.items():
            if baseline.get(key) == entry['applied']:
                if entry['previous'] is None: baseline.pop(key, None)
                else: baseline[key] = entry['previous']
        overrides = environment(item.get('environment', ''))
        next_environment = {**baseline, **overrides}
        applied = {key: {'previous': baseline.get(key), 'applied': val} for key, val in overrides.items()}
        if value.get('ProgramArguments') != command or value.get('EnvironmentVariables', {}) != next_environment:
            if loaded:
                subprocess.run(['/bin/launchctl', 'bootout', target], capture_output=True, check=True)
                loaded = False
            value['ProgramArguments'] = command
            value['EnvironmentVariables'] = next_environment
            plist.write_bytes(plistlib.dumps(value)); plist.chmod(0o600)
        atomic_json(applied_file, applied)
        args = ['/bin/launchctl', 'kickstart', target] if loaded else ['/bin/launchctl', 'bootstrap', domain, str(plist)]
        result = subprocess.run(args, capture_output=True, text=True, timeout=15)
        if result.returncode: raise ValueError('Could not start the ai-bridge login service: ' + result.stderr.strip())
        return None

    def log_path(self, identifier):
        return self.support / 'logs' / (identifier + '.log')

    def start(self, identifier):
        old, status = self.resolve(identifier)
        if status['running']: return {'ok': True}
        item = self.desired(identifier)
        if self.port_open(item['port']): raise ValueError('Port ' + str(item['port']) + ' is occupied; no process was changed.')
        if identifier in ('image', 'voice'):
            queue, queue_status = self.resolve(identifier + '-queue')
            if queue_status['running'] and (queue['port'] != item['queue_port'] or queue['root'] != item['root']):
                raise ValueError('Stop the queue before starting the generator with the new queue settings.')
        root = path(item['root'])
        if identifier == 'bridge': root.mkdir(parents=True, exist_ok=True, mode=0o700)
        if not root.is_dir(): raise ValueError('Service folder is unavailable: ' + str(root))
        command, env = self.start_command(item)
        log = self.log_path(identifier)
        log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if identifier == 'bridge':
            process = self.start_bridge(item)
            record = {'settings': item}
        else:
            with log.open('ab') as output:
                process = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                           stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            record = {'settings': item, 'launcher_pid': process.pid, 'fingerprint': self.fingerprint(process.pid)}
        record['ready'] = False
        atomic_json(self.active_file(identifier), record)
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            state = self.health(item)
            if state is not None:
                if state.get('status') == 'error': raise ValueError(self.health_problem(state))
                record['ready'] = True
                atomic_json(self.active_file(identifier), record)
                return {'ok': True}
            if process is not None and process.poll() is not None:
                raise ValueError('Startup failed. ' + self.log_tail(log))
            time.sleep(.5)
        raise ValueError('Startup is still in progress. Check the status and logs before retrying.')

    @staticmethod
    def log_tail(log):
        try:
            with log.open('rb') as handle:
                handle.seek(0, os.SEEK_END)
                handle.seek(max(0, handle.tell() - 8192))
                return '\n'.join(handle.read().decode(errors='replace').splitlines()[-6:])[-1400:]
        except OSError: return 'Open the service logs for details.'

    def stop(self, identifier):
        item, status = self.resolve(identifier)
        if not status['running']:
            self.active_file(identifier).unlink(missing_ok=True)
            return {'ok': True}
        state = status['state']
        if identifier == 'bridge':
            if state is None: raise ValueError('ai-bridge is not responding. No forced termination was sent.')
            self.request(item, '/v1/shutdown', 'POST', {})
        else:
            if state and state.get('busy'):
                raise ValueError('This generator is busy. Let the current job finish, then switch it off.')
            pids = status['pids']
            if not pids: raise ValueError('Service is still starting. Wait for it to become ready before stopping.')
            if len(pids) != 1: raise ValueError('Cannot identify a single service process; no termination was sent.')
            pid = pids[0]
            # Recheck command and cwd immediately before signalling to reject a stale/reused PID.
            fingerprint = self.fingerprint(pid)
            if pid not in self.owned_processes(item) or not fingerprint or self.fingerprint(pid) != fingerprint:
                raise ValueError('Service process changed. Refresh and try again.')
            os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if self.health(item) is None and not self.owned_processes(item):
                self.active_file(identifier).unlink(missing_ok=True)
                return {'ok': True}
            time.sleep(.3)
        raise ValueError('Shutdown is still in progress. No forced termination was sent.')

    def action(self, identifier, action):
        if identifier not in IDS: raise ValueError('Unknown service.')
        with self.lock(identifier.split('-')[0]):
            record = {'action': action, 'settings': self.desired(identifier), 'error': None}
            atomic_json(self.result_file(identifier), record)
            try:
                return self.start(identifier) if action == 'start' else self.stop(identifier)
            except Exception as error:
                record['error'] = str(error)[:1400]
                atomic_json(self.result_file(identifier), record)
                raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--support', type=Path, default=DEFAULT_SUPPORT)
    parser.add_argument('action', choices=('status', 'config', 'save', 'start', 'stop'))
    parser.add_argument('identifier', nargs='?', choices=IDS)
    args = parser.parse_args()
    try:
        controller = Controller(args.support)
        if args.action == 'status': result = controller.snapshot()
        elif args.action == 'config': result = {'ok': True, **controller.config}
        elif args.action == 'save': result = controller.save(json.load(sys.stdin))
        else: result = controller.action(args.identifier, args.action)
    except Exception as error:
        result = {'ok': False, 'error': str(error)}
    print(json.dumps(result))
    return 0 if result['ok'] else 1


if __name__ == '__main__': sys.exit(main())
