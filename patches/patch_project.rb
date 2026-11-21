#!/usr/bin/env ruby
require 'xcodeproj'

project_path = ARGV[0] || 'WebDriverAgent.xcodeproj'
project = Xcodeproj::Project.open(project_path)

lib_target = project.targets.find { |t| t.name == 'WebDriverAgentLib' }
raise "WebDriverAgentLib target not found" unless lib_target
puts "Target: #{lib_target.name}"

commands_group = nil
project.main_group.recursive_children.each do |g|
  next unless g.respond_to?(:children)
  gname = g.respond_to?(:name) ? g.name : nil
  gpath = g.respond_to?(:path) ? g.path : nil
  next unless gname == 'Commands' || (gpath && gpath.end_with?('Commands'))
  commands_group = g
  puts "Found Commands group: name=#{gname} path=#{gpath}"
  break
end

unless commands_group
  puts "DEBUG: all groups in project:"
  project.main_group.recursive_children.each do |g|
    next unless g.respond_to?(:children)
    gn = g.respond_to?(:name) ? g.name : nil
    gp = g.respond_to?(:path) ? g.path : nil
    puts "  #{gn || '(nil)'} | #{gp || '(nil)'}"
  end
  raise "Commands group not found"
end

%w[FBMediaCommands.h FBMediaCommands.m].each do |fname|
  existing = commands_group.files.find { |f|
    fn = f.respond_to?(:name) ? f.name : nil
    fp = f.respond_to?(:path) ? f.path : nil
    fn == fname || (fp && fp.end_with?(fname))
  }
  if existing
    puts "#{fname} already in project"
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
