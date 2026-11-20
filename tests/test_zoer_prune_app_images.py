"""zoer-prune-app-images.sh against stub kubectl/ssh and a stub node; no cluster or host writes.

The stub ssh runs the remote command locally with bash, with stub sudo, k3s and
docker in front of PATH answering from fixture files. The node's `date` must be
GNU: real GNU date (Linux, or Homebrew `gdate`) when there is one, otherwise a
small stand-in that accepts and rejects the same inputs as GNU coreutils 9.4 on
k3s-node-1. In particular, it rejects Docker's human CreatedAt with a zone name
("2026-11-18 17:05:13 -0700 MST"), which is what broke the 2026-11-20 deploy's
prune with "docker: unbound variable".
Needs bash, jq and python3.
"""
import datetime
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/zoer-prune-app-images.sh'

KUBECTL = r'''#!/usr/bin/env bash
case " $* " in
  *" get deploy "*) cat "$TEST_ROOT/deploy-images" ;;
  *" get pods "*) cat "$TEST_ROOT/pod-images" ;;
esac
exit 0
'''
# The last argument is the remote command, run as the node's login shell would.
SSH = r'''#!/usr/bin/env bash
printf '%s\n--\n' "${@: -1}" >> "$TEST_ROOT/remote-commands"
PATH="$TEST_ROOT/node-bin:$PATH" exec bash -c "${@: -1}"
'''
SUDO = '#!/usr/bin/env bash\n[[ "$1" == -n ]] && shift\nexec "$@"\n'
# containerd fixture: "<ref> <RFC3339 created>" per line.
K3S = r'''#!/usr/bin/env bash
case "$*" in
  "ctr -n k8s.io images list -q") cut -d' ' -f1 "$TEST_ROOT/containerd" ;;
  "crictl inspecti -o json "*)
    awk -v r="$5" '$1 == r { printf "{\"info\":{\"imageSpec\":{\"created\":\"%s\"}}}\n", $2 }' "$TEST_ROOT/containerd" ;;
  "ctr -n k8s.io images rm "*) echo "containerd rm $6" >> "$TEST_ROOT/removed" ;;
esac
exit 0
'''
# docker fixture: "<ref>|<.Created RFC3339>|<.CreatedAt as the node prints it>" per line.
DOCKER = r'''#!/usr/bin/env bash
if [[ "$1 $2" == "images --format" ]]; then
  while IFS='|' read -r ref created human; do
    o="$3"; o="${o//'{{.Repository}}'/${ref%%:*}}"; o="${o//'{{.Tag}}'/${ref#*:}}"; o="${o//'{{.CreatedAt}}'/$human}"
    echo "$o"
  done < "$TEST_ROOT/docker"
elif [[ "$1 $2 $3 $4" == "image inspect -f {{.Created}}" ]]; then
  awk -F'|' -v r="$5" '$1 == r { print $2; found = 1 } END { exit !found }' "$TEST_ROOT/docker"
elif [[ "$1" == rmi ]]; then
  echo "docker rmi $2" >> "$TEST_ROOT/removed"
fi
'''
GNU_DATE = r'''#!/usr/bin/env python3
"""`date -u -d STR +%s` the way GNU coreutils parses the inputs at hand."""
import datetime, os, re, sys
args = sys.argv[1:]
if '-d' not in args:
    os.execv('/bin/date', ['date', *args])
s = args[args.index('-d') + 1]
assert args[-1] == '+%s' and '-u' in args, args
m = re.fullmatch(r'(\d{4}-\d\d-\d\d)[T ](\d\d:\d\d:\d\d)(?:\.\d+)? ?(Z|UTC|[+-]\d\d:?\d\d)?', s)
if not m:
    sys.exit(f"date: invalid date '{s}'")
zone = m[3] or 'Z'
if zone in ('Z', 'UTC'):
    offset = datetime.timedelta(0)
else:
    sign, hh, mm = zone[0], int(zone[1:3]), int(zone[-2:])
    offset = (1 if sign == '+' else -1) * datetime.timedelta(hours=hh, minutes=mm)
t = datetime.datetime.fromisoformat(f'{m[1]}T{m[2]}').replace(tzinfo=datetime.timezone(offset))
print(int(t.timestamp()))
'''

MST = datetime.timezone(datetime.timedelta(hours=-7), 'MST')


def human(rfc3339):
    """Docker's {{.CreatedAt}} on a node whose clock is America/Vancouver."""
    t = datetime.datetime.fromisoformat(re.sub(r'\.\d+', '', rfc3339).replace('Z', '+00:00'))
    return t.astimezone(MST).strftime('%Y-%m-%d %H:%M:%S %z %Z')


class PruneAppImages(unittest.TestCase):
    def setUp(self):
        for tool in ('bash', 'jq', 'python3'):
            if not shutil.which(tool):
                self.skipTest(f'{tool} not installed')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        bindir, nodebin = self.root / 'bin', self.root / 'node-bin'
        bindir.mkdir()
        nodebin.mkdir()
        node_tools = {'sudo': SUDO, 'k3s': K3S, 'docker': DOCKER}
        version = subprocess.run(['date', '--version'], capture_output=True, text=True).stdout
        if 'GNU' not in version:
            node_tools['date'] = f'#!/bin/sh\nexec "{shutil.which("gdate")}" "$@"\n' if shutil.which('gdate') else GNU_DATE
        for directory, tools in ((bindir, {'kubectl': KUBECTL, 'ssh': SSH}), (nodebin, node_tools)):
            for name, body in tools.items():
                (directory / name).write_text(body)
                (directory / name).chmod(0o755)
        (self.root / 'kubeconfig').write_text('')
        self.env = dict(os.environ, TEST_ROOT=str(self.root), PATH=f'{bindir}:{os.environ["PATH"]}',
                        KUBECONFIG=str(self.root / 'kubeconfig'), ZOER_K8S_DEV_SSH_KEY='/dev/null',
                        ZOER_PRUNE_FRESH_HOURS='3')
        # Running: backend:current and frontend:current. Rollback target: backend:previous.
        (self.root / 'deploy-images').write_text(
            'docker.io/zoer-local/backend:current\nzoer-local/backend:previous\n'
            'docker.io/zoer-local/frontend:current\n\n')
        (self.root / 'pod-images').write_text(
            'docker.io/zoer-local/backend:current\ndocker.io/zoer-local/frontend:current\n'
            'docker.io/zoer-local/browser-runtime:rt1\n')
        (self.root / 'containerd').write_text(''.join(f'docker.io/{ref} {created}\n' for ref, created in [
            ('zoer-local/backend:current', '2026-01-10T00:00:00.123456789Z'),
            ('zoer-local/backend:previous', '2026-01-09T00:00:00Z'),
            ('zoer-local/backend:dev-b', '2026-01-07T00:00:00Z'),
            ('zoer-local/backend:dev-d', '2026-01-05T00:00:00Z'),
            ('zoer-local/frontend:current', '2026-01-10T00:00:00Z'),
            ('zoer-local/frontend:f-2', '2026-01-03T00:00:00Z'),
            ('zoer-local/browser-runtime:rt1', '2026-01-01T00:00:00Z'),
            ('library/nginx:latest', '2026-01-01T00:00:00Z'),
        ]))
        self.docker = [
            ('zoer-local/backend:current', '2026-01-09T23:59:00.5Z'),
            ('zoer-local/backend:dev-c', '2026-01-08T17:00:00.736243467-07:00'),
            ('zoer-local/backend:named-a', '2026-01-06T00:00:00.1Z'),
            ('zoer-local/backend:dev-d', '2026-01-04T00:00:00Z'),
            ('zoer-local/frontend:f-1', '2026-01-04T00:00:00Z'),
            ('zoer-local/frontend:f-3', '2026-01-02T00:00:00Z'),
            ('zoer-local/browser-runtime:rt1', '2026-01-01T00:00:00Z'),
        ]

    def prune(self, *args):
        (self.root / 'docker').write_text(''.join(
            f'{ref}|{created}|{human(created) if created[0].isdigit() else created}\n' for ref, created in self.docker))
        r = subprocess.run(['bash', str(SCRIPT), *args], env=self.env, capture_output=True, text=True, timeout=60)
        removed = (self.root / 'removed').read_text() if (self.root / 'removed').exists() else ''
        return r, removed

    LISTING = '''==> zoer-local/backend
     keep (in use / rollback) zoer-local/backend:current
     keep (in use / rollback) zoer-local/backend:previous
     keep (newest 1/2) zoer-local/backend:dev-c
     keep (newest 2/2) zoer-local/backend:dev-b
     REMOVE zoer-local/backend:named-a
     REMOVE zoer-local/backend:dev-d
==> zoer-local/frontend
     keep (in use / rollback) zoer-local/frontend:current
     keep (newest 1/2) zoer-local/frontend:f-1
     keep (newest 2/2) zoer-local/frontend:f-2
     REMOVE zoer-local/frontend:f-3
'''

    def test_dry_run_on_a_non_utc_node_lists_both_components(self):
        # Docker-only images (dev-c, named-a, f-1, f-3) need Docker's creation
        # time; dev-c must outrank the containerd-only dev-b to be kept.
        r, removed = self.prune()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn('unbound variable', r.stderr)
        self.assertEqual(r.stdout, self.LISTING + '\nDry run. Re-run with --apply to remove 3 image(s).\n')
        self.assertEqual(removed, '')

    def test_apply_removes_only_the_listed_images(self):
        r, removed = self.prune('--apply')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(r.stdout.startswith(self.LISTING + '==> removing\n'), r.stdout)
        doomed = ['zoer-local/backend:named-a', 'zoer-local/backend:dev-d', 'zoer-local/frontend:f-3']
        self.assertEqual(sorted(removed.splitlines()),
                         sorted([f'docker rmi {ref}' for ref in doomed] + [f'containerd rm docker.io/{ref}' for ref in doomed]))
        for ref in doomed:
            self.assertIn(f'     removed {ref}\n', r.stdout)
        self.assertIn('node disk: ', r.stdout)

    def test_unreadable_creation_time_is_reported_and_left_alone(self):
        self.docker.append(('zoer-local/backend:odd', 'not-a-date'))
        r, removed = self.prune('--apply')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('unreadable creation time "not-a-date" for docker zoer-local/backend:odd; leaving it alone', r.stderr)
        self.assertNotIn('backend:odd', r.stdout)
        self.assertNotIn('backend:odd', removed)
        self.assertIn('REMOVE zoer-local/frontend:f-3', r.stdout)


if __name__ == '__main__':
    unittest.main()
