#!/usr/bin/env ruby
# Patches WebDriverAgent.xcodeproj to include FBMediaCommands and Photos.framework
require 'xcodeproj'

project_path = ARGV[0] || 'WebDriverAgent.xcodeproj'
project = Xcodeproj::Project.open(project_path)

lib_target = project.targets.find { |t| t.name == 'WebDriverAgentLib' }
raise "WebDriverAgentLib target not found" unless lib_target

commands_group = project.main_group
  .recursive_children
  .find { |g| g.respond_to?(:path) && g.path == 'Commands' && g.parent.path == 'WebDriverAgentLib' }

unless commands_group
  wda_lib_group = project.main_group.recursive_children.find { |g|
    g.respond_to?(:path) && g.path == 'WebDriverAgentLib'
  }
  raise "WebDriverAgentLib group not found" unless wda_lib_group
  commands_group = wda_lib_group.children.find { |g| g.respond_to?(:name) && (g.name == 'Commands' || g.path&.end_with?('Commands')) }
  raise "Commands group not found" unless commands_group
end

puts "Found Commands group: #{commands_group.real_path}"

%w[FBMediaCommands.h FBMediaCommands.m].each do |fname|
  existing = commands_group.files.find { |f| f.name == fname || f.path&.end_with?(fname) }
  if existing
    puts "#{fname} already in project, skipping"
    next
  end
  ref = commands_group.new_file(fname)
  if fname.end_with?('.m')
    lib_target.source_build_phase.add_file_reference(ref)
    puts "Added #{fname} to compile sources"
  else
    puts "Added #{fname} as header"
  end
end

# Add Photos.framework
existing_photos = lib_target.frameworks_build_phase.files.find { |f|
  f.display_name == 'Photos.framework'
}
unless existing_photos
  lib_target.add_system_framework('Photos')
  puts "Linked Photos.framework"
else
  puts "Photos.framework already linked"
end

project.save
puts "Project saved"
