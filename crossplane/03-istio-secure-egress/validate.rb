# Run from the repository root. Add --render for Docker/CLI output-contract checks.
require 'yaml'
require 'open3'
require 'tmpdir'
require 'digest'

def run(*args)
  out, err, status = Open3.capture3(*args)
  abort "#{args.join(' ')} failed: #{err}" unless status.success?
  out
end

def check(condition, message)
  abort message unless condition
end

def render(path)
  YAML.load_stream(run('kubectl', 'kustomize', path)).compact
end

def one(docs, kind)
  matches = docs.select { |d| d['kind'] == kind }
  check(matches.size == 1, "expected exactly one #{kind}")
  matches.first
end

base = 'crossplane/03-istio-secure-egress'
registry = render('crossplane')
check(registry.size == 5 && registry.all? { |d| d['kind'] == 'Application' }, 'Applications-only registry')
app = registry.find { |d| d.dig('metadata', 'name') == 'istio-secure-egress' }
check(app && app.dig('spec', 'source', 'path') == base, 'parent registration')
check(render('infra').count { |d| d == app } == 1, 'single infra registry reference')
parent = render(base)
check(parent.size == 1 && parent.first['kind'] == 'ApplicationSet', 'parent must own only ApplicationSet')
set = parent.first['spec']
stages = set.dig('generators', 0, 'list', 'elements')
check(stages.map { |s| s['stage'] }.sort == %w[client compositions origin upstream xr], 'independent child ownership')
children = stages.flat_map do |stage|
  check(stage['path'] == "#{base}/#{stage['stage']}", 'child path')
  render(stage['path'])
end
identities = children.map { |d| [d['apiVersion'], d['kind'], d.dig('metadata', 'namespace'), d.dig('metadata', 'name')] }
check(identities.uniq == identities, 'duplicate child resource ownership')
check(children.none? { |d| %w[Application ApplicationSet Function Namespace Secret].include?(d['kind']) }, 'no self/namespace/Function/Secret ownership')
check(([app, parent.first] + children).none? { |d| d.dig('metadata', 'finalizers') || d.dig('spec', 'syncPolicy', 'automated', 'prune') }, 'no prune/finalizers')
check(set.dig('syncPolicy', 'preserveResourcesOnDeletion') == true, 'preserve child resources')
check(set.dig('template', 'spec', 'syncPolicy', 'automated') == { 'prune' => false, 'selfHeal' => true }, 'automated children without pruning')
check(!set.key?('strategy'), 'default AllAtOnce permits child auto-sync')
template = set.dig('template', 'spec')
check(template['ignoreDifferences'] == [{ 'group' => 'batch', 'kind' => 'Job', 'name' => 'secure-egress-client', 'namespace' => 'secure-egress-demo', 'jsonPointers' => ['/spec/suspend'] }] && template.dig('syncPolicy', 'syncOptions').include?('RespectIgnoreDifferences=true'), 'operator owns client suspend gate')

definitions = render("#{base}/compositions")
check(definitions.map { |d| d['kind'] }.sort == %w[ClusterRole Composition CompositeResourceDefinition EnvironmentConfig].sort, 'definitions only plus local RBAC/profile')
ref = 'https://github.com/mujak27/crossplane-compilations//03-istio-secure-egress?ref=istio-secure-egress-v0.1.0'
check(YAML.load_file("#{base}/compositions/kustomization.yaml")['resources'] == [ref, 'rbac.yaml', 'profile.yaml'], 'immutable definitions-only release import')
# Compare the tag-rendered definitions with the approved release commit, not examples.
%w[xrd composition].each do |file|
  release = YAML.load(run('curl', '-fsSL', "https://raw.githubusercontent.com/mujak27/crossplane-compilations/c9b64ce3cad0c36461e380f5c4f67a1d79ed5aaf/03-istio-secure-egress/#{file}.yaml"))
  check(one(definitions, release['kind']) == release, "#{file} differs from approved release commit")
end
xrd = one(definitions, 'CompositeResourceDefinition')
check(xrd['apiVersion'] == 'apiextensions.crossplane.io/v2' && xrd.dig('spec', 'scope') == 'Namespaced' && xrd.dig('metadata', 'name') == 'xistiosecureegresses.platform.mujak.com', 'namespaced v2 XRD')
composition = one(definitions, 'Composition')
check(composition.dig('spec', 'pipeline') == [{ 'step' => 'render', 'functionRef' => { 'name' => 'function-istio-secure-egress' } }], 'released Function pipeline')
role = one(definitions, 'ClusterRole')
check(role.dig('metadata', 'labels') == { 'rbac.crossplane.io/aggregate-to-crossplane' => 'true' }, 'aggregate composition RBAC')
check(role['rules'] == [{ 'apiGroups' => ['networking.istio.io'], 'resources' => %w[serviceentries gateways destinationrules virtualservices], 'verbs' => %w[get list watch create update patch delete] }], 'least-privilege native RBAC; no Secret or duplicate EnvironmentConfig grants')
profile = one(definitions, 'EnvironmentConfig')
check(!profile.dig('metadata', 'namespace'), 'cluster-scoped profile')
gateway = profile.dig('data', 'gateway')
values = YAML.load_file('infra/istio-egress/application.yaml').dig('spec', 'source', 'helm', 'valuesObject')
check(gateway == { 'namespace' => 'istio-egress', 'serviceFQDN' => 'istio-egress.istio-egress.svc.cluster.local', 'selector' => values['labels'], 'port' => 443 }, 'actual gateway profile')
check(values.dig('service', 'ports').any? { |p| p['port'] == gateway['port'] }, 'exposed Service port, not targetPort')
xrs = render("#{base}/xr")
xr = one(xrs, 'XIstioSecureEgress')
host = 'origin.origin-headless.secure-egress-origin.svc.cluster.local'
check(xrs.size == 1 && xr['apiVersion'] == 'platform.mujak.com/v1alpha1' && xr['metadata'] == { 'name' => 'secure-egress-demo', 'namespace' => 'secure-egress-demo' }, 'enabled namespaced XR identity')
check(xr['spec'] == { 'crossplane' => { 'compositionRef' => { 'name' => composition.dig('metadata', 'name') } }, 'hostname' => host, 'gatewayProfile' => 'secure-egress' }, 'exact XR contract')
check(profile.dig('metadata', 'name') == "istio-egress-#{xr.dig('spec', 'gatewayProfile')}", 'profile lookup')
job = one(render("#{base}/client"), 'Job')
check(job['apiVersion'] == 'batch/v1' && job['metadata'] == { 'name' => 'secure-egress-client', 'namespace' => 'secure-egress-demo' }, 'client identity')
check(job.dig('spec', 'suspend') == true && job.dig('spec', 'backoffLimit') == 0, 'no automatic traffic/retry')
pod = job.dig('spec', 'template')
check(pod.dig('metadata', 'annotations', 'sidecar.istio.io/inject') == 'true' && pod.dig('metadata', 'annotations', 'sidecar.istio.io/nativeSidecar') == 'true', 'captured client, native sidecar lets Job finish')
check(pod.dig('spec', 'automountServiceAccountToken') == false, 'client needs no Kubernetes credentials')
client = pod.dig('spec', 'containers')
check(client.size == 1 && client[0]['image'] == 'docker.io/curlimages/curl:8.12.1@sha256:94e9e444bcba979c2ea12e27ae39bee4cd10bc7041a472c4727a558e213744e6', 'published client image digest')
check(client[0]['args'] == ['--fail-with-body', '--show-error', '--silent', '--noproxy', '*', '--connect-timeout', '10', '--max-time', '30', "http://#{host}:80/"], 'client plain HTTP, no TLS bypass or retry')
check(children.to_yaml !~ /-----BEGIN|PRIVATE KEY|PLACEHOLDER|render\.crossplane\.io\/runtime/, 'no PEM/placeholder/development runtime')
shared = render('crossplane/_shared')
function = shared.select { |d| d.dig('metadata', 'name') == 'function-istio-secure-egress' }
check(function.size == 1 && function[0].dig('spec', 'package') == 'ghcr.io/mujak27/function-istio-secure-egress:v0.1.0' && !function[0].dig('metadata', 'annotations'), 'single shared released Function without runtime annotations')
%w[crossplane/01-tls-ingress crossplane/02-tls-ingress-custom crossplane/_shared crossplane/_controller infra/istio-ingress].each do |path|
  run('git', 'diff', '--name-only', '3d91b52', '--', path).lines.map(&:strip).each do |file|
    next if file == "#{path}/README.md"
    check(["#{path}/applicationset.yaml", 'infra/istio-ingress/application.yaml'].include?(file), "existing resource changed: #{file}")
    before = YAML.load(run('git', 'show', "3d91b52:#{file}"))
    after = YAML.load_file(file)
    spec = after['kind'] == 'ApplicationSet' ? after.dig('spec', 'template', 'spec') : after['spec']
    spec['syncPolicy'].delete('automated')
    spec['syncPolicy'].delete('retry')
    after['spec']['strategy'] = before.dig('spec', 'strategy') if after['kind'] == 'ApplicationSet'
    check(after == before, "non-policy declaration changed: #{file}")
  end
  Dir.glob("#{path}/**/kustomization.yaml").each { |file| render(File.dirname(file)) }
end
puts 'PASS: rendered ownership, release definitions, namespaced XR/profile, native RBAC, manual traffic gate, HTTP client pin, existing resources unchanged except sync policy'

if ARGV.include?('--render')
  Dir.mktmpdir('secure-egress-render-', ENV.fetch('TMPDIR')) do |dir|
    { 'composition' => composition, 'profile' => profile, 'xrd' => xrd }.each { |name, doc| File.write("#{dir}/#{name}.yaml", doc.to_yaml) }
    # Temporary CLI input only: run the exact published package, never Development/source.
    function[0]['spec']['package'] = 'ghcr.io/mujak27/function-istio-secure-egress@sha256:91f8e5a989ded2f52c43245d13d09e6111c766de4c5cd5badaed08ebcea5808c'
    File.write("#{dir}/function.yaml", function[0].to_yaml)
    output = YAML.load_stream(run('crossplane', 'render', "#{base}/xr/xr.yaml", "#{dir}/composition.yaml", "#{dir}/function.yaml", "--required-resources=#{dir}/profile.yaml", "--xrd=#{dir}/xrd.yaml", '--crossplane-version=v2.4.2', '--timeout=90s')).compact
    resources = output.reject { |d| d['kind'] == 'XIstioSecureEgress' }
    check(resources.map { |d| d['kind'] }.sort == %w[DestinationRule Gateway ServiceEntry VirtualService], 'actual Function output must be exactly four native kinds')
    check(resources.all? { |d| d['apiVersion'] == 'networking.istio.io/v1' && d.dig('metadata', 'name') == 'secure-egress-demo' && d.dig('metadata', 'namespace') == 'secure-egress-demo' && d.dig('metadata', 'ownerReferences', 0, 'kind') == 'XIstioSecureEgress' }, 'actual output scope/ownership')
    visibility = %w[secure-egress-demo istio-egress]
    check(one(resources, 'ServiceEntry')['spec'] == { 'hosts' => [host], 'location' => 'MESH_EXTERNAL', 'resolution' => 'DNS', 'exportTo' => visibility, 'ports' => [{ 'number' => 80, 'name' => 'http', 'protocol' => 'HTTP' }, { 'number' => 443, 'name' => 'https', 'protocol' => 'HTTPS' }] }, 'actual ServiceEntry visibility/HTTP/HTTPS')
    check(one(resources, 'Gateway')['spec'] == { 'selector' => gateway['selector'], 'servers' => [{ 'port' => { 'number' => 443, 'name' => 'https-egress', 'protocol' => 'HTTPS' }, 'hosts' => ["./#{host}"], 'tls' => { 'mode' => 'ISTIO_MUTUAL' } }] }, 'actual cross-namespace Gateway selection/listener')
    subset = 'egress-' + Digest::SHA256.hexdigest('secure-egress-demo/secure-egress-demo')[0, 32]
    check(one(resources, 'DestinationRule')['spec'] == { 'host' => gateway['serviceFQDN'], 'exportTo' => ['.'], 'subsets' => [{ 'name' => subset, 'trafficPolicy' => { 'portLevelSettings' => [{ 'port' => { 'number' => 443 }, 'tls' => { 'mode' => 'ISTIO_MUTUAL', 'sni' => host } }] } }] }, 'actual source-to-gateway mTLS')
    vs = one(resources, 'VirtualService')['spec']
    check(vs == { 'hosts' => [host], 'exportTo' => visibility, 'gateways' => ['mesh', 'secure-egress-demo/secure-egress-demo'], 'http' => [
      { 'match' => [{ 'gateways' => ['mesh'], 'port' => 80 }], 'route' => [{ 'destination' => { 'host' => gateway['serviceFQDN'], 'port' => { 'number' => 443 }, 'subset' => subset } }] },
      { 'match' => [{ 'gateways' => ['secure-egress-demo/secure-egress-demo'], 'port' => 443 }], 'route' => [{ 'destination' => { 'host' => host, 'port' => { 'number' => 443 } } }] }
    ] }, 'actual HTTP80 to gateway443 to origin443 routes')
    puts 'PASS: actual released Function local output via Crossplane v2.4.2 render engine; NOT live reconciliation/TLS evidence'
  end
end
