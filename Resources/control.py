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
import re
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time

IDS = ('bridge', 'image', 'image-queue', 'voice', 'voice-queue')
NAMES = ('ai-bridge', 'Image gen service', 'Image gen queue', 'Voice gen service', 'Voice gen queue')
GENERATOR_SERVICES = {'image': 'imagegen-generator', 'voice': 'voicegen-service'}
MODEL_ENV_KEYS = ('MODEL', 'IMAGE_MODEL', 'MODEL_BACKEND', 'DEFAULT_MODEL')
NORMAL_GENERATOR_STAGES = {'ready', 'idle', 'unloaded', 'starting', 'loading', 'switching',
                           'expanding', 'rendering', 'generating', 'synthesizing', 'processing',
                           'preparing', 'preview', 'previewing', 'unloading', 'saving', 'writing', 'paused', 'waiting', 'blocked'}
BUSY_GENERATOR_STAGES = NORMAL_GENERATOR_STAGES - {'ready', 'idle', 'unloaded', 'paused', 'waiting', 'blocked'}
LABEL = 'local.ai-bridge.api'
DEFAULT_SUPPORT = Path.home() / 'Library/Application Support/DaemonMonitor'


def defaults():
    image = '~/Documents/models/ImageGen-Service'
    voice = '~/Documents/models/VoiceGen-Service'
    return {'services': [
        dict(id='bridge', name=NAMES[0], port=8765, root='~/Library/Application Support/AI Bridge',
             binary='~/Library/Application Support/AI Bridge/bin/ai-bridge', log_file_only=True, environment=''),
        dict(id='image', name=NAMES[1], port=5742, root=image, llm=True, loras=True, environment=''),
        dict(id='image-queue', name=NAMES[2], port=55302, root=image, environment=''),
        dict(id='voice', name=NAMES[3], port=5743, root=voice, llm=True, environment=''),
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
        if key in MODEL_ENV_KEYS:
            raise ValueError('Model selection is managed by the generator UI/API; remove ' + key + ' from environment overrides.')
        if key in ('HOME', 'PATH', 'PORT', 'QUEUE_PORT', 'NO_LLM', 'NO_LORAS', 'NONINTERACTIVE'):
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
    for a, b in ((1, 2), (3, 4)):
        if path(services[a]['root']) != path(services[b]['root']):
            raise ValueError('A generator and its queue must use the same project folder.')
    if not services[0]['binary'].startswith(('/', '~/')): raise ValueError('Executable path must be absolute or start with ~/.')
    return config


class HTTPStatusError(ValueError):
    """A non-200 control/health reply; keeps the status so callers can tell an older server (404) apart."""
    def __init__(self, message, status):
        super().__init__(message)
        self.status = status


class Controller:
    def __init__(self, support=DEFAULT_SUPPORT):
        self.support = Path(support)
        self.config_file = self.support / 'services.json'
        self.config = self.load_config()
        self.health_errors = {}

    def load_config(self):
        config = read_json(self.config_file, defaults())
        # Model selection belongs to each service at runtime. Ignore
        # obsolete monitor overrides even before the user next saves settings.
        for item in config['services']:
            item.pop('model', None)
        return validate(config)

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
                raise HTTPStatusError(message, response.status)
            return json.loads(raw)
        finally: connection.close()

    def matches(self, item, state):
        if not isinstance(state, dict): return False
        identifier, root = item['id'], str(path(item['root']).resolve())
        if identifier == 'bridge':
            return state.get('ok') is True and state.get('capabilities', {}).get('multi_project') is True
        family = identifier.split('-')[0]
        if state.get('project_dir' if family == 'image' else 'project') != root: return False
        # The two projects publish different field names in their v4 health APIs.
        # Match each contract explicitly; never infer identity from a model name.
        version_key = 'version' if family == 'image' else 'api_version'
        if state.get('queue_scope') != 'shared' or not self.protocol_version(state.get(version_key)): return False
        if identifier.endswith('queue'):
            return state.get('service') == family + 'gen-queue' and (family == 'image' or state.get('role') == 'queue-crud')
        # Stable service/protocol identity, never the loaded model ID.
        return (state.get('runtime_model_switching') is True
                and state.get('service') == GENERATOR_SERVICES[family]
                and (state.get('role', 'generator') if family == 'image' else state.get('mode')) == 'generator')

    @staticmethod
    def protocol_version(value):
        return isinstance(value, str) and re.fullmatch(r'\d+(?:\.\d+)*(?:[-+][A-Za-z0-9.-]+)?', value) is not None

    @staticmethod
    def generator_busy(state):
        queue = state.get('queue') or {}
        counts = state.get('queue_counts') or queue.get('counts') or {}
        stages = (state.get('status'), state.get('stage'), queue.get('stage'))
        return bool(state.get('busy') or state.get('active_job') or state.get('loading')
                    or state.get('switching') or state.get('previewing')
                    or queue.get('running') or counts.get('running')
                    or any(stage in BUSY_GENERATOR_STAGES for stage in stages))

    @staticmethod
    def runtime_healthy(state):
        storage = state.get('queue_storage') or {}
        return (state.get('status') in NORMAL_GENERATOR_STAGES
                and not (state.get('queue') or {}).get('error')
                and not state.get('runtime_errors')
                and storage.get('status', 'ready') == 'ready')

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
    def read_process_info(command, timeout, check=False):
        # A process query can briefly stall around sleep/wake or heavy system load.
        # Retry only this read; never turn a failed query into an empty process list.
        for attempt, limit in enumerate((timeout, 8)):
            try:
                return subprocess.run(command, capture_output=True, text=True, timeout=limit, check=check)
            except subprocess.TimeoutExpired:
                if attempt:
                    raise ValueError('macOS took too long to read process status. Refresh to try again.') from None
            except (OSError, subprocess.CalledProcessError):
                raise ValueError('macOS could not read process status. Refresh to try again.') from None

    @staticmethod
    def processes():
        result = Controller.read_process_info(['/bin/ps', '-axo', 'pid=,command='], timeout=4, check=True)
        return [line.strip().split(None, 1) for line in result.stdout.splitlines() if len(line.strip().split(None, 1)) == 2]

    @staticmethod
    def fingerprint(pid):
        result = Controller.read_process_info(['/bin/ps', '-p', str(pid), '-o', 'lstart=,command='], timeout=3)
        return result.stdout.strip()

    @staticmethod
    def cwd_matches(pid, root):
        result = Controller.read_process_info(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'], timeout=4)
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
        error = (state.get('queue') or {}).get('error')
        if error and str(error) not in reasons: reasons.append(str(error))
        storage = state.get('queue_storage') or {}
        if storage.get('status', 'ready') != 'ready':
            reasons.append(str(storage.get('message') or 'Queue storage is unavailable.'))
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
        runtime = bool(state and state.get('runtime_model_switching') is True and item['id'] in GENERATOR_SERVICES)
        active_model = None
        busy = False
        if state is not None:
            if item['id'] == 'bridge': healthy = True
            elif item['id'].endswith('queue'): healthy = state.get('status') == 'ready'
            else: healthy = self.runtime_healthy(state)
            detail = ('Healthy' if healthy else 'Needs attention') + ' · ' + str(state.get('status', 'ready'))
            if not healthy: detail = self.health_problem(state)
            busy = self.generator_busy(state) if item['id'] in GENERATOR_SERVICES else False
            if busy: detail += ' · Busy'
            if runtime:
                active_model = state.get('active_model')
                active_model = active_model if isinstance(active_model, str) else None
                detail += '\nActive: ' + str(active_model or 'None loaded')
                queue = state.get('queue') or {}
                stage = queue.get('stage') or state.get('stage') or state.get('status')
                if stage: detail += '\nStage: ' + str(stage)
                progress = self.job_progress(item, state) if busy else None
                if progress: detail += '\nProgress: ' + progress
                counts = queue.get('counts') or state.get('queue_counts') or queue
                # VoiceGen publishes sparse status totals at the top level: an
                # empty dictionary means zero jobs when queue storage is healthy.
                if isinstance(state.get('queue_counts'), dict) and (state.get('queue_storage') or {}).get('status', 'ready') == 'ready':
                    counts = {'queued': 0, 'running': 0, **counts}
                count_text = [str(counts[key]) + ' ' + key for key in ('waiting', 'queued', 'running', 'blocked')
                              if type(counts.get(key)) is int]
                if queue.get('paused', state.get('queue_paused')) is True: count_text.append('Paused')
                if count_text: detail += '\nQueue: ' + ' · '.join(count_text)
                blocked = queue.get('blocked_reason')
                if blocked: detail += '\nWaiting: ' + str(blocked)
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
                    detail=detail, port=item['port'], state=state, pids=pids,
                    runtime_model_switching=runtime, active_model=active_model, busy=busy)

    def job_progress(self, item, state):
        """Readable progress for the running job; None when idle or the server predates progress reporting."""
        if item['id'] == 'image': progress = state.get('progress')
        else:
            # VoiceGen health names the running job; its estimate lives on the job itself.
            job = state.get('active_job')
            if not (isinstance(job, str) and re.fullmatch(r'[0-9a-f]{32}', job)): return None
            try: progress = self.request(item, '/api/jobs/' + job).get('progress')
            except (OSError, ValueError, AttributeError, http.client.HTTPException): return None
        return self.describe_progress(item['id'], progress)

    @staticmethod
    def describe_progress(family, progress, now=None):
        if not isinstance(progress, dict) or type(progress.get('percent')) is not int: return None
        now = time.time() if now is None else now
        percent, phase = max(0, min(100, progress['percent'])), progress.get('phase')
        if family == 'image':
            parts = [str(percent) + '%']
            image, total = progress.get('image'), progress.get('total_images')
            if type(image) is int and type(total) is int and total > 1: parts.append('image %d of %d' % (image, total))
            if isinstance(phase, str) and phase not in ('sampling', 'done'): parts.append(phase.replace('_', ' '))
            remaining, updated = progress.get('estimated_remaining_seconds'), progress.get('updated')
            # The estimate was made when the generator last saved progress.
            if type(remaining) in (int, float) and type(updated) in (int, float): remaining = max(0, remaining - max(0, now - updated))
        else:
            # Voice progress is a time estimate, so mark it as approximate.
            parts = ['~' + str(percent) + '%']
            if progress.get('overdue') is True: parts.append('taking longer than usual')
            elif phase in ('preparing', 'waiting'): parts.append(phase)
            remaining = None if progress.get('overdue') is True else progress.get('eta_seconds')
        if type(remaining) in (int, float) and remaining >= 0: parts.append(Controller.remaining_text(remaining, now))
        return ' · '.join(parts)

    @staticmethod
    def remaining_text(seconds, now):
        seconds = round(seconds)
        if seconds < 10: return 'a few seconds left'
        if seconds < 60: text = 'about %d sec left' % (5 * round(seconds / 5))
        elif seconds < 3600: text = 'about %d min left' % max(1, round(seconds / 60))
        else: text = 'about %d h %d min left' % divmod(round(seconds / 60), 60)
        return text + ' (done ~' + time.strftime('%-I:%M %p', time.localtime(now + seconds)) + ')'

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
            resolved = dict(zip(IDS, pool.map(lambda identifier: self.resolve(identifier, processes), IDS)))
        services = []
        for identifier in IDS:
            status = resolved[identifier][1]
            row = {k: status[k] for k in ('id', 'name', 'running', 'healthy', 'detail', 'port',
                   'runtime_model_switching', 'active_model', 'busy')}
            if identifier in GENERATOR_SERVICES:
                row['queue_paused'] = self.queue_paused(identifier, status['state'], *resolved[identifier + '-queue'])
            if identifier == 'image':
                row['keep_weights_loaded'], row['settings_note'] = self.keep_weights(resolved['image'], resolved['image-queue'])
            services.append(row)
        return {'ok': True, 'services': services}

    def queue_paused(self, family, state, queue_item, queue_status):
        """The persisted pause flag shared by a generator and its queue, or None when neither reports it."""
        value = None
        if state is not None:
            # ImageGen nests queue state; VoiceGen's top-level flag is only meaningful with readable storage.
            if family == 'image': value = (state.get('queue') or {}).get('paused')
            elif (state.get('queue_storage') or {}).get('status', 'ready') == 'ready': value = state.get('queue_paused')
        if not isinstance(value, bool) and queue_status['state'] is not None:
            if family == 'voice': value = queue_status['state'].get('paused')
            else:
                try: value = self.request(queue_item, '/v1/queue').get('paused')
                except (OSError, ValueError, AttributeError, http.client.HTTPException): value = None
        return value if isinstance(value, bool) else None

    def keep_weights(self, *sources):
        """ImageGen's shared keep_weights_loaded setting, or None with a reason it can't be shown."""
        running = [item for item, status in sources if status['state'] is not None]
        if not running: return None, 'Start the Image Generator or its queue to change this.'
        outdated = False
        for item in running:
            # Generator and queue share the value; an older process may not serve it yet.
            try: value = self.request(item, '/v1/settings').get('keep_weights_loaded')
            except HTTPStatusError as error:
                outdated = outdated or error.status == 404
                continue
            except (OSError, ValueError, AttributeError, http.client.HTTPException): continue
            if isinstance(value, bool): return value, None
        return None, ('Update and restart ImageGen to use this setting.' if outdated
                      else 'Could not read this setting. Refresh and try again.')

    def set_keep_weights(self, value):
        """Change ImageGen's keep_weights_loaded through its existing settings API; it applies from the next image."""
        outdated = False
        for identifier in ('image', 'image-queue'):
            item, status = self.resolve(identifier)
            if status['state'] is None: continue
            try: result = self.request(item, '/v1/settings', 'PATCH', {'keep_weights_loaded': value})
            except HTTPStatusError as error:
                if error.status != 404: raise
                outdated = True
                continue
            if not isinstance(result, dict) or result.get('keep_weights_loaded') is not value:
                raise ValueError('ImageGen did not confirm the change. Refresh and try again.')
            return {'ok': True, 'keep_weights_loaded': value}
        if outdated: raise ValueError('This ImageGen version has no Keep image weights loaded setting. Update ImageGen and restart it.')
        raise ValueError('Start the Image Generator or its queue to change this setting.')

    def set_paused(self, family, paused):
        """Pause or resume through each project's existing API; the active job always finishes."""
        if family not in GENERATOR_SERVICES: raise ValueError('Only Image and Voice Generator queues can be paused.')
        # Prefer the generator, then the standalone queue; both write the same SQLite flag.
        for identifier in (family, family + '-queue'):
            item, status = self.resolve(identifier)
            if status['state'] is None: continue
            if family == 'image': result = self.request(item, '/v1/queue', 'PATCH', {'paused': paused})
            else: result = self.request(item, '/api/queue/' + ('pause' if paused else 'resume'), 'POST', {})
            if not isinstance(result, dict) or result.get('paused') is not paused:
                raise ValueError('The queue did not confirm the change. Refresh and try again.')
            return {'ok': True, 'paused': paused}
        raise ValueError('Start the generator or its queue to pause or resume processing.')

    def save(self, patch):
        return self.save_many([patch])

    def save_many(self, patches):
        with self.lock('configuration'):
            self.config = self.load_config()
            proposed = copy.deepcopy(self.config)
            for patch in patches:
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
        for key in MODEL_ENV_KEYS: env.pop(key, None)
        command = ['/usr/bin/make', 'queue' if identifier.endswith('queue') else 'serve', 'NONINTERACTIVE=1']
        if identifier.endswith('queue'): command += ['QUEUE_PORT=' + str(item['port'])]
        else:
            command += ['PORT=' + str(item['port']), 'QUEUE_PORT=' + str(item['queue_port']), 'NO_LLM=' + str(int(not item['llm']))]
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
            if identifier in GENERATOR_SERVICES:
                if state and self.generator_busy(state):
                    raise ValueError('This generator is busy. Let the current job, model switch, or preview finish, then switch it off.')
                # Recheck work immediately before shutdown; switching models never
                # authorizes interrupting a batch or restarting the generator.
                current = self.health(item)
                if current and self.generator_busy(current):
                    raise ValueError('This generator is busy. Let the current job, model switch, or preview finish, then switch it off.')
                if current is None:
                    raise ValueError('Could not confirm that the generator is idle. No termination was sent; refresh and try again.')
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
    parser.add_argument('action', choices=('status', 'config', 'save', 'start', 'stop', 'pause', 'resume', 'keep-weights', 'sample', 'history'))
    parser.add_argument('identifier', nargs='?', choices=IDS)
    parser.add_argument('--range', dest='range_name', choices=('5m', '30m', '1h', '6h', '24h', '3d', '7d'), default='5m')
    parser.add_argument('--interval', type=int, choices=(15, 60), default=60)
    parser.add_argument('--value', choices=('on', 'off'))
    args = parser.parse_args()
    try:
        controller = Controller(args.support)
        if args.action == 'status': result = controller.snapshot()
        elif args.action == 'config': result = {'ok': True, **controller.config}
        elif args.action == 'save': result = controller.save(json.load(sys.stdin))
        elif args.action in ('sample', 'history'):
            from metrics import MetricsStore
            store = MetricsStore(controller.support)
            if args.action == 'sample':
                with controller.lock('metrics'):
                    result = store.sample(controller, interval=args.interval)
            else:
                if args.identifier is None: raise ValueError('Choose a service for history.')
                result = store.history(args.identifier, args.range_name)
        elif args.action == 'keep-weights':
            if args.identifier != 'image' or args.value is None: raise ValueError('Use keep-weights image --value on|off.')
            result = controller.set_keep_weights(args.value == 'on')
        elif args.action in ('pause', 'resume'):
            if args.identifier not in GENERATOR_SERVICES: raise ValueError('Choose image or voice to pause or resume.')
            result = controller.set_paused(args.identifier, args.action == 'pause')
        else: result = controller.action(args.identifier, args.action)
    except Exception as error:
        result = {'ok': False, 'error': str(error)}
    print(json.dumps(result))
    return 0 if result['ok'] else 1


if __name__ == '__main__': sys.exit(main())
