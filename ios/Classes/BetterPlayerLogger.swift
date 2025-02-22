//
//  BetterPlayerLogger.swift
//  better_player
//
//  Created by Vadim Melnikov on 09.08.2023.
//

import Foundation

@objc public class BetterPlayerLogger: NSObject {
    @objc public static var isEnabled = true
    @objc public static var onLogged: (_ message: String) -> Void = {message in }
    
    @objc public static func log(_ message: String) {
        log(message, method: "", force: false)
    }
    
    @objc public static func log(_ message: String, force forceLog: Bool = false) {
        log(message, method: "", force: forceLog)
    }
    
    @objc public static func log(_ message: String, method: String = "") {
        log(message, method: method, force: false)
    }
    
    @objc public static func log(_ message: String, method: String = "", force forceLog: Bool = false) {
        onLogged(message)
        if (!isEnabled && !forceLog) { return }
        
        let method = method.isEmpty ? "" : ("." + method)
        let message = "[BetterPlayer" + method + "]: " + message
        
        NSLog(message);
    }
}
