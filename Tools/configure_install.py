#!/usr/bin/env python3
"""Choose existing service directories before building the monitor."""
import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Resources'))
from control import Controller, path


DIRECTORIES = (
    ('bridge', 'AI Bridge state directory'),
    ('image', 'Image Generator project directory'),
    ('voice', 'Voice Generator project directory'),
)


def configure(controller, *, interactive, read=input, write=print):
    write('Service directories (press Enter to keep the current value).' if interactive
          else 'Using the currently configured service directories (no interactive prompts).')
    write('AI Bridge uses its state folder, containing its token and logs.')
    patches = []
    for identifier, label in DIRECTORIES:
        current = controller.item(identifier)['root']
        if not interactive:
            write(f'  {label}: {current}')
            continue
        while True:
            answer = read(f'\n{label} [{current}]: ').strip()
            if not answer:
                break
            # Accept pasted quoted paths, but never interpret shell syntax.
            if len(answer) >= 2 and answer[0] == answer[-1] and answer[0] in ('"', "'"):
                answer = answer[1:-1]
            selected = path(answer)
            if not selected.is_dir():
                write(f'  Directory not found: {selected}. Enter an existing directory, or press Enter to keep the current value.')
                continue
            if selected != path(current):
                patches.append({'id': identifier, 'root': str(selected)})
            break
    if patches:
        # One configuration transaction also synchronizes both queues and retains
        # the actual settings of services that are already running.
        controller.save_many(patches)
        write('\nDirectories saved. Running services keep their current settings until their next start.')
    else:
        write('\nKeeping the currently configured directories.')


def main():
    parser = argparse.ArgumentParser(prog='./install.sh', description=__doc__)
    parser.add_argument('--non-interactive', action='store_true', help='keep the current directories without prompting')
    args = parser.parse_args()
    try:
        configure(Controller(), interactive=sys.stdin.isatty() and not args.non_interactive)
    except (EOFError, KeyboardInterrupt):
        print('\nInstallation cancelled; no directories were changed.', file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        print('Could not configure service directories: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
