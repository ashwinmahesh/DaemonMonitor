import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('control', Path(__file__).parents[1] / 'Resources/control.py')
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.controller = control.Controller(Path(self.temp.name))

    def test_model_and_queue_startup_arguments(self):
        for identifier, model in [('image', 'z-image-turbo'), ('voice', 'higgs')]:
            command, env = self.controller.start_command(self.controller.desired(identifier))
            self.assertIn('MODEL=' + model, command)
            self.assertIn('NO_LLM=0', command)
            self.assertIn('QUEUE_PORT=' + str(self.controller.item(identifier + '-queue')['port']), command)
            self.assertEqual(command[:2], ['/usr/bin/make', 'serve'])
        command, _ = self.controller.start_command(self.controller.desired('image-queue'))
        self.assertEqual(command, ['/usr/bin/make', 'queue', 'NONINTERACTIVE=1', 'QUEUE_PORT=55302'])
        self.assertNotIn('MODEL=higgs', self.controller.start_command(self.controller.desired('voice-queue'))[0])

    def test_advanced_flags_are_literal_arguments(self):
        item = self.controller.desired('image')
        item.update(llm=False, loras=False, model='chroma1-flash', environment='DATA_DIR=/some path/$(touch hacked)\nVENV=/a venv')
        command, env = self.controller.start_command(item)
        self.assertIn('NO_LLM=1', command)
        self.assertIn('NO_LORAS=1', command)
        self.assertIn('MODEL=chroma1-flash', command)
        self.assertEqual(env['DATA_DIR'], '/some path/$(touch hacked)')
        self.assertEqual(env['VENV'], '/a venv')

    def test_ports_and_models_are_validated(self):
        for mutate in [lambda c: c['services'][0].update(port=0),
                       lambda c: c['services'][1].update(port=8765),
                       lambda c: c['services'][1].update(model='invalid'),
                       lambda c: c['services'][1].update(llm='false')]:
            config = control.defaults(); mutate(config)
            with self.assertRaises(ValueError): control.validate(config)

    def test_environment_does_not_override_named_controls(self):
        for value in ('HOME=/tmp', 'MODEL=higgs', 'PORT=1234', 'bad key=x', 'missing-equals'):
            with self.assertRaises(ValueError): control.environment(value)

    def test_health_matches_checkout_and_service_identity(self):
        image = self.controller.desired('image-queue')
        state = {'service': 'imagegen-queue', 'project_dir': str(control.path(image['root']))}
        self.assertTrue(self.controller.matches(image, state))
        self.assertFalse(self.controller.matches(image, {**state, 'project_dir': '/other/project'}))
        self.assertFalse(self.controller.matches(image, {**state, 'service': 'voicegen-queue'}))

    def test_voice_unloaded_is_healthy_but_runtime_errors_are_red(self):
        voice = self.controller.desired('voice')
        healthy = dict(status='unloaded', service='higgs', downloaded=True, runtime_errors=[], asset_errors=[], model_loaded=False)
        with patch.object(self.controller, 'health', return_value=healthy), patch.object(self.controller, 'owned_processes', return_value=[]):
            self.assertTrue(self.controller.inspect(voice)['healthy'])
        with patch.object(self.controller, 'health', return_value={**healthy, 'runtime_errors': ['missing runtime']}), patch.object(self.controller, 'owned_processes', return_value=[]):
            status = self.controller.inspect(voice)
            self.assertTrue(status['running'])
            self.assertFalse(status['healthy'])

    def test_image_worker_error_is_red(self):
        image = self.controller.desired('image')
        with patch.object(self.controller, 'health', return_value={'status': 'ready', 'queue': {'error': 'worker stopped'}}), patch.object(self.controller, 'owned_processes', return_value=[]):
            self.assertFalse(self.controller.inspect(image)['healthy'])

    def test_red_reason_includes_asset_runtime_and_worker_failures(self):
        voice = self.controller.desired('voice')
        state = dict(status='error', downloaded=False, asset_errors=['SSD is not mounted'],
                     runtime_errors=['Native runtime missing'], last_error='Load failed')
        with patch.object(self.controller, 'health', return_value=state), patch.object(self.controller, 'owned_processes', return_value=[]):
            detail = self.controller.inspect(voice)['detail']
        for reason in ('SSD is not mounted', 'Native runtime missing', 'Load failed'):
            self.assertIn(reason, detail)
        self.assertEqual(self.controller.health_problem({'status': 'error', 'queue': {'error': 'Worker lease lost'}}), 'Worker lease lost')

    def test_red_reason_distinguishes_not_started_from_startup_failure(self):
        item = self.controller.desired('image')
        with patch.object(self.controller, 'health', return_value=None), patch.object(self.controller, 'owned_processes', return_value=[]), patch.object(self.controller, 'port_open', return_value=False):
            self.assertEqual(self.controller.inspect(item)['detail'], 'Not started.')
            with patch.object(self.controller, 'start', side_effect=ValueError('Model assets missing: transformer')):
                with self.assertRaises(ValueError): self.controller.action('image', 'start')
            # A new controller instance must retain the last failure.
            restarted = control.Controller(self.temp.name)
            with patch.object(restarted, 'health', return_value=None), patch.object(restarted, 'owned_processes', return_value=[]), patch.object(restarted, 'port_open', return_value=False):
                self.assertIn('Model assets missing: transformer', restarted.inspect(item)['detail'])
            self.controller.action('image', 'stop')
            self.assertEqual(self.controller.inspect(item)['detail'], 'Not started.')

    def test_red_reason_identifies_running_but_unresponsive_service(self):
        with patch.object(self.controller, 'health', return_value=None), patch.object(self.controller, 'owned_processes', return_value=[123]):
            status = self.controller.inspect(self.controller.desired('voice'))
        self.assertTrue(status['running'])
        self.assertIn('health endpoint is not responding', status['detail'])

    def test_crash_reason_uses_recent_log_and_does_not_claim_stopped(self):
        item = self.controller.desired('image')
        record = dict(settings=item, launcher_pid=123, fingerprint='original', ready=True)
        control.atomic_json(self.controller.active_file('image'), record)
        log = self.controller.log_path('image'); log.parent.mkdir(); log.write_text('Traceback:\nRuntimeError: accelerator unavailable\n')
        with patch.object(self.controller, 'health', return_value=None), patch.object(self.controller, 'owned_processes', return_value=[]), patch.object(self.controller, 'fingerprint', return_value=''), patch.object(self.controller, 'port_open', return_value=False):
            _, status = self.controller.resolve('image')
        self.assertEqual(status['detail'], 'Service exited: RuntimeError: accelerator unavailable')
        self.assertFalse(status['running'])

    def test_unrelated_listener_cannot_be_stopped_or_replaced(self):
        item = self.controller.desired('image')
        offline = dict(running=False, state=None, pids=[])
        with patch.object(self.controller, 'resolve', return_value=(item, offline)), patch.object(self.controller, 'port_open', return_value=True), patch.object(control.os, 'kill') as kill, patch.object(control.subprocess, 'Popen') as spawn:
            self.assertTrue(self.controller.stop('image')['ok'])
            with self.assertRaisesRegex(ValueError, 'occupied'): self.controller.start('image')
            kill.assert_not_called(); spawn.assert_not_called()

    def test_busy_generator_is_not_interrupted(self):
        item = self.controller.desired('voice')
        status = dict(running=True, state={'busy': True}, pids=[123])
        with patch.object(self.controller, 'resolve', return_value=(item, status)), patch.object(control.os, 'kill') as kill:
            with self.assertRaisesRegex(ValueError, 'busy'): self.controller.stop('voice')
            kill.assert_not_called()

    def test_reused_pid_is_not_signalled(self):
        item = self.controller.desired('image')
        status = dict(running=True, state={}, pids=[123])
        with patch.object(self.controller, 'resolve', return_value=(item, status)), patch.object(self.controller, 'fingerprint', return_value='old'), patch.object(self.controller, 'owned_processes', return_value=[]), patch.object(control.os, 'kill') as kill:
            with self.assertRaisesRegex(ValueError, 'changed'): self.controller.stop('image')
            kill.assert_not_called()

    def test_save_retains_running_endpoint_and_syncs_queue_port(self):
        active = self.controller.desired('voice')
        def resolve(identifier, processes=None):
            return (copy.deepcopy(active) if identifier == 'voice' else self.controller.desired(identifier), {'running': identifier == 'voice'})
        with patch.object(self.controller, 'resolve', side_effect=resolve):
            self.controller.save({'id': 'voice', 'port': 6743, 'queue_port': 65205})
        self.assertEqual(self.controller.desired('voice')['port'], 6743)
        self.assertEqual(self.controller.desired('voice')['queue_port'], 65205)
        record = control.read_json(self.controller.active_file('voice'))
        self.assertEqual(record['settings']['port'], 5743)
        with patch.object(self.controller, 'inspect', return_value={'running': True}):
            self.assertEqual(self.controller.resolve('voice')[0]['port'], 5743)

    def test_family_lock_prevents_overlapping_generator_queue_actions(self):
        with self.controller.lock('image'):
            with self.assertRaisesRegex(ValueError, 'in progress'):
                self.controller.action('image-queue', 'start')

    def test_development_process_on_another_port_is_not_owned(self):
        item = self.controller.desired('voice-queue')
        command = '/a/python3.14 -u ' + str(control.path(item['root']) / 'queue_server.py') + ' --port 58502'
        with patch.object(self.controller, 'cwd_matches', return_value=True):
            self.assertEqual(self.controller.owned_processes(item, [('123', command)]), [])
            command = command.replace('58502', '55205')
            self.assertEqual(self.controller.owned_processes(item, [('123', command)]), [123])

    def test_old_launcher_pid_does_not_make_service_running(self):
        item = self.controller.desired('image')
        with patch.object(self.controller, 'health', return_value=None), patch.object(self.controller, 'owned_processes', return_value=[]), patch.object(self.controller, 'fingerprint', return_value='reused PID'), patch.object(self.controller, 'port_open', return_value=False):
            status = self.controller.inspect(item, record={'launcher_pid': 123, 'fingerprint': 'original process'})
            self.assertFalse(status['running'])

    def test_bridge_stop_uses_authenticated_shutdown_without_signals(self):
        item = self.controller.desired('bridge')
        status = dict(running=True, state={'ok': True}, pids=[123])
        with patch.object(self.controller, 'resolve', return_value=(item, status)), patch.object(self.controller, 'request', return_value={'ok': True}) as request, patch.object(self.controller, 'health', return_value=None), patch.object(self.controller, 'owned_processes', return_value=[]), patch.object(control.os, 'kill') as kill:
            self.assertTrue(self.controller.stop('bridge')['ok'])
            request.assert_called_once_with(item, '/v1/shutdown', 'POST', {})
            kill.assert_not_called()

    def test_bridge_startup_settings_and_removing_environment_overrides(self):
        home = Path(self.temp.name) / 'fake-home'
        agent = home / 'Library/LaunchAgents/local.ai-bridge.api.plist'
        agent.parent.mkdir(parents=True)
        binary = home / 'bridge-binary'; binary.touch()
        original = {'Label': control.LABEL, 'ProgramArguments': [str(binary), 'serve'],
                    'EnvironmentVariables': {'PATH': '/original/path', 'RESTORE_ME': 'original'}, 'RunAtLoad': True}
        agent.write_bytes(control.plistlib.dumps(original))
        item = self.controller.desired('bridge')
        item.update(binary=str(binary), root=str(home), port=45678,
                    environment='RESTORE_ME=temporary\nEXTRA=value', log_file_only=False)
        def run(args, **kwargs):
            return control.subprocess.CompletedProcess(args, 1 if 'print' in args else 0, stdout='', stderr='')
        with patch.object(control.Path, 'home', return_value=home), patch.object(control.subprocess, 'run', side_effect=run) as launch:
            self.controller.start_bridge(item)
            changed = control.plistlib.loads(agent.read_bytes())
            self.assertEqual(changed['ProgramArguments'], [str(binary), '--home', str(home), '--port', '45678', 'serve'])
            self.assertEqual(changed['EnvironmentVariables']['RESTORE_ME'], 'temporary')
            self.assertEqual(changed['EnvironmentVariables']['EXTRA'], 'value')
            item['environment'] = ''
            self.controller.start_bridge(item)
        restored = control.plistlib.loads(agent.read_bytes())
        self.assertEqual(restored['EnvironmentVariables'], original['EnvironmentVariables'])
        self.assertTrue(restored['RunAtLoad'])

    def test_failed_health_request_keeps_specific_failure_for_hover(self):
        item = self.controller.desired('voice')
        with patch.object(self.controller, 'request', side_effect=ValueError('HTTP 503: queue storage unavailable')), patch.object(self.controller, 'owned_processes', return_value=[123]):
            detail = self.controller.inspect(item)['detail']
        self.assertIn('HTTP 503: queue storage unavailable', detail)

    def test_http_authentication_stays_local_and_no_proxy_is_used(self):
        token = 'test-secret-token'
        (Path(self.temp.name) / 'token').write_text(token)
        received = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                received.append(self.headers.get('Authorization'))
                data = json.dumps({'ok': True, 'capabilities': {'multi_project': True}}).encode()
                self.send_response(200); self.end_headers(); self.wfile.write(data)
            def log_message(self, *_): pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        item = self.controller.desired('bridge'); item.update(root=self.temp.name, port=server.server_port)
        with patch.dict(control.os.environ, {'http_proxy': 'http://127.0.0.1:1'}):
            self.assertTrue(self.controller.health(item)['ok'])
        self.assertEqual(received, ['Bearer ' + token])


if __name__ == '__main__': unittest.main()
