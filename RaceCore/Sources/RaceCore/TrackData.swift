public enum TrackData {
    /// Punkty kontrolne pierwszej trasy (x, z w metrach). Spline zamyka pętlę sam.
    public static let cityLoop: [SIMD2<Double>] = [
        [0, 0], [0, 300], [80, 420], [220, 440], [320, 360], [330, 200],
        [260, 120], [300, 0], [260, -150], [120, -200], [30, -140],
    ]
    public static let cityLoopHalfWidth = 9.0

    public static func makeCityLoop() -> Track { Track(points: cityLoop, halfWidth: cityLoopHalfWidth) }
}
