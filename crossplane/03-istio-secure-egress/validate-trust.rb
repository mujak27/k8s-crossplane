# Run from the repository root; never reads live Secrets or private PEM.
require 'yaml'
require 'open3'

def render(path)
  out, err, status = Open3.capture3('kubectl', 'kustomize', path)
  abort "render failed: #{path}: #{err}" unless status.success?
  YAML.load_stream(out).compact
end

def check(condition, message)
  abort message unless condition
end

docs = render('crossplane/03-istio-secure-egress/upstream')
check(docs.size == 1, 'upstream must own exactly one resource')
rule = docs.first
check(rule['apiVersion'] == 'networking.istio.io/v1' && rule['kind'] == 'DestinationRule', 'native DestinationRule required')
check(rule['metadata'] == { 'name' => 'secure-egress-origin-tls', 'namespace' => 'istio-egress' }, 'rule ownership')
spec = rule['spec']
host = 'origin.origin-headless.secure-egress-origin.svc.cluster.local'
certificate = render('crossplane/03-istio-secure-egress/origin').find { |d| d['kind'] == 'Certificate' }
check(certificate.dig('spec', 'dnsNames') == [host], 'origin SAN agreement')
check(spec['host'] == host && spec['exportTo'] == ['.'], 'host/local export')
labels = YAML.load_file('infra/istio-egress/application.yaml').dig('spec', 'source', 'helm', 'valuesObject', 'labels')
check(spec['workloadSelector'] == { 'matchLabels' => labels }, 'exact gateway selector')
check(spec['trafficPolicy'] == {
  'portLevelSettings' => [{
    'port' => { 'number' => 443 },
    'tls' => {
      'mode' => 'SIMPLE', 'credentialName' => 'secure-egress-origin-ca',
      'sni' => host, 'subjectAltNames' => [host], 'insecureSkipVerify' => false
    }
  }]
}, 'verified TLS contract')
check(!File.read('crossplane/03-istio-secure-egress/upstream/destinationrule.yaml').include?('-----BEGIN'), 'no public PEM')
puts 'PASS: upstream ownership, exact gateway selector, origin SAN/SNI, CA credential, port 443, SIMPLE, verification, local export'
