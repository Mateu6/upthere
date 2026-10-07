// Debug helper: swift scripts/debug-notch.swift <mode> [snapshot-dir]
import Foundation
let args = CommandLine.arguments
var info: [String: String] = ["mode": args.count > 1 ? args[1] : "collapsed"]
if args.count > 2 { info["snapshot"] = args[2] }
DistributedNotificationCenter.default().postNotificationName(
    .init("dev.upthere.debug"), object: nil, userInfo: info, deliverImmediately: true)
