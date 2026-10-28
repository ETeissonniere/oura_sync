import Foundation

/// Native Gen 3 optical classification; acceptance does not establish calibration.
/// Preserve Float rounding and fused operations used by the ring analysis library.
enum OxygenDipClassifier {

  static func probability(of dip: OxygenDipDetector.Dip, in batch: OxygenEventProcessor.Batch)
    -> Double
  {
    let samples = batch.quality
    let quality = samples.map {
      QualitySample(
        time: $0.sample.time, pi: $0.optical.perfusion,
        pulses: UInt8(clamping: $0.optical.pulses), motion: $0.motion)
    }
    let red = batch.optical.filter { $0.channel == 0 }.map {
      Baseline(time: $0.time, value: $0.value)
    }
    let infrared = batch.optical.filter { $0.channel == 1 }.map {
      Baseline(time: $0.time, value: $0.value)
    }
    return classify(
      start: samples[dip.start].sample.time, end: samples[dip.end].sample.time,
      bottom: samples[dip.bottom].sample.time, depth: dip.depth,
      quality: quality, red: red, infrared: infrared
    )
  }

  private struct Baseline {
    let time: Int64
    let value: UInt32
  }
  private static func redBaseline(at time: Int64, in samples: [Baseline]) -> UInt32 {
    guard time != 0, !samples.isEmpty else { return 0 }
    if let exact = samples.first(where: { $0.time == time }) { return exact.value }
    guard let left = samples.prefix(while: { $0.time < time }).last,
      let right = samples.first(where: { $0.time > time })
    else { return 0 }
    let fraction = Float(time - left.time) / Float(right.time - left.time)
    let low = Float(left.value)
    let delta = Float(right.value) - low
    let interpolated = low.addingProduct(fraction, delta)
    guard interpolated.isFinite, interpolated > 0 else { return 0 }
    if Double(interpolated) >= Double(UInt32.max) { return .max }
    return UInt32(interpolated)
  }

  private static func opticalWindow(times: [Int64], start: Int64, end: Int64, bottom: Int64) -> (
    Int, Int, Int
  ) {
    guard !times.isEmpty else { return (0, 0, 0) }
    let first = times.firstIndex(where: { $0 >= max(0, start - 2000) }) ?? 0
    let last = times.indices.prefix(while: { times[$0] <= end + 2000 }).last ?? (times.count - 1)
    let center: Int
    if bottom == 0 {
      center = last
    } else if let exact = times.firstIndex(of: bottom) {
      center = min(max(exact, first), last)
    } else {
      let left = times.indices.prefix(while: { times[$0] <= bottom }).last
      let right = times.firstIndex(where: { $0 >= bottom })
      let nearest: Int
      if let left, let right {
        nearest = bottom - times[left] < times[right] - bottom ? left : right
      } else {
        nearest = left ?? right ?? last
      }
      center = min(max(nearest, first), last)
    }
    return (first, last, center)
  }

  private struct QualitySample {
    let time: Int64
    let pi: Double
    let pulses: UInt8
    let motion: Double
  }
  private static func featureWindow(samples: [QualitySample], start: Int64, end: Int64)
    -> ClosedRange<Int>?
  {
    guard !samples.isEmpty else { return nil }
    let first = start >= 2001 ? samples.firstIndex(where: { $0.time >= start - 2000 }) ?? 0 : 0
    let last =
      samples.indices.prefix(while: { samples[$0].time <= end + 2000 }).last ?? (samples.count - 1)
    return first <= last ? first...last : nil
  }
  private static func qualityFeatures(_ samples: ArraySlice<QualitySample>) -> (
    pi: Float, pulses: Float, motion: Float
  ) {
    guard !samples.isEmpty else { return (0, 0, 0) }
    let sorted = samples.map(\.pi).sorted()
    let middle = sorted.count / 2
    let median = Float(
      sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) * 0.5 : sorted[middle])
    let pulses = samples.reduce(Float(0)) { $0 + Float($1.pulses) } / Float(samples.count)
    let motion = samples.reduce(Float(0)) { $0 + Float($1.motion) } / Float(samples.count)
    return (median.isNaN ? 0 : median, pulses.isNaN ? 0 : pulses, motion.isNaN ? 0 : motion)
  }

  private static func baselineMeans(_ values: [UInt32]) -> [Double] {
    guard !values.isEmpty else { return [] }
    let width = min(values.count, 5)
    let half = min(values.count, 5) / 2
    return values.indices.map { index in
      let first = max(0, index - half)
      let last =
        index > values.count - 1 - half
        ? values.count - 1 : index + half - (width.isMultiple(of: 2) ? 1 : 0)
      return values[first...last].reduce(0.0) { $0 + Double($1) } / Double(last - first + 1)
    }
  }
  private static func dcRates(red: [UInt32], infrared: [UInt32], times: [Int64], center: Int) -> (
    Double, Double
  ) {
    precondition(
      red.count == infrared.count && red.count == times.count && times.indices.contains(center))
    let r = baselineMeans(red)
    let ir = baselineMeans(infrared)
    let difference = zip(r, ir).map(-)
    func rate(_ first: Int, _ last: Int) -> Double {
      let seconds = Double(times[last] - times[first]) / 1000
      guard seconds > 0 else { return 0 }
      let value = (difference[last] - difference[first]) / seconds
      return value.isNaN ? 0 : value
    }
    return (rate(0, center), rate(center, times.count - 1))
  }

  private struct DropFeatures {
    let durationMilliseconds: UInt32
    let depth: UInt8
    let dropRate: Float
    let fallDC: Double
    let riseDC: Double
    let fallCorrelation: Double
    let riseCorrelation: Double
    let medianPI: Float
    let motion: Float
    let pulses: Float
  }
  private static func probability(_ f: DropFeatures) -> Double {
    func clamp<T: BinaryFloatingPoint>(_ x: T, _ low: T, _ high: T) -> T { min(max(x, low), high) }
    guard
      [
        Double(f.dropRate), f.fallDC, f.riseDC, f.fallCorrelation, f.riseCorrelation,
        Double(f.medianPI), Double(f.motion), Double(f.pulses),
      ].allSatisfy(\.isFinite)
    else { return 0 }
    var score = Double(f.durationMilliseconds / 60000) * -0.839592
    score = score.addingProduct(Double(f.depth).squareRoot(), 1.08092)
    score = score.addingProduct(clamp(f.fallDC, -500, 500) / 100, -0.30539)
    score = score.addingProduct(clamp(f.riseDC, -500, 500) / 100, 0.19897)
    score = score.addingProduct(Double(clamp(f.motion, 0, 30).squareRoot()), -0.55532)
    score = score.addingProduct(Double(clamp(f.medianPI, 0, 1) * 100), 0.21898)
    score = score.addingProduct(Double(f.dropRate.squareRoot()), -2.92177)
    score = score.addingProduct(clamp(f.fallCorrelation, -1, 1), -0.19157)
    score = score.addingProduct(clamp(f.riseCorrelation, -1, 1), -0.24601)
    score = score.addingProduct(Double(clamp(f.pulses, 0, 20).squareRoot()), 0.27785)
    score += -1.69312
    let result = 1 / (1 + exp(-score))
    return result.isNaN ? 0 : result
  }

  private static func correlation(_ a: [Double], _ b: [Double], range: ClosedRange<Int>) -> Double {
    var x = 0.0
    var y = 0.0
    var xx = 0.0
    var yy = 0.0
    var xy = 0.0
    for i in range {
      x += a[i]
      y += b[i]
      xx = xx.addingProduct(a[i], a[i])
      yy = yy.addingProduct(b[i], b[i])
      xy = xy.addingProduct(a[i], b[i])
    }
    let n = Double(range.count)
    let denominator = ((-x * x).addingProduct(n, xx) * (-y * y).addingProduct(n, yy)).squareRoot()
    guard denominator != 0 else { return 0 }
    let result = (-x * y).addingProduct(n, xy) / denominator
    return result.isNaN ? 0 : result
  }
  private static func classify(
    start: Int64, end: Int64, bottom: Int64, depth: UInt8,
    quality: [QualitySample], red: [Baseline], infrared: [Baseline]
  ) -> Double {
    let window = opticalWindow(times: infrared.map(\.time), start: start, end: end, bottom: bottom)
    guard !infrared.isEmpty, window.0 <= window.1,
      window.2 > window.0, window.2 < window.1, bottom > start, bottom < end,
      let qRange = featureWindow(samples: quality, start: start, end: end)
    else {
      return 0
    }
    let ir = Array(infrared[window.0...window.1])
    let r = ir.map { redBaseline(at: $0.time, in: red) }
    let center = window.2 - window.0
    let rates = dcRates(red: r, infrared: ir.map(\.value), times: ir.map(\.time), center: center)
    let rMean = baselineMeans(r)
    let irMean = baselineMeans(ir.map(\.value))
    let q = qualityFeatures(quality[qRange])
    let features = DropFeatures(
      durationMilliseconds: UInt32(end - start), depth: depth,
      dropRate: Float(depth) / (Float(bottom - start) / 1000), fallDC: rates.0, riseDC: rates.1,
      fallCorrelation: correlation(rMean, irMean, range: 0...center),
      riseCorrelation: correlation(rMean, irMean, range: center...(ir.count - 1)),
      medianPI: q.pi, motion: q.motion, pulses: q.pulses)
    return probability(features)
  }
}
