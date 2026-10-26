import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / ('Resources/' + name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


control = load('control')
metrics = load('metrics')
NOW = 1800000000


class MetricsTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.controller = control.Controller(Path(self.folder.name))
        self.store = metrics.MetricsStore(self.folder.name)
        self.roots = {'bridge': {20}, 'image': {10}, 'image-queue': {11}, 'voice': set(), 'voice-queue': set()}
        self.controller.owned_processes = Mock(side_effect=lambda item, pairs: list(self.roots[item['id']] & {int(p) for p, _ in pairs}))
        binary = str(control.path(self.controller.desired('bridge')['binary']))
        self.table = {
            10: {'parent': 1, 'command': 'python server.py --port 5742'},
            11: {'parent': 10, 'command': 'python queue_api.py --port 55302'},
            12: {'parent': 11, 'command': 'queue helper'},
            13: {'parent': 10, 'command': 'image helper'},
            20: {'parent': 1, 'command': binary + ' --port 8765 serve'},
            21: {'parent': 20, 'command': 'provider helper'},
        }
        self.usage = {pid: {'start': pid * 100, 'cpu': 0, 'memory': pid * 1024} for pid in self.table}
        self.gpus = {10: {'client:0': 1000000000}}
        self.gpu_available = True

    def sample(self, seconds=0):
        result = self.store.sample(self.controller, now=NOW + seconds, uptime=1000 + seconds,
                                  table=self.table, usage_reader=lambda pid: self.usage.get(pid),
                                  gpu_reader=lambda: (self.gpu_available, self.gpus))
        return {s['id']: s for s in result['services']}

    def test_live_children_and_queue_are_counted_separately(self):
        groups = metrics.service_processes(self.controller, self.table)
        self.assertEqual(groups['image'], {10, 13})
        self.assertEqual(groups['image-queue'], {11, 12})
        self.assertEqual(groups['bridge'], {20, 21})

    def test_backend_switch_follows_new_children_without_restarting_history(self):
        first = self.sample()['image']
        del self.table[13]
        self.table[14] = {'parent':10, 'command':'python backend_runtime.py --model chroma1-hd'}
        self.usage[14] = {'start':1400, 'cpu':1, 'memory':14*1024}
        switched = self.sample(60)['image']
        self.assertEqual(switched['run'], first['run'])
        self.assertEqual(switched['processes'], 2)
        self.assertEqual(switched['memory'], (10+14)*1024)
        self.assertIsNone(switched['cpu'])
        self.assertEqual(metrics.service_processes(self.controller, self.table)['image-queue'], {11,12})

    def test_metrics_process_list_retries_a_transient_timeout(self):
        command = ['/bin/ps', '-axo', 'pid=,ppid=,uid=,command=']
        result = control.subprocess.CompletedProcess(command, 0, stdout=f'123 1 {os.getuid()} python server.py\n')
        with patch.object(control.subprocess, 'run', side_effect=[control.subprocess.TimeoutExpired(command, 5), result]) as run:
            table = metrics.process_table(self.controller)
        self.assertEqual(table, {123: {'parent': 1, 'command': 'python server.py'}})
        self.assertEqual([call.kwargs['timeout'] for call in run.call_args_list], [5, 8])

    def test_failed_process_query_preserves_history_and_running_state(self):
        self.sample()
        with patch.object(self.controller, 'read_process_info', side_effect=ValueError('macOS took too long to read process status')):
            with self.assertRaises(ValueError):
                self.store.sample(self.controller, now=NOW + 60)
        history = self.store.history('image', '5m', now=NOW + 60)
        self.assertTrue(history['running'])
        self.assertEqual(len(history['points']), 1)

    def test_bridge_executable_with_spaces_is_identified(self):
        del self.controller.owned_processes
        only_bridge = {pid: self.table[pid] for pid in (20, 21)}
        self.assertEqual(metrics.service_processes(self.controller, only_bridge)['bridge'], {20, 21})

    def test_first_interval_is_unknown_instead_of_invented_zero(self):
        first = self.sample()
        self.assertIsNone(first['image']['cpu'])
        self.assertIsNone(first['image']['gpu'])
        self.assertEqual(first['image']['memory'], (10 + 13) * 1024)
        self.assertEqual(first['bridge']['gpu'], 0)

    def test_cpu_gpu_deltas_and_memory_sum(self):
        self.sample()
        self.usage[10]['cpu'] = 30 * 10**9
        self.usage[13]['cpu'] = 15 * 10**9
        self.usage[11]['cpu'] = 6 * 10**9
        self.gpus[10]['client:0'] += 30 * 10**9
        result = self.sample(60)
        self.assertAlmostEqual(result['image']['cpu'], 75)
        self.assertAlmostEqual(result['image']['gpu'], 50)
        self.assertAlmostEqual(result['image-queue']['cpu'], 10)
        self.assertEqual(result['image']['processes'], 2)

    def test_cpu_can_use_more_than_one_core(self):
        self.sample()
        self.usage[10]['cpu'] = 180 * 10**9
        self.assertAlmostEqual(self.sample(60)['image']['cpu'], 300)

    def test_reused_pid_does_not_create_a_spike(self):
        self.sample()
        self.usage[10].update(start=9999, cpu=900 * 10**9)
        self.assertIsNone(self.sample(60)['image']['cpu'])
        self.usage[10]['cpu'] += 6 * 10**9
        self.assertAlmostEqual(self.sample(120)['image']['cpu'], 10)

    def test_sleep_and_counter_resets_produce_gaps(self):
        self.sample()
        self.assertIsNone(self.sample(300)['image']['cpu'])
        self.usage[10]['cpu'] = 10 * 10**9
        self.sample(360)
        self.usage[10]['cpu'] = 1
        self.assertIsNone(self.sample(420)['image']['cpu'])

    def test_missing_or_reset_gpu_counters_are_not_reported_as_idle(self):
        self.sample()
        self.gpus[10]['client:0'] = 0
        self.assertIsNone(self.sample(60)['image']['gpu'])
        self.gpus[10] = {}
        self.assertIsNone(self.sample(120)['image']['gpu'])

    def test_unavailable_gpu_and_exited_process_are_unknown(self):
        self.sample()
        self.gpu_available = False
        del self.usage[10]
        result = self.sample(60)
        self.assertIsNone(result['image']['cpu'])
        self.assertIsNone(result['image']['memory'])
        self.assertIsNone(result['image']['gpu'])
        self.assertNotIn('voice', result)

    def test_stopped_services_are_not_sampled_and_keep_prior_history(self):
        self.sample()
        self.roots = {key: set() for key in self.roots}
        result = self.sample(60)
        self.assertEqual(result, {})
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM baselines').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM samples WHERE processes=0').fetchone()[0], 0)
        history = self.store.history('image', '5m', now=NOW + 60)
        self.assertFalse(history['running'])
        self.assertEqual(history['latest']['timestamp'], NOW)

    def test_gpu_query_is_skipped_when_every_service_is_stopped(self):
        self.roots = {key: set() for key in self.roots}
        gpu = Mock(side_effect=AssertionError('GPU query should not run'))
        result = self.store.sample(self.controller, now=NOW, uptime=1000, table=self.table,
                                  usage_reader=Mock(side_effect=AssertionError('No counters while stopped')), gpu_reader=gpu)
        self.assertEqual(result['services'], [])
        gpu.assert_not_called()

    def test_runs_are_separate_even_after_a_short_stop(self):
        first = self.sample()['image']['run']
        self.roots['image'] = set()
        self.sample(15)
        self.roots['image'] = {10}
        second = self.sample(30)['image']['run']
        self.assertNotEqual(first, second)
        self.usage[10]['start'] += 1
        self.assertNotEqual(second, self.sample(45)['image']['run'])

    def test_all_ranges_and_retention_without_backfilling_history(self):
        with self.store.connect() as db:
            db.execute('INSERT INTO samples(service,ts,cpu,memory,gpu,processes,interval) VALUES (?,?,?,?,?,?,?)', ('image', NOW - metrics.RETENTION - 1, 999, 999, 999, 1, 60))
        self.sample()
        self.sample(60)
        for name, duration in metrics.RANGES.items():
            history = self.store.history('image', name, now=NOW + 60)
            self.assertEqual(history['start'], NOW + 60 - duration)
            self.assertEqual(history['recording_since'], NOW)
            self.assertTrue(1 <= len(history['points']) <= 2)
            self.assertEqual(history['latest']['timestamp'], NOW + 60)
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT MIN(ts) FROM samples').fetchone()[0], NOW)
        self.assertEqual(os.stat(self.store.path).st_mode & 0o777, 0o600)

    def test_long_history_is_bounded_and_retains_actual_peaks(self):
        with self.store.connect() as db:
            db.executemany('INSERT INTO samples(service,ts,cpu,memory,gpu,processes,interval) VALUES (?,?,?,?,?,?,?)',
                           [('image', NOW - i * 60, 500 if i == 51 else 10, 1000, 0, 1, 60) for i in range(10000)])
        history = self.store.history('image', '7d', now=NOW)
        self.assertLessEqual(len(history['points']), 361)
        self.assertEqual(history['peaks']['cpu'], 500)
        self.assertEqual(history['latest']['cpu'], 10)

    def test_nested_gpu_registry_and_independent_clients(self):
        available, result = metrics.parse_gpu_registry([{'IORegistryEntryChildren': [
            {'IOObjectClass': 'AGXDeviceUserClient', 'IORegistryEntryID': 30,
             'IOUserClientCreator': 'pid 10, python', 'AppUsage': [{'accumulatedGPUTime': 50}, {'accumulatedGPUTime': 25}]},
            {'IOObjectClass': 'AGXDeviceUserClient', 'IORegistryEntryID': 31,
             'IOUserClientCreator': 'pid 10, python', 'AppUsage': [{'accumulatedGPUTime': 10}]}]}])
        self.assertTrue(available)
        self.assertEqual(result, {10: {'30:0': 50, '30:1': 25, '31:0': 10}})
        self.assertEqual(metrics.parse_gpu_registry([]), (False, {}))
        self.assertEqual(metrics.parse_gpu_registry([{'IOObjectClass': 'AGXDeviceUserClient'}]), (False, {}))

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin counters')
    def test_real_read_only_process_counter_abi(self):
        usage = metrics.process_usage(os.getpid())
        self.assertGreater(usage['memory'], 0)
        self.assertGreater(usage['start'], 0)
        self.assertGreater(usage['cpu'], 0)


if __name__ == '__main__':
    unittest.main()
