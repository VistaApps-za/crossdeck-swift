// PerformanceVitals — MetricKit integration.
//
// Mirrors Web SDK's web-vitals.ts: emit one event per performance
// signal so dashboards can surface "this build hangs", "this build
// cold-launches in 3.4s up from 1.2s last week", "this build hits CPU
// exception N times per session". Bank-grade product telemetry —
// engineers see regressions before customers file tickets.
//
// MetricKit deliver model:
//   * `MXMetricManager` aggregates 24h of device-level metrics and
//     ships them once a day to subscribed apps. Cold launch, hang
//     count, CPU time, memory peaks all land here.
//   * `didReceive(_ diagnostics: [MXDiagnosticPayload])` fires for
//     near-real-time crash / hang / CPU-exception / disk-write
//     diagnostics — typically within minutes of the incident.
//
// Bank-grade contract:
//   * iOS 14+ only (MetricKit was iOS 13 but the Swift API matured
//     in iOS 14). Older targets get nothing — the SDK still functions,
//     just no perf signal.
//   * Strict opt-in via `CrossdeckOptions(performanceMonitoring: true)`.
//     OFF by default because MetricKit's daily payload can be large
//     and the SDK is conservative about background activity.

import Foundation

#if canImport(MetricKit) && !os(watchOS) && !os(tvOS)
import MetricKit

@available(iOS 14.0, macOS 12.0, *)
final class PerformanceVitals: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let emit: @Sendable (_ name: String, _ properties: [String: Any]) -> Void
    private let lock = NSLock()
    private var subscribed = false

    init(emit: @escaping @Sendable (_ name: String, _ properties: [String: Any]) -> Void) {
        self.emit = emit
        super.init()
    }

    func start() {
        lock.lock()
        guard !subscribed else { lock.unlock(); return }
        subscribed = true
        lock.unlock()
        MXMetricManager.shared.add(self)
    }

    func stop() {
        lock.lock()
        guard subscribed else { lock.unlock(); return }
        subscribed = false
        lock.unlock()
        MXMetricManager.shared.remove(self)
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Aggregate 24h metrics — fires roughly once per day per
        // device when the app comes to foreground after a payload
        // window closes.
        for payload in payloads {
            var props: [String: Any] = [
                "timeStampBegin": ISO8601DateFormatter().string(from: payload.timeStampBegin),
                "timeStampEnd": ISO8601DateFormatter().string(from: payload.timeStampEnd),
            ]

            // App launch metrics (cold launch time, resume time).
            if let launch = payload.applicationLaunchMetrics {
                if #available(iOS 15.2, *) {
                    let coldLaunchAvgMs = launch.histogrammedTimeToFirstDraw.totalBucketCount > 0
                        ? Int(launch.histogrammedTimeToFirstDraw.totalBucketCount)
                        : nil
                    if let v = coldLaunchAvgMs { props["coldLaunchSamples"] = v }
                }
                let resumeMs = launch.histogrammedApplicationResumeTime.totalBucketCount
                if resumeMs > 0 { props["resumeSamples"] = Int(resumeMs) }
            }

            // Hang counts (UI blocked >100ms — Apple's threshold).
            if let responsiveness = payload.applicationResponsivenessMetrics {
                let hangSamples = responsiveness.histogrammedApplicationHangTime.totalBucketCount
                if hangSamples > 0 { props["hangSamples"] = Int(hangSamples) }
            }

            // Memory peaks.
            if let memory = payload.memoryMetrics {
                props["peakMemoryMB"] = memory.peakMemoryUsage.converted(to: .megabytes).value
            }

            // CPU time.
            if let cpu = payload.cpuMetrics {
                props["cumulativeCPUSec"] = cpu.cumulativeCPUTime.converted(to: .seconds).value
            }

            emit("perf.metrics", props)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Near-real-time diagnostics: crashes, hangs, CPU exceptions,
        // disk-write exceptions. Each payload type emits as its own
        // event for clean dashboard slicing.
        for payload in payloads {
            // Hang diagnostics — UI blocked long enough that MetricKit
            // captured a stack trace.
            if let hangs = payload.hangDiagnostics {
                for hang in hangs {
                    var props: [String: Any] = [
                        "hangDurationSec": hang.hangDuration.converted(to: .seconds).value,
                    ]
                    if let metadata = encodeMetadata(hang.metaData) {
                        props["metadata"] = metadata
                    }
                    emit("perf.hang", props)
                }
            }

            // CPU-exception diagnostics — sustained CPU spikes that
            // trigger system intervention.
            if let cpuExceptions = payload.cpuExceptionDiagnostics {
                for ex in cpuExceptions {
                    var props: [String: Any] = [
                        "totalCPUTimeSec": ex.totalCPUTime.converted(to: .seconds).value,
                        "totalSampledTimeSec": ex.totalSampledTime.converted(to: .seconds).value,
                    ]
                    if let metadata = encodeMetadata(ex.metaData) {
                        props["metadata"] = metadata
                    }
                    emit("perf.cpu_exception", props)
                }
            }

            // Disk-write exception diagnostics — app wrote enough to
            // disk that iOS flagged it.
            if let diskExceptions = payload.diskWriteExceptionDiagnostics {
                for ex in diskExceptions {
                    var props: [String: Any] = [
                        "totalWritesCausedMB": ex.totalWritesCaused.converted(to: .megabytes).value,
                    ]
                    if let metadata = encodeMetadata(ex.metaData) {
                        props["metadata"] = metadata
                    }
                    emit("perf.disk_write_exception", props)
                }
            }

            // Crash diagnostics — process-fatal exceptions / signals
            // captured by MetricKit's separate pipeline (not the
            // NSSetUncaughtExceptionHandler path).
            if let crashes = payload.crashDiagnostics {
                for crash in crashes {
                    var props: [String: Any] = [:]
                    if let sig = crash.signal { props["signal"] = sig.intValue }
                    if let code = crash.exceptionCode { props["exceptionCode"] = code.intValue }
                    if let type = crash.exceptionType { props["exceptionType"] = type.intValue }
                    if let reason = crash.terminationReason {
                        props["terminationReason"] = reason
                    }
                    if let metadata = encodeMetadata(crash.metaData) {
                        props["metadata"] = metadata
                    }
                    emit("perf.crash_diagnostic", props)
                }
            }
        }
    }

    private func encodeMetadata(_ metaData: MXMetaData) -> [String: Any]? {
        // MXMetaData is JSON-encodable but the dictionary representation
        // varies by iOS version. Stringify defensively.
        let data = metaData.jsonRepresentation()
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}
#endif
