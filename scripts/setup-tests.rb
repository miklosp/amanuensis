#!/usr/bin/env ruby
# Idempotently ensures the `audio-pipelineTests` Swift Testing unit-test target
# exists and that every .swift file under audio-pipelineTests/ belongs to it.
# Also writes a shared `audio-pipeline` scheme whose Test action runs the suite.
#
# Run from the repo root, via scripts/run-setup-tests.sh.

require 'xcodeproj'

PROJECT_PATH = 'audio-pipeline.xcodeproj'
APP_TARGET   = 'audio-pipeline'
TEST_TARGET  = 'audio-pipelineTests'
TEST_DIR     = 'audio-pipelineTests'

project = Xcodeproj::Project.open(PROJECT_PATH)

app = project.targets.find { |t| t.name == APP_TARGET }
raise "app target '#{APP_TARGET}' not found" unless app

app_debug  = app.build_configurations.find { |c| c.name == 'Debug' }
deployment = app_debug.build_settings['MACOSX_DEPLOYMENT_TARGET'] || '26.3'
swift_ver  = app_debug.build_settings['SWIFT_VERSION'] || '5.0'

# @testable import requires the app module to be built testable in Debug.
app.build_configurations.each do |config|
  config.build_settings['ENABLE_TESTABILITY'] ||= 'YES'
end

test_target = project.targets.find { |t| t.name == TEST_TARGET }

if test_target.nil?
  test_target = project.new_target(:unit_test_bundle, TEST_TARGET, :osx, deployment, nil, :swift)
  test_target.add_dependency(app)

  test_target.build_configurations.each do |config|
    s = config.build_settings
    s['PRODUCT_BUNDLE_IDENTIFIER']     = 'work.miklos.audio-pipeline.tests'
    s['PRODUCT_NAME']                  = '$(TARGET_NAME)'
    s['SWIFT_VERSION']                 = swift_ver
    s['SWIFT_DEFAULT_ACTOR_ISOLATION'] = 'MainActor'
    s['MACOSX_DEPLOYMENT_TARGET']      = deployment
    s['GENERATE_INFOPLIST_FILE']       = 'YES'
    s['TEST_HOST']     = '$(BUILT_PRODUCTS_DIR)/audio-pipeline.app/Contents/MacOS/audio-pipeline'
    s['BUNDLE_LOADER'] = '$(TEST_HOST)'
    s['CODE_SIGN_STYLE'] = 'Automatic'
  end
  puts "created target #{TEST_TARGET}"
else
  puts "target #{TEST_TARGET} already exists"
end

# --- sync test source files into the target ---------------------------------
group = project.main_group.find_subpath(TEST_DIR, true)
group.set_source_tree('SOURCE_ROOT')
group.set_path(TEST_DIR)

phase    = test_target.source_build_phase
existing = phase.files_references.compact.map { |r| r.real_path.to_s }

Dir.glob("#{TEST_DIR}/**/*.swift").sort.each do |rel_path|
  abs = File.expand_path(rel_path)
  next if existing.include?(abs)
  ref = project.reference_for_path(abs) || group.new_file(abs)
  phase.add_file_reference(ref, true)
  puts "added #{rel_path}"
end

# --- shared scheme ----------------------------------------------------------
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(test_target)
scheme.set_launch_target(app)
scheme.save_as(PROJECT_PATH, APP_TARGET, true)
puts "wrote shared scheme #{APP_TARGET}"

project.save
puts "saved #{PROJECT_PATH}"
