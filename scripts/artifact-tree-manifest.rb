#!/usr/bin/ruby

require 'digest'
require 'json'

abort('Usage: scripts/artifact-tree-manifest.rb PATH') unless ARGV.length == 1
root = File.expand_path(ARGV.fetch(0))
root_metadata = File.lstat(root)
abort('Artifact root must be an unsymlinked directory') unless root_metadata.directory? && !root_metadata.symlink?
entries = []

visit = lambda do |absolute, relative|
  metadata = File.lstat(absolute)
  display = relative.empty? ? '.' : relative
  mode = format('%04o', metadata.mode & 0o7777)
  if metadata.symlink?
    target = File.readlink(absolute)
    resolved_target = File.expand_path(target, File.dirname(absolute))
    unless resolved_target == root || resolved_target.start_with?("#{root}/")
      abort("Artifact symlink escapes root: #{display} -> #{target}")
    end
    entries << { path: display, type: 'symlink', mode: mode, target: target }
  elsif metadata.directory?
    entries << { path: display, type: 'directory', mode: mode }
    Dir.children(absolute).sort { |left, right| left.b <=> right.b }.each do |name|
      child_relative = relative.empty? ? name : "#{relative}/#{name}"
      visit.call(File.join(absolute, name), child_relative)
    end
  elsif metadata.file?
    entries << {
      path: display,
      type: 'file',
      mode: mode,
      size: metadata.size,
      sha256: Digest::SHA256.file(absolute).hexdigest
    }
  else
    abort("Unsupported artifact entry type: #{display}")
  end
end

visit.call(root, '')
STDOUT.write(JSON.generate({ version: 1, entries: entries }) + "\n")
