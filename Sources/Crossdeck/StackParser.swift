// Swift stack-trace normaliser.
//
// `Thread.callStackSymbols` returns raw entries that look like:
//
//   "5   CrossdeckTests   0x000000010fab12cd $s14CrossdeckTes…"
//
// That's mangled Swift symbols inside `_$s…` prefix, plus a frame
// number + module + address. For the server-side error grouper to
// fingerprint correctly, we strip the addresses (which differ
// across launches due to ASLR) and produce a stable shape:
//
//   "<module> <demangled-symbol-or-mangled>"
//
// We do NOT demangle here — `swift_demangle` is not on the public
// platform surface and pulling it in via dlsym would make the SDK
// brittle. Server-side has the toolchain available; mangled names
// are stable enough to fingerprint.

import Foundation

public struct ParsedStackFrame: Sendable, Codable {
    public let module: String
    public let symbol: String
    public let frameNumber: Int

    public init(module: String, symbol: String, frameNumber: Int) {
        self.module = module
        self.symbol = symbol
        self.frameNumber = frameNumber
    }
}

/// Parse `Thread.callStackSymbols`-style strings into a stable
/// shape suitable for fingerprinting. Skips any lines we can't
/// parse so a single malformed frame doesn't drop the whole trace.
public func parseStackSymbols(_ symbols: [String]) -> [ParsedStackFrame] {
    return symbols.compactMap(parseFrame)
}

/// Build a fingerprint string from a stack trace. Format mirrors
/// the web/RN SDKs: top-N frames concatenated, so the server-side
/// grouper can hash on the same shape regardless of platform.
public func fingerprintFromStack(_ symbols: [String], depth: Int = 5) -> String {
    let frames = parseStackSymbols(symbols).prefix(depth)
    return frames.map { "\($0.module):\($0.symbol)" }.joined(separator: "|")
}

private func parseFrame(_ raw: String) -> ParsedStackFrame? {
    // Typical format (whitespace-separated):
    //   "<frame>   <module>   <address>   <symbol> + <offset>"
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }

    // Split on whitespace, but cap to 4 components so the symbol
    // (which may contain spaces inside angle brackets) stays intact.
    let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
    guard parts.count >= 4 else { return nil }

    guard let frameNo = Int(parts[0]) else { return nil }
    let module = String(parts[1])
    let rest = String(parts[3])

    // Strip address prefix if present (parts[2] is the address;
    // rest starts at the symbol).
    let symbol = rest
        .replacingOccurrences(of: #"\s+\+\s+\d+$"#, with: "", options: .regularExpression)

    return ParsedStackFrame(module: module, symbol: symbol, frameNumber: frameNo)
}
