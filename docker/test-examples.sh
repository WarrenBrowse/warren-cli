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

# A manifest is a file people commit. Shipping a Secret with a placeholder
# phrase in it teaches the one storage habit the docs forbid, and the
# placeholder is what gets replaced in place, in the repo.
check('no recovery phrase is modelled inside the manifest') do
  docs(k8s).compact.none? { |d| d['kind'] == 'Secret' }
end

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
%w[
  docker-compose.yml
  docker-compose.qbittorrent.yml
  docker-compose.transmission.yml
  docker-compose.deluge.yml
].each do |name|
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
  # A recipe is copied verbatim into someone else's repository, so it carries
  # the workspace typography rule with it.
  check("#{name}: neither dash the workspace bans") { !raw.match?(/[\u2013\u2014]/) }
end

puts 'torrent client up-commands'
# One recipe per standard client. The up-command is the only thing that makes
# the client follow the port the exit granted, and every client takes it
# through a different API, so what is pinned is per-client: the leg that
# authenticates, the call that writes, and the exact setting names. A typo in
# any of them is a stack that stays healthy and seeds to nobody.
#
# Each recipe also turns the client's own UPnP/NAT-PMP and random-port
# picking OFF: the exit owns the mapping, and a client that renegotiates it
# or moves off the granted port undoes the grant it was just handed.
recipes = [
  {
    name: 'docker-compose.qbittorrent.yml',
    # qBittorrent Web API, POST /api/v2/app/setPreferences.
    handshake: '/api/v2/auth/login',
    write: '/api/v2/app/setPreferences',
    fields: ['"listen_port":{{PORT}}', '"random_port":false', '"upnp":false'],
    credentials: ['${QBT_USER:?', '${QBT_PASS:?'],
    headers: []
  },
  {
    name: 'docker-compose.transmission.yml',
    # Transmission RPC session arguments, rpc-spec.md section 4.1:
    # https://github.com/transmission/transmission/blob/4.0.6/docs/rpc-spec.md
    handshake: '"method":"session-get"',
    write: '"method":"session-set"',
    fields: [
      '"peer-port":{{PORT}}',
      '"peer-port-random-on-start":false',
      '"port-forwarding-enabled":false'
    ],
    credentials: ['${TR_USER:?', '${TR_PASS:?'],
    # CSRF protection: the first request answers 409 and carries the id to
    # replay with. Without the replay header every write is a 409 forever.
    headers: ['X-Transmission-Session-Id']
  },
  {
    name: 'docker-compose.deluge.yml',
    # Deluge web JSON-RPC, deluge/core/preferencesmanager.py config keys.
    handshake: '"method":"auth.login"',
    write: '"method":"core.set_config"',
    fields: [
      '"listen_ports":[{{PORT}},{{PORT}}]',
      '"random_port":false',
      '"upnp":false',
      '"natpmp":false'
    ],
    credentials: ['${DELUGE_PASS:?'],
    # deluge/ui/web/json_api.py rejects any other content type outright.
    headers: ['Content-Type: application/json']
  }
]

recipes.each do |recipe|
  path = File.join(repo, 'docker/examples', recipe[:name])
  raw = File.read(path)
  env = docs(path).first['services']['warren']['environment']
  up = env.find { |e| e.start_with?('WARREN_PORT_FORWARD_UP_COMMAND=') }
  label = recipe[:name].sub('docker-compose.', '').sub('.yml', '')

  check("#{label}: the grant reaches the client through an up-command") do
    !up.nil? && up.include?('{{PORT}}')
  end
  # Every one of these WebUIs authenticates on localhost too. Without the
  # login leg the write is refused, the port is never pushed, and the only
  # signal is one WARNING line while the container stays healthy.
  check("#{label}: the hook authenticates before it writes") do
    !up.nil? && up.index(recipe[:handshake]) && up.index(recipe[:write]) &&
      up.index(recipe[:handshake]) < up.index(recipe[:write])
  end
  check("#{label}: the write carries the granted port and pins the settings that fight it") do
    !up.nil? && recipe[:fields].all? { |f| up.include?(f) }
  end
  # curl's --retry with the default unlimited --retry-max-time can burn well
  # over ten minutes; the entrypoint kills the hook, but the retry budget is
  # what keeps a slow WebUI from eating the whole hook budget every time.
  check("#{label}: the retry budget is bounded") { !up.nil? && up.include?('--retry-max-time') }
  # Compose substitutes an unset variable with an empty string and only warns,
  # so a missing .env would start the stack with empty credentials: the WebUI
  # refuses the hook and the container still looks healthy. The
  # required-variable syntax refuses to start instead.
  check("#{label}: the credentials are required, not defaulted to empty") do
    recipe[:credentials].all? { |c| raw.include?(c) }
  end
  recipe[:headers].each do |header|
    check("#{label}: the hook sends #{header}") { !up.nil? && up.include?(header) }
  end
end

puts
puts "#{$checks} checks, #{$failures} failure(s)"
exit($failures.zero? ? 0 : 1)
RUBY
