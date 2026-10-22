# Run from the public repository root; optionally pass the private task worktree.
# Reads Application declarations only, never Secret contents. No live API calls.
require 'yaml'
require 'open3'

def git(repo, *args)
  out, err, status = Open3.capture3('git', '-C', repo, *args)
  abort "git failed: #{err}" unless status.success?
  out
end

def check(condition, message)
  abort message unless condition
end

retry_policy = { 'limit' => -1, 'backoff' => { 'duration' => '5s', 'factor' => 2, 'maxDuration' => '3m' } }
repos = [['.', '9e82a4976d523f747005d0361402c128fa0fb465', 13, 24]]
repos << [ARGV.fetch(0), '942950ecf6bacc78dd0005b52156567f3902e07a', 1, 2] unless ARGV.empty?
newly_automated = 0
repos.each do |repo, base, expected_new, expected_total|
  paths = git(repo, 'grep', '-l', '-E', '^kind: Application(Set)?$', '--', '*.yaml').lines.map(&:strip)
  changed_yaml = git(repo, 'diff', '--name-only', base, '--', '*.yaml', '*.yml').lines.map(&:strip)
  check((changed_yaml - paths).empty?, "non-Application resource changed: #{repo}")
  total = added = 0
  paths.each do |path|
    doc = YAML.load_file(File.join(repo, path))
    before = YAML.load(git(repo, 'show', "#{base}:#{path}"))
    is_set = doc['kind'] == 'ApplicationSet'
    count = is_set ? doc.dig('spec', 'generators').sum { |g| g.fetch('list').fetch('elements').size } : 1
    total += count
    check(!doc.dig('metadata', 'finalizers'), "finalizer: #{path}")
    if is_set
      check(!doc.dig('spec', 'strategy') || doc.dig('spec', 'strategy', 'type') == 'AllAtOnce', "non-automated strategy: #{path}")
      check(doc.dig('spec', 'syncPolicy', 'preserveResourcesOnDeletion') == true, "preservation: #{path}")
      check(!doc.dig('spec', 'template', 'metadata', 'finalizers'), "child finalizer: #{path}")
    end
    spec = is_set ? doc.dig('spec', 'template', 'spec') : doc['spec']
    old_spec = is_set ? before.dig('spec', 'template', 'spec') : before['spec']
    automated = spec.dig('syncPolicy', 'automated')
    check(automated.is_a?(Hash) && automated['enabled'] != false && !automated['prune'], "automation/pruning: #{path}")
    unless old_spec.dig('syncPolicy', 'automated')
      added += count
      check(automated == { 'prune' => false, 'selfHeal' => true }, "new automation policy: #{path}")
      check(spec.dig('syncPolicy', 'retry') == retry_policy, "prerequisite retry: #{path}")
      spec['syncPolicy'].delete('automated')
      spec['syncPolicy'].delete('retry')
      doc['spec']['strategy'] = before.dig('spec', 'strategy') if is_set
    end
    check(doc == before, "non-policy declaration changed: #{path}")
  end
  check(added == expected_new && total == expected_total, "inventory mismatch: #{repo}: #{added} newly automated / #{total} total")
  newly_automated += added
  puts "PASS: #{repo}: #{added} newly automated / #{total} declared Applications; only intended policies changed"
end
check(newly_automated == (ARGV.empty? ? 13 : 14), 'expected 14 newly automated across both repositories')
