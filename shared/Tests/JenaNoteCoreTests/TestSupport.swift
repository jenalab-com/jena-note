import Foundation

/// The writer tests check their output with a real unzip.
#if os(Windows)
let unzipExecutableURL = URL(fileURLWithPath: "C:/Program Files/Git/usr/bin/unzip.exe")
#else
let unzipExecutableURL = URL(fileURLWithPath: "/usr/bin/unzip")
#endif
