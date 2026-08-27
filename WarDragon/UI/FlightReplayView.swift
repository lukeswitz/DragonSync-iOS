import SwiftUI
import MapKit
import CoreLocation

struct FlightReplaySample: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let altitude: Double
    let timestamp: TimeInterval
}

struct FlightReplayView: View {
    let title: String
    let dronePath: [FlightReplaySample]
    let operatorPath: [FlightReplaySample]
    let homeCoordinate: CLLocationCoordinate2D?

    @Environment(\.dismiss) private var dismiss

    @State private var elapsed: TimeInterval = 0
    @State private var isPlaying = false
    @State private var speed: Double = 4
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var followDrone = true

    private let tick: TimeInterval = 1.0 / 30.0
    private let speeds: [Double] = [1, 4, 10, 30, 120]

    private var startTime: TimeInterval { dronePath.first?.timestamp ?? 0 }
    private var endTime: TimeInterval { dronePath.last?.timestamp ?? 0 }
    private var duration: TimeInterval { max(0, endTime - startTime) }
    private var playhead: TimeInterval { startTime + elapsed }

    private var dronePosition: FlightReplaySample? {
        Self.interpolate(dronePath, at: playhead)
    }

    private var operatorPosition: FlightReplaySample? {
        Self.interpolate(operatorPath, at: playhead)
    }

    private var travelled: [CLLocationCoordinate2D] {
        var coords = dronePath.filter { $0.timestamp <= playhead }.map(\.coordinate)
        if let head = dronePosition?.coordinate { coords.append(head) }
        return coords
    }

    var body: some View {
        VStack(spacing: 0) {
            map
            controls
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear(perform: frameWholeFlight)
        .onReceive(Timer.publish(every: tick, on: .main, in: .common).autoconnect()) { _ in
            advance()
        }
    }

    private var map: some View {
        Map(position: $cameraPosition) {
            if dronePath.count > 1 {
                MapPolyline(coordinates: dronePath.map(\.coordinate))
                    .stroke(.blue.opacity(0.25), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }

            if travelled.count > 1 {
                MapPolyline(coordinates: travelled)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }

            if operatorPath.count > 1 {
                MapPolyline(coordinates: operatorPath.filter { $0.timestamp <= playhead }.map(\.coordinate))
                    .stroke(.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 4]))
            }

            if let home = homeCoordinate {
                Annotation("Home", coordinate: home) {
                    marker(system: "house.fill", tint: .green, size: 20)
                }
            }

            if let op = operatorPosition {
                Annotation("Pilot", coordinate: op.coordinate) {
                    marker(system: "person.fill", tint: .orange, size: 22)
                }
            }

            if let drone = dronePosition {
                Annotation("Drone", coordinate: drone.coordinate) {
                    marker(system: "airplane", tint: .blue, size: 26)
                }
            }
        }
        .mapStyle(.standard)
        .onMapCameraChange { _ in }
    }

    private func marker(system: String, tint: Color, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(tint).frame(width: size, height: size)
            Image(systemName: system)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.55, height: size * 0.55)
                .foregroundStyle(.white)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Text(clock(elapsed))
                    .font(.system(.caption, design: .monospaced))
                Slider(value: $elapsed, in: 0...max(duration, 0.01)) { editing in
                    if editing { isPlaying = false }
                }
                Text(clock(duration))
                    .font(.system(.caption, design: .monospaced))
            }

            if let drone = dronePosition {
                HStack(spacing: 16) {
                    Label(String(format: "%.0f m", drone.altitude), systemImage: "arrow.up.to.line")
                    if let op = operatorPosition {
                        Label(String(format: "%.0f m", separation(drone.coordinate, op.coordinate)), systemImage: "person.and.arrow.left.and.arrow.right")
                    }
                    Spacer()
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                Button {
                    elapsed = 0
                    isPlaying = false
                } label: {
                    Image(systemName: "backward.end.fill")
                }

                Button {
                    if elapsed >= duration { elapsed = 0 }
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .resizable()
                        .frame(width: 44, height: 44)
                }

                Picker("Speed", selection: $speed) {
                    ForEach(speeds, id: \.self) { value in
                        Text("\(Int(value))x").tag(value)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(isOn: $followDrone) {
                    Image(systemName: followDrone ? "location.fill" : "location")
                }
                .toggleStyle(.button)
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    private func advance() {
        guard isPlaying, duration > 0 else { return }
        elapsed = min(duration, elapsed + tick * speed)
        if elapsed >= duration { isPlaying = false }
        if followDrone, let drone = dronePosition {
            cameraPosition = .region(MKCoordinateRegion(
                center: drone.coordinate,
                span: currentSpan()
            ))
        }
    }

    private func currentSpan() -> MKCoordinateSpan {
        MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
    }

    private func frameWholeFlight() {
        let coords = dronePath.map(\.coordinate) + operatorPath.map(\.coordinate)
        guard !coords.isEmpty else { return }

        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }

        cameraPosition = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.004),
                                   longitudeDelta: max((maxLon - minLon) * 1.4, 0.004))
        ))
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func separation(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Position at `time`, linearly interpolated between the bracketing samples
    /// so playback moves at the speed it was actually flown.
    static func interpolate(_ samples: [FlightReplaySample], at time: TimeInterval) -> FlightReplaySample? {
        guard let first = samples.first else { return nil }
        guard time > first.timestamp else { return first }
        guard let last = samples.last, time < last.timestamp else { return samples.last }

        var lower = 0
        var upper = samples.count - 1
        while upper - lower > 1 {
            let mid = (lower + upper) / 2
            if samples[mid].timestamp <= time { lower = mid } else { upper = mid }
        }

        let a = samples[lower]
        let b = samples[upper]
        let span = b.timestamp - a.timestamp
        guard span > 0 else { return a }

        let t = (time - a.timestamp) / span
        return FlightReplaySample(
            coordinate: CLLocationCoordinate2D(
                latitude: a.coordinate.latitude + (b.coordinate.latitude - a.coordinate.latitude) * t,
                longitude: a.coordinate.longitude + (b.coordinate.longitude - a.coordinate.longitude) * t
            ),
            altitude: a.altitude + (b.altitude - a.altitude) * t,
            timestamp: time
        )
    }
}
