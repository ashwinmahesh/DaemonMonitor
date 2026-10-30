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

    def test_generator_and_queue_startup_arguments(self):
        self.assertEqual(self.controller.desired('image')['port'], 5742)
        self.assertEqual(self.controller.desired('voice')['port'], 5743)
        for identifier in ('image', 'voice'):
            item = self.controller.desired(identifier)
            command, env = self.controller.start_command(item)
            self.assertFalse(any(argument.startswith('MODEL=') for argument in command))
            self.assertIn('NO_LLM=0', command)
            self.assertIn('PORT=' + str(item['port']), command)
            self.assertIn('QUEUE_PORT=' + str(self.controller.item(identifier + '-queue')['port']), command)
            self.assertEqual(command[:2], ['/usr/bin/make', 'serve'])
        command, _ = self.controller.start_command(self.controller.desired('image-queue'))
        self.assertEqual(command, ['/usr/bin/make', 'queue', 'NONINTERACTIVE=1', 'QUEUE_PORT=55302'])
        self.assertNotIn('MODEL=higgs', self.controller.start_command(self.controller.desired('voice-queue'))[0])

    def test_image_default_change_preserves_saved_port_overrides(self):
        for port in (5732, 6732):
            saved = control.defaults()
            saved['services'][1]['port'] = port
            control.atomic_json(self.controller.config_file, saved)
            before = self.controller.config_file.read_bytes()
            reloaded = control.Controller(self.temp.name)
            image = reloaded.desired('image')
            self.assertEqual(image['port'], port)
            self.assertEqual(image['queue_port'], 55302)
            self.assertIn('PORT=' + str(port), reloaded.start_command(image)[0])
            self.assertEqual(self.controller.config_file.read_bytes(), before)

    def test_image_default_change_retains_a_running_endpoint(self):
        active = self.controller.desired('image')
        active['port'] = 5732
        control.atomic_json(self.controller.active_file('image'), {'settings': active})
        with patch.object(self.controller, 'inspect', return_value={'running':True}):
            self.assertEqual(self.controller.resolve('image')[0]['port'], 5732)
        with patch.object(self.controller, 'inspect', return_value={'running':False}):
            self.assertEqual(self.controller.resolve('image')[0]['port'], 5742)

    def test_process_list_retries_a_transient_timeout(self):
        command = ['/bin/ps', '-axo', 'pid=,command=']
        result = control.subprocess.CompletedProcess(command, 0, stdout='123 /usr/bin/python server.py\n')
        with patch.object(control.subprocess, 'run', side_effect=[control.subprocess.TimeoutExpired(command, 4), result]) as run:
            self.assertEqual(self.controller.processes(), [['123', '/usr/bin/python server.py']])
        self.assertEqual([call.kwargs['timeout'] for call in run.call_args_list], [4, 8])

    def test_process_list_timeout_is_bounded_and_never_reports_stopped(self):
        command = ['/bin/ps', '-axo', 'pid=,command=']
        with patch.object(control.subprocess, 'run', side_effect=control.subprocess.TimeoutExpired(command, 4)) as run:
            with self.assertRaisesRegex(ValueError, 'macOS took too long to read process status'):
                self.controller.snapshot()
        self.assertEqual(run.call_count, 2)

    def test_failed_process_query_is_not_an_empty_list(self):
        with patch.object(control.subprocess, 'run', side_effect=control.subprocess.CalledProcessError(1, ['/bin/ps'])):
            with self.assertRaisesRegex(ValueError, 'macOS could not read process status'):
                self.controller.processes()

    def test_advanced_flags_are_literal_arguments(self):
        item = self.controller.desired('image')
        item.update(llm=False, loras=False, environment='DATA_DIR=/some path/$(touch hacked)\nVENV=/a venv')
        command, env = self.controller.start_command(item)
        self.assertIn('NO_LLM=1', command)
        self.assertIn('NO_LORAS=1', command)
        self.assertFalse(any(argument.startswith('MODEL=') for argument in command))
        self.assertEqual(env['DATA_DIR'], '/some path/$(touch hacked)')
        self.assertEqual(env['VENV'], '/a venv')

    def test_ports_and_flags_are_validated(self):
        for mutate in [lambda c: c['services'][0].update(port=0),
                       lambda c: c['services'][1].update(port=8765),
                       lambda c: c['services'][1].update(llm='false')]:
            config = control.defaults(); mutate(config)
            with self.assertRaises(ValueError): control.validate(config)

    def test_environment_does_not_override_named_controls(self):
        for value in ('HOME=/tmp', 'MODEL=higgs', 'PORT=1234', 'bad key=x', 'missing-equals'):
            with self.assertRaises(ValueError): control.environment(value)

    def test_health_matches_checkout_and_service_identity(self):
        image = self.controller.desired('image-queue')
        state = {'service': 'imagegen-queue', 'project_dir': str(control.path(image['root'])), 'version':'4.0.0', 'queue_scope':'shared'}
        self.assertTrue(self.controller.matches(image, state))
        self.assertFalse(self.controller.matches(image, {**state, 'project_dir': '/other/project'}))
        self.assertFalse(self.controller.matches(image, {**state, 'service': 'voicegen-queue'}))

    def runtime_state(self, identifier='image', **updates):
        item = self.controller.desired(identifier)
        identity = ({'service':'imagegen-generator', 'role':'generator', 'version':'4.0.0'}
                    if identifier == 'image' else {'service':'voicegen-service', 'mode':'generator', 'api_version':'4.0.0'})
        state = {**identity,
                 'runtime_model_switching': True, 'queue_scope':'shared', 'status': 'ready', 'busy': False,
                 'active_model': None, 'queue': {'stage': 'idle', 'running': 0, 'waiting': 2},
                 'queue_storage': {'status': 'ready'},
                 'project_dir' if identifier == 'image' else 'project': str(control.path(item['root']).resolve())}
        return {**state, **updates}

    def test_runtime_identity_is_independent_of_the_active_model(self):
        for identifier in ('image', 'voice'):
            item = self.controller.desired(identifier)
            for active in (None, 'some-future-ready-model', 'chroma1-flash'):
                state = self.runtime_state(identifier, active_model=active)
                self.assertTrue(self.controller.matches(item, state))
                with patch.object(self.controller, 'request', return_value=state), patch.object(self.controller, 'owned_processes', return_value=[123]):
                    status = self.controller.inspect(item)
                self.assertTrue(status['running']); self.assertTrue(status['healthy'])
                self.assertEqual(status['active_model'], active)
                self.assertNotIn('Default:', status['detail'])
                self.assertIn('Active: ' + (active or 'None loaded'), status['detail'])

    def test_runtime_identity_requires_project_service_mode_and_version(self):
        for identifier in ('image', 'voice'):
            item = self.controller.desired(identifier)
            state = self.runtime_state(identifier)
            key = 'project_dir' if identifier == 'image' else 'project'
            version = 'version' if identifier == 'image' else 'api_version'
            mode = 'role' if identifier == 'image' else 'mode'
            for patch_value in ({key:'/other/project'}, {'service':'unrelated'}, {'service':identifier+'gen-queue'},
                                {'runtime_model_switching':False}, {'runtime_model_switching':'true'},
                                {mode:'queue-crud'}, {version:None}, {version:'not-a-version'}, {'queue_scope':'model'}):
                self.assertFalse(self.controller.matches(item, {**state, **patch_value}), patch_value)

    def test_voice_tooltip_uses_published_stage_and_sparse_queue_counts(self):
        item = self.controller.desired('voice')
        for stage, counts, active, busy, paused, expected in (
                ('ready', {}, None, False, False, 'Queue: 0 queued · 0 running'),
                ('loading', {'queued': 3, 'running': 1}, 'higgs', True, False, 'Queue: 3 queued · 1 running'),
                ('ready', {'queued': 2, 'done': 8}, 'voxcpm2', False, True, 'Queue: 2 queued · 0 running · Paused')):
            state = self.runtime_state('voice', status=stage, active_model=active, busy=busy,
                queue_counts=counts, queue_paused=paused)
            state.pop('queue')  # VoiceGen /health has no nested queue or stage.
            with patch.object(self.controller, 'request', return_value=state), patch.object(self.controller, 'owned_processes', return_value=[123]):
                status = self.controller.inspect(item)
            self.assertTrue(status['healthy'])
            self.assertEqual(status['port'], 5743)
            self.assertIn('Active: ' + (active or 'None loaded'), status['detail'])
            self.assertIn('Stage: ' + stage, status['detail'])
            self.assertIn(expected, status['detail'])
            self.assertEqual(' · Busy' in status['detail'], busy)

    def test_voice_tooltip_does_not_invent_queue_counts_when_storage_fails(self):
        item = self.controller.desired('voice')
        state = self.runtime_state('voice', queue_counts={},
            queue_storage={'status':'unavailable','message':'SQLite is locked'})
        state.pop('queue')
        with patch.object(self.controller, 'request', return_value=state), patch.object(self.controller, 'owned_processes', return_value=[123]):
            status = self.controller.inspect(item)
        self.assertFalse(status['healthy'])
        self.assertIn('SQLite is locked', status['detail'])
        self.assertNotIn('Queue:', status['detail'])

    def test_voice_queue_uses_its_published_api_version_contract(self):
        item = self.controller.desired('voice-queue')
        state = {'service':'voicegen-queue', 'role':'queue-crud', 'api_version':'4.0.0',
                 'queue_scope':'shared', 'project':str(control.path(item['root']).resolve()),
                 'queue_database':str(control.path(item['root'])/'state/queue.sqlite3'),
                 'status':'ready', 'default_model':'higgs', 'paused':False}
        with patch.object(self.controller, 'request', return_value=state), patch.object(self.controller, 'owned_processes', return_value=[]):
            status = self.controller.inspect(item)
        self.assertTrue(status['running']); self.assertTrue(status['healthy'])
        for update in ({'api_version':None}, {'api_version':'invalid'}, {'queue_scope':'model'},
                       {'project':'/other/project'}, {'service':'imagegen-queue'}, {'role':'generator'}):
            self.assertFalse(self.controller.matches(item, {**state, **update}), update)

    def test_voice_generator_does_not_accept_invented_image_style_identity(self):
        item = self.controller.desired('voice')
        state = self.runtime_state('voice')
        for update in ({'service':'voicegen-generator'}, {'mode':None}, {'mode':'queue-crud'},
                       {'api_version':None, 'version':'4.0.0'}):
            self.assertFalse(self.controller.matches(item, {**state, **update}), update)

    def test_model_bound_health_is_rejected(self):
        image = self.controller.desired('image')
        voice = self.controller.desired('voice')
        for model in ('z-image-turbo', 'chroma1-hd', 'flux2-klein-4b'):
            self.assertFalse(self.controller.matches(image, {'project_dir':str(control.path(image['root'])), 'model':model}))
        for model in ('higgs', 'voxcpm2'):
            self.assertFalse(self.controller.matches(voice, {'project':str(control.path(voice['root'])), 'service':model}))

    def test_obsolete_monitor_model_values_are_not_forwarded(self):
        obsolete = control.defaults()
        for item in obsolete['services']:
            if item['id'] in ('image','voice'): item['model']='obsolete-model'
        control.atomic_json(self.controller.config_file, obsolete)
        controller = control.Controller(self.temp.name)
        for identifier in ('image','voice'):
            self.assertNotIn('model', controller.desired(identifier))
            command, env = controller.start_command(controller.desired(identifier))
            self.assertFalse(any(argument.startswith('MODEL=') for argument in command))
            self.assertIn('NO_LLM=0', command)
        with self.assertRaisesRegex(ValueError, 'Unknown setting'):
            controller.save({'id':'image','model':'z-image-turbo'})
        with patch.object(controller, 'resolve', side_effect=lambda identifier: (controller.desired(identifier), {'running':False})):
            controller.save({'id':'image','port':5742})
        self.assertTrue(all('model' not in item for item in control.read_json(controller.config_file)['services']))

    def test_inherited_model_environment_is_not_forwarded(self):
        inherited = dict.fromkeys(control.MODEL_ENV_KEYS, 'unwanted-model')
        with patch.dict(control.os.environ, inherited):
            for identifier in ('image','voice','image-queue','voice-queue'):
                command, env = self.controller.start_command(self.controller.desired(identifier))
                self.assertTrue(all(key not in env for key in inherited))
        for key in inherited:
            with self.assertRaisesRegex(ValueError, 'managed by the generator'):
                control.environment(key+'=unwanted-model')
    def test_runtime_loading_switching_and_blocked_jobs_are_normal(self):
        for identifier in ('image', 'voice'):
            item = self.controller.desired(identifier)
            for stage in ('ready', 'unloaded', 'loading', 'switching', 'expanding', 'rendering', 'previewing', 'waiting', 'blocked'):
                state = self.runtime_state(identifier, status=stage, last_error='A previous job failed',
                    queue={'stage':stage, 'waiting':3, 'blocked':1, 'blocked_reason':'Model assets are unavailable'},
                    queue_api={'status':'unavailable'}, queue_service={'status':'unavailable'})
                with patch.object(self.controller, 'health', return_value=state), patch.object(self.controller, 'owned_processes', return_value=[123]):
                    status = self.controller.inspect(item)
                self.assertTrue(status['healthy'], stage)
                self.assertIn('3 waiting', status['detail'])
                self.assertIn('1 blocked', status['detail'])
                self.assertIn('Model assets are unavailable', status['detail'])

    def test_runtime_storage_and_worker_failures_remain_red(self):
        item = self.controller.desired('image')
        for updates in ({'status':'error'}, {'queue':{'error':'Consumer stopped'}},
                        {'queue_storage':{'status':'unavailable','message':'SQLite is locked'}}):
            with patch.object(self.controller, 'health', return_value=self.runtime_state(**updates)), patch.object(self.controller, 'owned_processes', return_value=[123]):
                status = self.controller.inspect(item)
            self.assertTrue(status['running']); self.assertFalse(status['healthy'])
        self.assertIn('SQLite is locked', status['detail'])

    def test_start_existing_runtime_generator_never_switches_or_restarts_it(self):
        item = self.controller.desired('image')
        state = self.runtime_state(active_model='chroma1-hd', busy=True)
        with patch.object(self.controller, 'resolve', return_value=(item, {'running':True,'state':state})), \
             patch.object(self.controller, 'start_command') as command, patch.object(control.subprocess, 'Popen') as spawn, \
             patch.object(control.os, 'kill') as kill:
            self.assertTrue(self.controller.start('image')['ok'])
        command.assert_not_called(); spawn.assert_not_called(); kill.assert_not_called()

    def test_runtime_busy_loading_preview_and_queue_work_refuse_stop(self):
        item = self.controller.desired('image')
        updates = ({'busy':True}, {'status':'loading'}, {'queue':{'stage':'expanding'}},
                   {'previewing':True}, {'active_job':'job-123'}, {'queue_counts':{'running':1}})
        for update in updates:
            state = self.runtime_state(**update)
            with patch.object(self.controller, 'resolve', return_value=(item, {'running':True,'state':state,'pids':[123]})), patch.object(control.os, 'kill') as kill:
                with self.assertRaisesRegex(ValueError, 'busy'): self.controller.stop('image')
            kill.assert_not_called()

    def test_runtime_stop_rechecks_busy_and_refuses_unknown_state(self):
        item = self.controller.desired('voice')
        state = self.runtime_state('voice')
        for current in (self.runtime_state('voice', busy=True), None):
            with patch.object(self.controller, 'resolve', return_value=(item, {'running':True,'state':state,'pids':[123]})), \
                 patch.object(self.controller, 'health', return_value=current), patch.object(control.os, 'kill') as kill:
                with self.assertRaises(ValueError): self.controller.stop('voice')
            kill.assert_not_called()

    def test_voice_unloaded_is_healthy_but_runtime_errors_are_red(self):
        voice = self.controller.desired('voice')
        healthy = self.runtime_state('voice', status='unloaded', downloaded=True, runtime_errors=[], asset_errors=[], model_loaded=False)
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
        with patch.object(self.controller, 'resolve', return_value=(item, status)), patch.object(self.controller, 'health', return_value={'status':'ready'}), patch.object(self.controller, 'fingerprint', return_value='old'), patch.object(self.controller, 'owned_processes', return_value=[]), patch.object(control.os, 'kill') as kill:
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


    def fake_service(self, health, paused=False):
        """A local HTTP fixture recording control requests; it shares one pause flag like the real queue database."""
        service = {'health': health, 'paused': paused, 'requests': []}
        class Handler(BaseHTTPRequestHandler):
            def reply(self, value):
                data = json.dumps(value).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(data)
            def do_GET(self):
                if self.path == '/health': self.reply(service['health']())
                elif self.path == '/v1/queue': self.reply({'queued': 0, 'running': 0, 'paused': service['paused']})
                else: self.send_error(404)
            def control(self):
                length = int(self.headers.get('Content-Length') or 0)
                body = json.loads(self.rfile.read(length) or b'null')
                service['requests'].append((self.command, self.path, body))
                if self.command == 'PATCH' and self.path == '/v1/queue': service['paused'] = body['paused']
                elif self.command == 'POST' and self.path in ('/api/queue/pause', '/api/queue/resume'): service['paused'] = self.path.endswith('pause')
                else: return self.send_error(404)
                self.reply({'paused': service['paused']})
            do_PATCH = do_POST = control
            def log_message(self, *_): pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        service['port'] = server.server_port
        return service

    def queue_health(self, family):
        root = str(control.path(self.controller.item(family + '-queue')['root']).resolve())
        if family == 'image':
            return {'status': 'ready', 'service': 'imagegen-queue', 'project_dir': root, 'version': '4.0.0', 'queue_scope': 'shared'}
        return {'status': 'ready', 'service': 'voicegen-queue', 'role': 'queue-crud', 'project': root,
                'api_version': '4.0.0', 'queue_scope': 'shared'}

    def test_snapshot_reports_each_projects_shared_pause_flag(self):
        image = self.fake_service(lambda: self.runtime_state('image', queue={'stage': 'idle', 'paused': True}))
        voice = self.fake_service(lambda: self.runtime_state('voice', queue_paused=False))
        image_queue = self.fake_service(lambda: self.queue_health('image'))
        voice_queue = self.fake_service(lambda: {**self.queue_health('voice'), 'paused': True})
        bridge = self.fake_service(lambda: {})  # Keep the snapshot away from a real local bridge.
        self.controller.item('bridge')['root'] = self.temp.name
        for identifier, service in (('bridge', bridge), ('image', image), ('voice', voice), ('image-queue', image_queue), ('voice-queue', voice_queue)):
            self.controller.item(identifier)['port'] = service['port']
        with patch.object(self.controller, 'processes', return_value=[]), patch.object(self.controller, 'owned_processes', return_value=[]):
            rows = {row['id']: row for row in self.controller.snapshot()['services']}
        self.assertIs(rows['image']['queue_paused'], True)
        self.assertIs(rows['voice']['queue_paused'], False)  # The generator wins over the queue's reading.
        self.assertNotIn('queue_paused', rows['image-queue'])
        self.assertNotIn('queue_paused', rows['bridge'])
        self.assertEqual(image['requests'] + voice['requests'] + image_queue['requests'] + voice_queue['requests'], [])

    def test_pause_flag_falls_back_to_the_queue_and_is_unknown_without_either(self):
        image_queue = self.fake_service(lambda: self.queue_health('image'), paused=True)
        voice_queue = self.fake_service(lambda: {**self.queue_health('voice'), 'paused': False})
        for family, queue in (('image', image_queue), ('voice', voice_queue)):
            item, status = self.controller.desired(family + '-queue'), None
            item['port'] = queue['port']
            with patch.object(self.controller, 'owned_processes', return_value=[]):
                status = self.controller.inspect(item)
            self.assertIs(self.controller.queue_paused(family, None, item, status), family == 'image')
            # A VoiceGen storage failure makes its generator flag unreliable, so the queue's reading is used.
            failed = self.runtime_state('voice', queue_paused=False, queue_storage={'status': 'unavailable'})
            self.assertIs(self.controller.queue_paused(family, failed if family == 'voice' else None, item, status), family == 'image')
        stopped = {'state': None}
        self.assertIsNone(self.controller.queue_paused('image', None, self.controller.desired('image-queue'), stopped))
        storage_down = self.runtime_state('voice', queue_paused=False, queue_storage={'status': 'unavailable'})
        self.assertIsNone(self.controller.queue_paused('voice', storage_down, self.controller.desired('voice-queue'), stopped))

    def test_pause_and_resume_use_each_projects_existing_api(self):
        image = self.fake_service(lambda: self.runtime_state('image', queue={'stage': 'idle', 'paused': image['paused']}))
        voice = self.fake_service(lambda: self.runtime_state('voice', queue_paused=voice['paused']))
        self.controller.item('image')['port'] = image['port']; self.controller.item('voice')['port'] = voice['port']
        with patch.object(self.controller, 'owned_processes', return_value=[]):
            self.assertEqual(self.controller.set_paused('image', True), {'ok': True, 'paused': True})
            self.assertEqual(self.controller.set_paused('image', False), {'ok': True, 'paused': False})
            self.assertEqual(self.controller.set_paused('voice', True), {'ok': True, 'paused': True})
            self.assertEqual(self.controller.set_paused('voice', False), {'ok': True, 'paused': False})
        self.assertEqual(image['requests'], [('PATCH', '/v1/queue', {'paused': True}), ('PATCH', '/v1/queue', {'paused': False})])
        self.assertEqual(voice['requests'], [('POST', '/api/queue/pause', {}), ('POST', '/api/queue/resume', {})])

    def test_pause_uses_the_queue_when_the_generator_is_off_and_never_an_unrelated_listener(self):
        stranger = self.fake_service(lambda: {'status': 'ready', 'service': 'something-else'})
        voice_queue = self.fake_service(lambda: {**self.queue_health('voice'), 'paused': voice_queue['paused']})
        self.controller.item('voice')['port'] = stranger['port']; self.controller.item('voice-queue')['port'] = voice_queue['port']
        with patch.object(self.controller, 'owned_processes', return_value=[]):
            self.assertEqual(self.controller.set_paused('voice', True), {'ok': True, 'paused': True})
        self.assertEqual(stranger['requests'], [])
        self.assertEqual(voice_queue['requests'], [('POST', '/api/queue/pause', {})])
        self.controller.item('voice-queue')['port'] = stranger['port']
        with patch.object(self.controller, 'owned_processes', return_value=[]):
            with self.assertRaisesRegex(ValueError, 'Start the generator or its queue'):
                self.controller.set_paused('voice', False)
        self.assertEqual(stranger['requests'], [])
        with self.assertRaisesRegex(ValueError, 'Only Image and Voice'):
            self.controller.set_paused('bridge', True)

    def test_pause_reports_an_unconfirmed_change(self):
        reply = lambda item, endpoint='/health', method='GET', body=None: (
            self.runtime_state('image') if endpoint == '/health' else {'paused': False})
        with patch.object(self.controller, 'owned_processes', return_value=[]), patch.object(self.controller, 'request', side_effect=reply):
            with self.assertRaisesRegex(ValueError, 'did not confirm'):
                self.controller.set_paused('image', True)

    def done_at(self, now, seconds):
        return '(done ~' + control.time.strftime('%-I:%M %p', control.time.localtime(now + seconds)) + ')'

    def test_progress_text_for_image_and_voice(self):
        now = 1_800_000_000
        describe = control.Controller.describe_progress
        image = {'percent': 62, 'phase': 'sampling', 'image': 2, 'total_images': 3, 'step': 5, 'total_steps': 8,
                 'estimated_remaining_seconds': 75, 'updated': now - 15}
        self.assertEqual(describe('image', image, now), '62% · image 2 of 3 · about 1 min left ' + self.done_at(now, 60))
        self.assertEqual(describe('image', {'percent': 0, 'phase': 'loading_model', 'image': None, 'total_images': 1,
            'estimated_remaining_seconds': None, 'updated': now}, now), '0% · loading model')
        self.assertEqual(describe('image', {'percent': 97, 'phase': 'finishing', 'total_images': 1,
            'estimated_remaining_seconds': 3, 'updated': now}, now), '97% · finishing · a few seconds left')
        self.assertEqual(describe('voice', {'percent': 40, 'phase': 'generating', 'estimated': True, 'eta_seconds': 32,
            'overdue': False, 'basis': 'history'}, now), '~40% · about 30 sec left ' + self.done_at(now, 32))
        self.assertEqual(describe('voice', {'percent': 95, 'phase': 'generating', 'eta_seconds': None, 'overdue': True}, now),
                         '~95% · taking longer than usual')
        self.assertEqual(describe('voice', {'percent': 0, 'phase': 'preparing', 'eta_seconds': None, 'overdue': False}, now), '~0% · preparing')
        self.assertEqual(describe('voice', {'percent': 10, 'phase': 'generating', 'eta_seconds': 7170}, now),
                         '~10% · about 2 h 0 min left ' + self.done_at(now, 7170))
        for missing in (None, {}, {'percent': None}, {'percent': True}, 'soon'):
            self.assertIsNone(describe('image', missing, now)); self.assertIsNone(describe('voice', missing, now))

    def test_tooltip_shows_running_job_progress_and_tolerates_older_servers(self):
        image = self.controller.desired('image')
        progress = {'percent': 62, 'phase': 'sampling', 'image': 1, 'total_images': 1, 'estimated_remaining_seconds': None, 'updated': None}
        busy = self.runtime_state('image', busy=True, active_model='qwen-image-2.1-turbo', progress=progress,
                                  queue={'stage': 'rendering', 'running': 1, 'waiting': 0})
        with patch.object(self.controller, 'request', return_value=busy), patch.object(self.controller, 'owned_processes', return_value=[123]):
            self.assertIn('\nProgress: 62%', self.controller.inspect(image)['detail'])
        busy.pop('progress')  # An image generator started before progress reporting.
        with patch.object(self.controller, 'request', return_value=busy), patch.object(self.controller, 'owned_processes', return_value=[123]):
            self.assertNotIn('Progress:', self.controller.inspect(image)['detail'])

        voice = self.controller.desired('voice')
        job = 'f' * 32
        state = self.runtime_state('voice', status='Generating', busy=True, active_job=job, queue_counts={'running': 1})
        state.pop('queue')
        replies = {'/health': state, '/api/jobs/' + job: {'id': job, 'status': 'running',
                   'progress': {'percent': 40, 'phase': 'generating', 'eta_seconds': None, 'overdue': True}}}
        requested = []
        def reply(item, endpoint='/health', method='GET', body=None):
            requested.append((method, endpoint)); return replies[endpoint]
        with patch.object(self.controller, 'request', side_effect=reply), patch.object(self.controller, 'owned_processes', return_value=[123]):
            self.assertIn('\nProgress: ~40% · taking longer than usual', self.controller.inspect(voice)['detail'])
        self.assertEqual(requested, [('GET', '/health'), ('GET', '/api/jobs/' + job)])
        replies['/api/jobs/' + job] = {'id': job, 'status': 'running'}  # A voice generator without estimates.
        with patch.object(self.controller, 'request', side_effect=reply), patch.object(self.controller, 'owned_processes', return_value=[123]):
            self.assertNotIn('Progress:', self.controller.inspect(voice)['detail'])
        # An idle generator or an unexpected job ID never triggers the extra lookup.
        for update in ({'busy': False, 'status': 'ready', 'active_job': None, 'queue_counts': {}}, {'active_job': '../health'}):
            requested.clear(); replies['/health'] = {**state, **update}
            with patch.object(self.controller, 'request', side_effect=reply), patch.object(self.controller, 'owned_processes', return_value=[123]):
                self.assertNotIn('Progress:', self.controller.inspect(voice)['detail'])
            self.assertEqual(requested, [('GET', '/health')])


if __name__ == '__main__': unittest.main()
