import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location('configure_install', Path(__file__).parents[1] / 'Tools/configure_install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
from control import atomic_json, read_json


class InstallConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.controller = installer.Controller(self.root / 'support')
        self.resolve = patch.object(self.controller, 'resolve', side_effect=lambda identifier: (
            self.controller.desired(identifier), {'running': False}))
        self.resolve.start()
        self.addCleanup(self.resolve.stop)
        self.output = Mock()

    def configure(self, answers, interactive=True):
        reader = Mock(side_effect=answers)
        installer.configure(self.controller, interactive=interactive, read=reader, write=self.output)
        return reader

    def test_enter_keeps_saved_values_and_other_settings_exactly(self):
        saved = copy.deepcopy(self.controller.config)
        for item in saved['services']:
            item['root'] = '/currently configured/' + item['id'].split('-')[0]
            item['environment'] = 'DATA_DIR=/private storage'
        saved['services'][0]['binary'] = '/custom/bin/ai-bridge'
        saved['services'][1].update(port=6732, llm=False, loras=False)
        atomic_json(self.controller.config_file, saved)
        self.controller = installer.Controller(self.controller.support)
        before = self.controller.config_file.read_bytes()
        with patch.object(self.controller, 'save_many') as save:
            reader = self.configure(['', '  ', ''])
        save.assert_not_called()
        self.assertEqual(self.controller.config_file.read_bytes(), before)
        self.assertIn('/currently configured/bridge', reader.call_args_list[0].args[0])
        self.assertIn('/currently configured/image', reader.call_args_list[1].args[0])
        self.assertIn('/currently configured/voice', reader.call_args_list[2].args[0])

    def test_first_install_enter_uses_defaults_without_writing(self):
        self.configure(['', '', ''])
        self.assertFalse(self.controller.config_file.exists())

    def test_changed_paths_are_saved_together_and_both_queues_follow(self):
        original = copy.deepcopy(self.controller.config)
        directories = [self.root / name for name in ('AI Bridge state', 'Image $(literal)', 'Voice ü')]
        for directory in directories:
            directory.mkdir()
        # Quoted paths are accepted; shell-looking characters remain literal.
        with patch('control.atomic_json', wraps=atomic_json) as save:
            self.configure([str(directories[0]), '"' + str(directories[1]) + '"', str(directories[2])])
        save.assert_called_once()
        saved = installer.Controller(self.controller.support)
        for identifier, directory in zip(('bridge', 'image', 'voice'), directories):
            self.assertEqual(saved.item(identifier)['root'], str(directory))
            if identifier != 'bridge':
                self.assertEqual(saved.item(identifier + '-queue')['root'], str(directory))
        for before, after in zip(original['services'], saved.config['services']):
            self.assertEqual({k: v for k, v in before.items() if k != 'root'},
                             {k: v for k, v in after.items() if k != 'root'})

    def test_invalid_directory_reprompts_and_enter_keeps_current(self):
        not_a_directory = self.root / 'file'
        not_a_directory.touch()
        reader = self.configure([str(self.root / 'missing'), str(not_a_directory), '', '', ''])
        self.assertEqual(reader.call_count, 5)
        self.assertEqual(sum('Directory not found:' in call.args[0] for call in self.output.call_args_list), 2)
        self.assertFalse(self.controller.config_file.exists())

    def test_cancel_after_an_answer_does_not_save_partial_changes(self):
        for error in (EOFError(), KeyboardInterrupt()):
            with self.subTest(error=type(error).__name__):
                with self.assertRaises(type(error)):
                    self.configure([str(self.root), error])
                self.assertFalse(self.controller.config_file.exists())

    def test_unattended_mode_never_reads_or_writes(self):
        reader = self.configure([], interactive=False)
        reader.assert_not_called()
        self.assertFalse(self.controller.config_file.exists())

    def test_running_endpoints_are_retained_when_directories_change(self):
        self.resolve.stop()
        original = {identifier: self.controller.desired(identifier) for identifier in ('bridge', 'image', 'image-queue', 'voice', 'voice-queue')}
        with patch.object(self.controller, 'resolve', side_effect=lambda identifier: (original[identifier], {'running': True})):
            self.configure([str(self.root), str(self.root), str(self.root)])
        for identifier, settings in original.items():
            self.assertEqual(read_json(self.controller.active_file(identifier))['settings'], settings)

    def test_invalid_batch_does_not_write_any_of_the_changes(self):
        before = copy.deepcopy(self.controller.config)
        with self.assertRaisesRegex(ValueError, 'Ports must be'):
            self.controller.save_many([{'id': 'image', 'root': str(self.root)}, {'id': 'voice', 'port': 80}])
        self.assertFalse(self.controller.config_file.exists())
        self.assertEqual(self.controller.config, before)


if __name__ == '__main__':
    unittest.main()
