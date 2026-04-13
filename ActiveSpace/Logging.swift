import Foundation

private let logFile: FileHandle? = {
    let path = "/tmp/activespace.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

func aslog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    logFile?.seekToEndOfFile()
    logFile?.write(line.data(using: .utf8)!)
}

/// C-callable bridge so VirtualDisplayHelper.m can write to the same file.
@_cdecl("ActiveSpaceLogC")
public func ActiveSpaceLogC(_ cstr: UnsafePointer<CChar>) {
    aslog(String(cString: cstr))
}
