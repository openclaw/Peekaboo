#!/usr/bin/env ruby

require 'fiddle/import'

module DarwinRename
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)
  extern 'int renamex_np(const char *, const char *, unsigned int)'
end

RENAME_EXCL = 0x00000004

def fail!(message)
  warn("atomic-rename-exclusive: #{message}")
  exit(1)
end

fail!('expected SOURCE DESTINATION') unless ARGV.length == 2
source, destination = ARGV.map { |value| File.expand_path(value) }
fail!('paths must be absolute and normalized') unless ARGV == [source, destination]
fail!('source and destination must be siblings') unless File.dirname(source) == File.dirname(destination)

begin
  source_info = File.lstat(source)
rescue Errno::ENOENT
  fail!('source does not exist')
end
fail!('source must not be a symlink') if source_info.symlink?
fail!('source must be a regular file or directory') unless source_info.file? || source_info.directory?
fail!('source must be owned by the current user') unless source_info.uid == Process.euid
fail!('source must be owner-private') unless (source_info.mode & 0o077).zero?
fail!('source file must have one link') if source_info.file? && source_info.nlink != 1

begin
  File.lstat(destination)
  fail!('destination already exists')
rescue Errno::ENOENT
  # Required: renamex_np(RENAME_EXCL) closes the race after this diagnostic check.
end

result = DarwinRename.renamex_np(source, destination, RENAME_EXCL)
unless result.zero?
  error = Fiddle.last_error
  fail!(error == Errno::EEXIST::Errno ? 'destination already exists' : "renamex_np failed with errno #{error}")
end

begin
  File.open(File.dirname(destination), File::RDONLY) { |directory| directory.fsync }
rescue SystemCallError
  fail!('destination published but parent directory fsync failed')
end
