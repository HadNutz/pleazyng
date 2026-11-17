require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'xcodeproj'

class TvOSPluginWiringTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def test_rewiring_preserves_package_link_and_embed_entries_and_removes_orphans
    Dir.mktmpdir('pleazyng-tvos-wiring-') do |scratch|
      tvos = File.join(scratch, 'tvos')
      project_path = File.join(tvos, 'Runner.xcodeproj')
      FileUtils.mkdir_p([project_path, File.join(tvos, 'scripts')])
      FileUtils.cp(File.join(ROOT, 'tvos/Runner.xcodeproj/project.pbxproj'), project_path)
      script = File.join(tvos, 'scripts/wire_plugins.rb')
      FileUtils.cp(ENV.fetch('PLEAZYNG_WIRING_SCRIPT', File.join(ROOT, 'tvos/scripts/wire_plugins.rb')), script)
      project = Xcodeproj::Project.open(project_path)
      runner = project.targets.find { |t| t.name == 'Runner' }
      linked = runner.frameworks_build_phase.files.find { |b| b.product_ref&.product_name == 'AMSMB2' }
      embed_phase = runner.copy_files_build_phases.find { |p| p.name == 'Embed Frameworks' }
      embedded = embed_phase.files.find { |b| b.product_ref&.product_name == 'AMSMB2' }
      refute_nil linked
      refute_nil embedded
      assert_nil linked.file_ref
      assert_nil embedded.file_ref
      package_ids = [linked.uuid, embedded.uuid]
      orphan_ids = [runner.frameworks_build_phase, embed_phase].map do |phase|
        orphan = project.new(Xcodeproj::Project::Object::PBXBuildFile)
        phase.files << orphan
        orphan.uuid
      end
      stale = project.main_group['Runner'].new_file('SiriRemoteDpadBridge.swift')
      runner.source_build_phase.add_file_reference(stale)
      project.save
      2.times do
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, script)
        assert status.success?, "#{stdout}\n#{stderr}"
        updated = Xcodeproj::Project.open(project_path)
        target = updated.targets.find { |t| t.name == 'Runner' }
        build_files = target.build_phases.select { |p| p.respond_to?(:files) }.flat_map(&:files)
        assert_equal package_ids.sort, build_files.select { |b| b.product_ref&.product_name == 'AMSMB2' }.map(&:uuid).sort
        assert_empty build_files.select { |b| orphan_ids.include?(b.uuid) }
        assert_empty updated.files.select { |f| f.display_name == 'SiriRemoteDpadBridge.swift' }
        embedded = build_files.find { |b| b.uuid == package_ids.last }
        assert_includes embedded.settings['ATTRIBUTES'], 'CodeSignOnCopy'
        assert_includes embedded.settings['ATTRIBUTES'], 'RemoveHeadersOnCopy'
        assert updated.files.any? { |f| f.display_name == 'AppDelegate.swift' }
      end
    end
  end
end
