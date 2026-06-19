import Foundation

enum ConnectivityError {
    private static let connectivityURLErrorCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .dataNotAllowed,
        .internationalRoamingOff,
    ]

    static func isConnectivityFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return connectivityURLErrorCodes.contains(urlError.code)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           connectivityURLErrorCodes.contains(URLError.Code(rawValue: nsError.code)) {
            return true
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           !(underlying as NSError).isEqual(nsError),
           isConnectivityFailure(underlying) {
            return true
        }

        return false
    }
}
