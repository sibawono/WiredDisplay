import SwiftUI

/// Phase 0 transport probe. Not the product UI: it exists only to prove that
/// bytes cross the USB-C cable between the Mac and a sandboxed iPad app, and to
/// guide experiment E-05b on the iPad itself (the user's only view of the Mac
/// is Sidecar on this same iPad, so instructions cannot live on the Mac).
@main
struct TransportProbeApp: App {
    private let events: EventLog
    private let server: EchoServer
    private let network: NetworkWatcher
    @State private var finished = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let events = EventLog()
        self.events = events
        server = EchoServer(events: events)
        network = NetworkWatcher(events: events)
        FinishMarker.clear(events: events)
    }

    var body: some Scene {
        WindowGroup {
            ProbeView(server: server, network: network, events: events, finished: $finished)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    events.append("APP scene=\(phase)")
                    // iPadOS suspends the app in the background; the listener
                    // cannot serve there, so do not pretend it can.
                    if phase == .active, !finished {
                        server.start()
                    } else if phase == .background {
                        server.stop(reason: "app in background")
                    }
                    UIApplication.shared.isIdleTimerDisabled = (phase == .active)
                }
        }
    }
}

/// Explicit end-of-test signal for the Mac monitor (review finding 1): the Mac
/// polls for this file over the cable instead of guessing the end from refused
/// connections, which also happen whenever Sidecar takes over the screen.
enum FinishMarker {
    static let fileName = "e05b-finished"

    static var url: URL? { EventLog.documentsURL?.appendingPathComponent(fileName) }

    static func set(events: EventLog) {
        guard let url else { return }
        do {
            try Data("finished \(Date())\nlog \(events.fileName)\n".utf8).write(to: url, options: .atomic)
            events.append("MARKER \(fileName) written")
        } catch {
            events.append("MARKER write failed: \(error)")
        }
    }

    static func clear(events: EventLog) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            events.append("MARKER \(fileName) cleared")
        } catch {
            events.append("MARKER clear failed: \(error)")
        }
    }
}

struct ProbeView: View {
    let server: EchoServer
    let network: NetworkWatcher
    let events: EventLog
    @Binding var finished: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let stats = server.snapshot()
            let net = network.snapshot()
            ScrollView {
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 18) {
                        guide
                        markers
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 14) {
                        liveStatus(stats: stats, net: net, now: context.date)
                        Divider()
                        details(stats: stats)
                        Divider()
                        recentEvents
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(32)
            }
        }
    }

    // MARK: guide (Indonesian: the person running the test reads Indonesian)

    private var guide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("E-05b — uji kabel saja").font(.title2.bold())
            Text("Biarkan aplikasi ini tetap di depan sampai langkah D. Mac menjalankan echo setiap ±2 detik dan mencatat hasilnya. Wi-Fi Mac tetap menyala.")
                .font(.callout).foregroundStyle(.secondary)
            step("A", "Buka app Settings: matikan Wi-Fi (Settings › Wi-Fi) dan Bluetooth (Settings › Bluetooth). Jangan lewat Control Center — itu hanya memutus jaringan, radionya tetap hidup. Kembali ke WD Probe, ketuk “Mulai A”, tunggu ±20 detik: “Wi-Fi iPad terhubung” harus TIDAK dan “Echo terakhir” tetap hijau. (Sidecar tetap jalan lewat kabel.)")
            step("B", "LEWATI — sudah lulus pada 16 Nov 15:19 (cabut kabel dengan Wi-Fi mati memutus Sidecar, jadi tidak diulang).")
            step("C", "Nyalakan lagi Wi-Fi dan Bluetooth di Settings, kembali ke WD Probe, ketuk “Mulai C”, tunggu ±20 detik. Cabut kabel ±20 detik: echo biasa HARUS berhenti walau Wi-Fi menyala. Mac juga mencoba sekali lewat jalur Wi-Fi dengan sengaja (uji pembanding). Colok lagi dan tunggu sampai hijau. (Sidecar pindah ke Wi-Fi, tidak putus.)")
            step("D", "Ketuk “Selesai”, lalu kembali ke Sidecar. Jika Sidecar tidak muncul, tunggu ±30 detik: Mac akan menyambungkannya ulang otomatis.")
        }
    }

    private func step(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.headline.monospaced()).frame(width: 22)
            Text(text).font(.body)
        }
    }

    private var markers: some View {
        HStack(spacing: 12) {
            ForEach(["A", "C"], id: \.self) { phase in
                Button("Mulai \(phase)") { events.append("USER start phase \(phase)") }
                    .buttonStyle(.bordered)
                    .disabled(finished)
            }
            if finished {
                Button("Mulai ulang") {
                    finished = false
                    events.append("USER restart")
                    FinishMarker.clear(events: events)
                    server.start()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Selesai") {
                    finished = true
                    events.append("USER finished E-05b")
                    server.stop(reason: "user finished")
                    FinishMarker.set(events: events)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
    }

    // MARK: live status

    private func liveStatus(stats: EchoStats, net: NetworkStatus, now: Date) -> some View {
        let age = stats.lastEchoAt.map { now.timeIntervalSince($0) }
        let fresh = (age ?? .infinity) < 4
        return VStack(alignment: .leading, spacing: 10) {
            // NWPathMonitor reports whether a usable Wi-Fi path exists, not
            // whether the radio is powered (review finding 8), so say exactly that.
            indicator("Wi-Fi iPad terhubung",
                      net.wifiUsable == nil ? "…" : (net.wifiUsable == true ? "YA" : "TIDAK"),
                      color: net.wifiUsable == false ? .blue : .orange)
            indicator("Echo terakhir dari Mac",
                      age.map { String(format: "%.1f dtk lalu", $0) } ?? "belum ada",
                      color: fresh ? .green : .red)
            Text("Antarmuka jaringan iPad (tanpa loopback): \(net.interfaces.isEmpty ? "tidak ada" : net.interfaces.joined(separator: ", "))")
                .font(.footnote.monospaced())
            if finished {
                Text("Selesai. Silakan kembali ke Sidecar.").font(.headline).foregroundStyle(.green)
            }
        }
    }

    private func indicator(_ title: String, _ value: String, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 14, height: 14)
            Text(title).font(.headline)
            Spacer()
            Text(value).font(.title3.monospacedDigit().bold()).foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    private func details(stats: EchoStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Listener", stats.listener)
            row("Connection", stats.connection)
            row("Remote", stats.remoteEndpoint)
            row("Path", stats.interfaces)
            row("Accepted / rejected", "\(stats.accepted) / \(stats.rejected)")
            if let error = stats.lastError { row("Last error", error).foregroundStyle(.red) }
        }
        .font(.footnote)
    }

    private var recentEvents: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Log").font(.headline)
            ForEach(Array(events.recent(12).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption2.monospaced()).lineLimit(1)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).font(.footnote.monospaced()).multilineTextAlignment(.trailing)
        }
    }
}
