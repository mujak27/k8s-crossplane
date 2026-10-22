# Run from the repository root: ruby crossplane/03-istio-secure-egress/validate-platform.rb
require 'yaml'
require 'open3'
require 'tmpdir'
require 'digest'

def run(*args, input: '')
  out, err, status = Open3.capture3(*args, stdin_data: input)
  abort "#{args.join(' ')} failed: #{err}" unless status.success?
  out
end

def check(condition, message)
  abort message unless condition
end

def one(docs, kind)
  matches = docs.select { |d| d['kind'] == kind }
  check(matches.size == 1, "expected exactly one #{kind}")
  matches.first
end

infra = YAML.load_stream(run('kubectl', 'kustomize', 'infra'))
%w[crossplane crossplane/_shared infra/istio-egress infra/secure-egress-namespaces].each do |path|
  run('kubectl', 'kustomize', path)
end
namespaces = infra.select { |d| d['kind'] == 'Namespace' }
%w[istio-egress secure-egress-origin secure-egress-demo].each do |name|
  check(namespaces.count { |d| d.dig('metadata', 'name') == name } == 1, "duplicate/missing namespace #{name}")
end
origin_ns = namespaces.find { |d| d.dig('metadata', 'name') == 'secure-egress-origin' }
check(origin_ns.dig('metadata', 'labels', 'istio-injection') == 'disabled', 'origin must be unmeshed')
gateway_ns = namespaces.find { |d| d.dig('metadata', 'name') == 'istio-egress' }
check((gateway_ns.dig('metadata', 'labels') || {}).empty?, 'gateway namespace injection eligibility')
demo_ns = namespaces.find { |d| d.dig('metadata', 'name') == 'secure-egress-demo' }
check(demo_ns.dig('metadata', 'labels') == { 'istio-injection' => 'enabled' }, 'demo sidecar injection')

app = YAML.load_file('infra/istio-egress/application.yaml')
check(infra.count { |d| d['kind'] == 'Application' && d.dig('metadata', 'name') == 'istio-egress' } == 1, 'gateway Application ownership')
check(!app.dig('spec', 'syncPolicy').key?('automated'), 'gateway must sync manually')
check(!app.dig('metadata', 'finalizers'), 'no cascading deletion')
source = app.dig('spec', 'source')
check(source['targetRevision'] == '1.31.1' && source['chart'] == 'gateway', 'gateway chart pin')

Dir.mktmpdir('secure-egress-', ENV.fetch('TMPDIR')) do |dir|
  chart = File.join(dir, 'gateway.tgz')
  run('curl', '-fsSL', "#{source['repoURL']}/gateway-1.31.1.tgz", '-o', chart)
  check(Digest::SHA256.file(chart).hexdigest == 'bfeb6ecf73586e6992c038daae518d11795e932a7c2d034f6e16c7e60638757e', 'published chart archive changed')
  template = lambda do |application|
    helm = application.dig('spec', 'source', 'helm')
    run('helm', 'template', helm['releaseName'], chart, '--namespace', application.dig('spec', 'destination', 'namespace'), '--kube-version', '1.36.5', '-f', '-', input: helm['valuesObject'].to_yaml)
  end
  gateway = YAML.load_stream(template.call(app)).compact
  service = one(gateway, 'Service')['spec']
  deployment = one(gateway, 'Deployment')['spec']
  selector = { 'app' => 'istio-egress', 'istio' => 'egress' }
  check(service['type'] == 'ClusterIP' && !service['externalIPs'], 'gateway must be internal')
  check(service['selector'] == selector && deployment.dig('selector', 'matchLabels') == selector, 'gateway selectors')
  check(selector.all? { |k, v| deployment.dig('template', 'metadata', 'labels', k) == v }, 'gateway pod labels')
  check(service['ports'].map { |p| [p['port'], p['targetPort'], p['nodePort']] }.sort == [[443, 443, nil], [15021, 15021, nil]], 'gateway exposed ports/targetPorts')
  check(deployment['replicas'] == 1 && gateway.none? { |d| d['kind'] == 'HorizontalPodAutoscaler' }, 'single gateway replica')
  annotations = deployment.dig('template', 'metadata', 'annotations')
  check(annotations['inject.istio.io/templates'] == 'gateway' && annotations['sidecar.istio.io/inject'] == 'true', 'gateway object injection')
  check(annotations['sidecar.istio.io/proxyImage'] == 'docker.io/istio/proxyv2:1.31.1@sha256:d86cba0dd1eb15c00b6901c69ce5ae3d2d5f8427a47751098cf8c3ab2a4a62e9', 'gateway image digest')
  ingress_path = 'infra/istio-ingress/application.yaml'
  before = run('git', 'show', "d05bc6b:#{ingress_path}")
  check(before == File.read(ingress_path), 'existing ingress declaration changed')
  check(template.call(YAML.load(before)) == template.call(YAML.load_file(ingress_path)), 'existing ingress render changed')
end

origin = YAML.load_stream(run('kubectl', 'kustomize', 'crossplane/03-istio-secure-egress/origin'))
check(origin.map { |d| d['kind'] }.sort == %w[Certificate ConfigMap Deployment Service], 'origin resource ownership')
check(origin.all? { |d| d.dig('metadata', 'namespace') == 'secure-egress-origin' }, 'origin namespace')
deployment = one(origin, 'Deployment')['spec']
pod = deployment.dig('template', 'spec')
service = one(origin, 'Service')
fqdn = "#{pod['hostname']}.#{pod['subdomain']}.secure-egress-origin.svc.cluster.local"
check(fqdn == 'origin.origin-headless.secure-egress-origin.svc.cluster.local', 'origin DNS identity')
check(deployment['replicas'] == 1 && deployment.dig('strategy', 'type') == 'Recreate', 'single stable origin hostname')
check(service.dig('metadata', 'name') == pod['subdomain'] && service.dig('spec', 'clusterIP') == 'None', 'headless service')
check(service.dig('spec', 'selector') == deployment.dig('selector', 'matchLabels') && service.dig('spec', 'selector') == deployment.dig('template', 'metadata', 'labels'), 'origin selectors')
check(service.dig('spec', 'ports').map { |p| [p['port'], p['targetPort']] } == [[443, 443]], 'headless TLS port')
check(pod['containers'].size == 1 && pod['containers'][0]['image'] == 'docker.io/library/nginx:1.28.3-alpine@sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236', 'origin image pin')
certificate = one(origin, 'Certificate')['spec']
check(certificate['dnsNames'] == [fqdn] && certificate['issuerRef'] == { 'group' => 'cert-manager.io', 'kind' => 'ClusterIssuer', 'name' => 'selfsigned-ca' }, 'origin certificate identity/issuer')
check(pod['volumes'].find { |v| v['name'] == 'tls' }.dig('secret', 'secretName') == certificate['secretName'], 'server secret mount')
config = one(origin, 'ConfigMap')['data']['default.conf']
check(config.include?('listen 443 ssl;') && config.include?("server_name #{fqdn};") && config.include?('ssl_certificate /etc/nginx/tls/tls.crt;') && config.include?('ssl_certificate_key /etc/nginx/tls/tls.key;'), 'nginx TLS listener and certificate paths')
check(pod['containers'][0]['volumeMounts'].any? { |m| m['name'] == 'tls' && m['mountPath'] == '/etc/nginx/tls' && m['readOnly'] }, 'TLS mount path')
puts 'PASS: platform renders, chart checksum, gateway injection/ports/selectors/pins, origin DNS/TLS contract, unchanged ingress render'
