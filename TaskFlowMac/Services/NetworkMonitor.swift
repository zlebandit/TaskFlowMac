//
//  NetworkMonitor.swift
//  TaskFlowMac
//
//  Surveille l'état de la connexion réseau en temps réel
//  via NWPathMonitor (framework Network).
//  Cohérent avec les implémentations iPhone et Watch.
//
//  Fonctionnalités :
//    - Détection connecté/hors ligne
//    - Type de connexion (wifi, filaire, unknown)
//    - Callback onNetworkRestored pour auto-retry des uploads pending
//

import Foundation
import Network
import Observation

@Observable
final class NetworkMonitor {
    
    static let shared = NetworkMonitor()
    
    /// true = connecté, false = hors ligne
    var isConnected: Bool = true
    
    /// Type de connexion actuel
    var connectionType: ConnectionType = .unknown
    
    /// Callback déclenché quand le réseau passe de offline → online
    /// Utilisé pour auto-retry des uploads pending
    var onNetworkRestored: (() -> Void)?
    
    enum ConnectionType {
        case wifi
        case wired
        case unknown
    }
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor", qos: .utility)
    private var wasDisconnected = false
    
    private init() {
        startMonitoring()
    }
    
    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = (path.status == .satisfied)
            let type = self.getConnectionType(path)
            
            DispatchQueue.main.async {
                let previouslyDisconnected = self.wasDisconnected
                self.isConnected = connected
                self.connectionType = type
                
                if !connected {
                    self.wasDisconnected = true
                    print("[Network] ❌ Connexion perdue")
                } else if previouslyDisconnected {
                    self.wasDisconnected = false
                    print("[Network] ✅ Connexion rétablie (\(type))")
                    self.onNetworkRestored?()
                }
            }
        }
        monitor.start(queue: queue)
        print("[Network] Monitoring démarré")
    }
    
    private func getConnectionType(_ path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .unknown
    }
    
    deinit {
        monitor.cancel()
    }
}
