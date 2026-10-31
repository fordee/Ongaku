//
//  PersonalFiles.swift
//  OngakuTests
//

import Foundation

/// The user's real home folder, not the sandbox container `NSHomeDirectory()` returns. Tests of
/// files that live only on one person's Mac look for them here, and skip when they're missing.
let realHomeDirectory = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) }
  ?? URL(fileURLWithPath: NSHomeDirectory())
