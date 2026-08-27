import Foundation

enum SeriesSmoother {

    /// Linear interpolation across gaps of at most `maxGap` samples. Longer gaps
    /// stay nil so the chart breaks the line instead of inventing data.
    static func fillShortGaps(_ values: [Double?], maxGap: Int) -> [Double?] {
        guard maxGap > 0, values.contains(where: { $0 != nil }) else { return values }
        var out = values
        var lastIndex: Int? = nil

        for i in values.indices {
            guard values[i] != nil else { continue }
            defer { lastIndex = i }
            guard let previous = lastIndex else { continue }

            let span = i - previous
            guard span > 1, span - 1 <= maxGap else { continue }

            let start = values[previous]!
            let end = values[i]!
            for step in 1..<span {
                out[previous + step] = start + (end - start) * Double(step) / Double(span)
            }
        }
        return out
    }

    /// Rolling median. Removes impulse spikes without the lag a mean introduces.
    static func rollingMedian(_ values: [Double?], window: Int) -> [Double?] {
        guard window > 1 else { return values }
        let half = window / 2

        return values.indices.map { i -> Double? in
            guard values[i] != nil else { return nil }
            let lower = max(values.startIndex, i - half)
            let upper = min(values.index(before: values.endIndex), i + half)
            let sample = (lower...upper).compactMap { values[$0] }.sorted()
            guard !sample.isEmpty else { return nil }
            let mid = sample.count / 2
            return sample.count % 2 == 0 ? (sample[mid - 1] + sample[mid]) / 2 : sample[mid]
        }
    }

    /// Exponential moving average. Resets across nil gaps.
    static func ema(_ values: [Double?], alpha: Double) -> [Double?] {
        guard alpha > 0, alpha < 1 else { return values }
        var previous: Double? = nil

        return values.map { value -> Double? in
            guard let value else {
                previous = nil
                return nil
            }
            let smoothed = previous.map { alpha * value + (1 - alpha) * $0 } ?? value
            previous = smoothed
            return smoothed
        }
    }

    /// Gap fill, then median to kill spikes, then EMA to level the result.
    static func level(_ values: [Double?],
                      window: Int = 5,
                      alpha: Double = 0.35,
                      maxGap: Int = 2) -> [Double?] {
        ema(rollingMedian(fillShortGaps(values, maxGap: maxGap), window: window), alpha: alpha)
    }

    #if DEBUG
    static func selfCheck() {
        let spike: [Double?] = [10, 10, 90, 10, 10]
        let despiked = rollingMedian(spike, window: 3).compactMap { $0 }
        assert(despiked.allSatisfy { $0 < 20 }, "rollingMedian failed to remove impulse")

        let gapped: [Double?] = [0, nil, nil, 3]
        let filled = fillShortGaps(gapped, maxGap: 2)
        assert(filled[1] == 1 && filled[2] == 2, "fillShortGaps interpolation wrong")

        let wide: [Double?] = [0, nil, nil, nil, 4]
        assert(fillShortGaps(wide, maxGap: 2)[2] == nil, "fillShortGaps bridged too wide a gap")

        let reset = ema([1, nil, 100], alpha: 0.5)
        assert(reset[2] == 100, "ema failed to reset across a gap")
    }
    #endif
}
