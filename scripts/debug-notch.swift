// Debug helper: swift scripts/debug-notch.swift <mode> [snapshot-dir] [delay-ms]
import Foundation
let args = CommandLine.arguments
var info: [String: String] = ["mode": args.count > 1 ? args[1] : "collapsed"]
if args.count > 2 { info["snapshot"] = args[2] }
if args.count > 3 { info["delay"] = args[3] }  // ms before capturing
DistributedNotificationCenter.default().postNotificationName(
    .init("dev.upthere.debug"), object: nil, userInfo: info, deliverImmediately: true)
