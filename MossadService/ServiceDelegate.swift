// MossadService/ServiceDelegate.swift
import Foundation
import MossadShared

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let exportedInterface = NSXPCInterface(with: MossadServiceProtocol.self)
        newConnection.exportedInterface = exportedInterface

        let remoteInterface = NSXPCInterface(with: MossadAppProtocol.self)
        newConnection.remoteObjectInterface = remoteInterface

        let serviceImpl = MossadServiceImpl()
        serviceImpl.appProxy = newConnection.remoteObjectProxy as? MossadAppProtocol
        newConnection.exportedObject = serviceImpl

        newConnection.invalidationHandler = {
            serviceImpl.appProxy = nil
        }

        newConnection.resume()
        return true
    }
}
