import Darwin
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("atomic-publish-no-replace: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else { fail("expected SOURCE DESTINATION") }
let source = arguments[0]
let destination = arguments[1]
guard source.hasPrefix("/"), destination.hasPrefix("/"),
      URL(fileURLWithPath: source).deletingLastPathComponent().path
      == URL(fileURLWithPath: destination).deletingLastPathComponent().path
else { fail("source and destination must be absolute siblings") }

var sourceInfo = stat()
guard lstat(source, &sourceInfo) == 0,
      (sourceInfo.st_mode & S_IFMT) == S_IFREG,
      sourceInfo.st_nlink == 1,
      (sourceInfo.st_mode & 0o077) == 0,
      sourceInfo.st_uid == geteuid()
else { fail("source is not one owner-private regular file") }

var destinationInfo = stat()
guard lstat(destination, &destinationInfo) != 0, errno == ENOENT else {
    fail("destination already exists")
}

let result = source.withCString { sourcePointer in
    destination.withCString { destinationPointer in
        renameatx_np(AT_FDCWD, sourcePointer, AT_FDCWD, destinationPointer, UInt32(RENAME_EXCL))
    }
}

guard result == 0 else {
    fail(errno == EEXIST ? "destination already exists" : "renameatx_np failed with errno \(errno)")
}

let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
let directoryDescriptor = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
if directoryDescriptor >= 0 {
    _ = fsync(directoryDescriptor)
    close(directoryDescriptor)
}
