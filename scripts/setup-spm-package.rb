#!/usr/bin/env ruby
# Idempotently:
#   (1) ensures Packages/AudioPipeline is registered as a local SPM package
#       reference on Amanuensis.xcodeproj;
#   (2) ensures the named library product is linked into the `Amanuensis`
#       app target's package_product_dependencies and Frameworks build phase.
#
# Usage: ruby scripts/setup-spm-package.rb <ProductName>
# Wrap via scripts/run-setup-spm-package.sh from the repo root.

require 'xcodeproj'

PROJECT_PATH = 'Amanuensis.xcodeproj'
APP_TARGET   = 'Amanuensis'
PACKAGE_PATH = 'Packages/AudioPipeline'

product = ARGV.first
raise "usage: setup-spm-package.rb <ProductName>" if product.nil? || product.empty?

project = Xcodeproj::Project.open(PROJECT_PATH)
app = project.targets.find { |t| t.name == APP_TARGET }
raise "app target '#{APP_TARGET}' not found" unless app

# --- (1) Ensure the local package reference exists on the project. ---
package_ref = project.root_object.package_references.find do |ref|
  ref.is_a?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference) &&
    ref.relative_path == PACKAGE_PATH
end

if package_ref.nil?
  package_ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  package_ref.relative_path = PACKAGE_PATH
  project.root_object.package_references << package_ref
  puts "added local package reference #{PACKAGE_PATH}"
else
  puts "local package #{PACKAGE_PATH} already registered"
end

# --- (2a) Ensure the product dependency exists on the target ---
product_dep = app.package_product_dependencies.find { |d| d.product_name == product }
if product_dep.nil?
  product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product_dep.product_name = product
  app.package_product_dependencies << product_dep
  puts "added product dependency #{product} to #{APP_TARGET}"
else
  puts "product dependency #{product} already present on #{APP_TARGET}"
end

# --- (2b) Ensure the Frameworks build phase links the product ---
linked = app.frameworks_build_phase.files.any? { |bf| bf.product_ref == product_dep }
if !linked
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product_dep
  app.frameworks_build_phase.files << build_file
  puts "linked #{product} in #{APP_TARGET} Frameworks phase"
else
  puts "#{product} already linked in #{APP_TARGET} Frameworks phase"
end

project.save
puts "saved #{PROJECT_PATH}"
