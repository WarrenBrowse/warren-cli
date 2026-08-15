#!/usr/bin/env sh
#
# Structural tests for the manifests in docker/examples/.
#
# These files are copy-paste templates: whatever they get wrong, users deploy.
# The properties pinned here are the ones whose absence leaks traffic or
# strands a container, and which no build step would ever catch.
#
#   sh docker/test-examples.sh
#
# Ruby carries YAML in its standard library (psych); the tests are skipped,
# loudly, on a host without it.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v ruby > /dev/null 2>&1; then
	echo "SKIP docker/test-examples.sh: no ruby on this host"
	exit 0
fi

ruby - "$REPO_DIR" <<'RUBY'
require 'yaml'

repo = ARGV[0]
$checks = 0
$failures = 0

def check(description)
  $checks += 1
  if yield
    puts "  ok   #{description}"
  else
    puts "  FAIL #{description}"
    $failures += 1
  end
end

def docs(path)
  YAML.load_stream(File.read(path))
end

puts 'kubernetes sidecar'
k8s = File.join(repo, 'docker/examples/k8s-sidecar.yaml')
deployment = docs(k8s).find { |d| d['kind'] == 'Deployment' }
pod = deployment['spec']['template']['spec']
inits = pod['initContainers'] || []
mains = pod['containers'] || []
warren = inits.find { |c| c['name'] == 'warren' }

# Ordinary pod containers start concurrently, so a warren listed there races
# the workload: the app egresses with the node's real IP for the whole
# bring-up, before the daemon has installed any firewall rule in the pod
# netns. A native sidecar (initContainer with restartPolicy Always) makes the
# kubelet hold the workload until warren's startup probe passes.
check('warren is a native sidecar, not a container racing the workload') do
  !warren.nil? && warren['restartPolicy'] == 'Always'
end
check('no warren among the ordinary containers') do
  mains.none? { |c| c['name'] == 'warren' }
end
check('the protected workload is an ordinary container the sidecar gates') do
  mains.any? { |c| c['name'] == 'app' }
end
check('the sidecar keeps the startup probe that gates the workload') do
  !warren.nil? && !warren['startupProbe'].nil?
end

# The exec probes spawn a process that opens the management socket, and
# WARREN_HEALTH_TARGET adds a curl with --max-time 10 on top. The kubelet's
# default timeoutSeconds is 1, which restarts the container in a loop and
# takes the pod's whole network down with it each time.
check('the startup probe outlives the kubelet default of one second') do
  (warren&.dig('startupProbe', 'timeoutSeconds') || 1) >= 5
end
check('the liveness probe allows a full WARREN_HEALTH_TARGET fetch') do
  (warren&.dig('livenessProbe', 'timeoutSeconds') || 1) >= 15
end

puts 'compose examples'
%w[docker-compose.yml docker-compose.qbittorrent.yml].each do |name|
  path = File.join(repo, 'docker/examples', name)
  raw = File.read(path)
  compose = docs(path).first
  joined = compose['services'].select { |_, s| s['network_mode'] == 'service:warren' }

  check("#{name}: something actually joins the tunnel namespace") { !joined.empty? }
  check("#{name}: every joined service waits for a healthy tunnel") do
    joined.all? { |_, s| s.dig('depends_on', 'warren', 'condition') == 'service_healthy' }
  end
  # Docker gives the restarted container a NEW namespace, and the services
  # that joined the old one keep a handle on a destroyed netns: no
  # connectivity, no error, until someone restarts them by hand. Compose
  # cannot express that dependency, so the caveat has to be written down.
  check("#{name}: the netns restart coupling is spelled out") do
    raw.include?('replaces the network namespace')
  end
end

puts 'qbittorrent up-command'
qbt = docs(File.join(repo, 'docker/examples/docker-compose.qbittorrent.yml')).first
env = qbt['services']['warren']['environment']
up = env.find { |e| e.start_with?('WARREN_PORT_FORWARD_UP_COMMAND=') }

# Recent qBittorrent authenticates localhost too, and the linuxserver image
# generates a random WebUI password on first start. Without the login leg the
# hook gets a 403, the listen port is never pushed, and the only signal is one
# WARNING line while the container stays healthy.
check('the hook authenticates before it writes preferences') do
  !up.nil? && up.index('/api/v2/auth/login') && up.index('/api/v2/app/setPreferences') &&
    up.index('/api/v2/auth/login') < up.index('/api/v2/app/setPreferences')
end
# curl's --retry with the default unlimited --retry-max-time can burn well
# over ten minutes; the entrypoint kills the hook, but the retry budget is
# what keeps a slow WebUI from eating the whole hook budget every time.
check('the retry budget is bounded') { !up.nil? && up.include?('--retry-max-time') }

puts
puts "#{$checks} checks, #{$failures} failure(s)"
exit($failures.zero? ? 0 : 1)
RUBY
