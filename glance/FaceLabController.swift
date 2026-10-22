//
//  FaceLabController.swift
//  glance
//
//  Orchestrates the Face Lab debug tab. Deliberately never touches LockMonitor, KeystrokeInjector, or
//  SecureCredentialManager for *unlocking* — that's handled separately by FaceUnlockCoordinator (off by default).
//

import Foundation
import CoreGraphics
import Observation

struct RecognitionResult: Identifiable {
    let id = UUID()
    let name: String
    /// Similarity against the identity's averaged template.
    let centroidSimilarity: Float
    /// Similarity against the single closest sample. A match must clear the threshold on *both* measures.
    let maxSampleSimilarity: Float
    let isStale: Bool
}

/// One manually-tagged data point for threshold calibration: "this
/// similarity score came from a genuine match" or "from an impostor."
struct CalibrationSample: Identifiable {
    let id = UUID()
    let centroidSimilarity: Float
    let isGenuine: Bool
}

@Observable
@MainActor
final class FaceLabController {
    let camera = CameraManager()
    let store = FaceEnrollmentStore.shared
    let pipeline = FaceRecognitionPipeline()

    private(set) var detectedFaces: [DetectedFace] = []
    private(set) var currentResult: FaceRecognitionResult?

    /// Fed live, same as `FaceUnlockCoordinator`'s scan loop — this is exactly what the real unlock path would see.
    private let livenessAnalyzer = LivenessAnalyzer()
    private(set) var currentLiveness = LivenessSnapshot.empty
    /// Diagnostics behind the flat-vs-3D cue, explaining *why* it reads what it reads beyond the cue's own 0...1 level.
    private(set) var currentGeometry = GeometryLivenessResult.empty
    /// Lets the debug view show raw measurements live (not just derived cue levels), to tell a wrong threshold from
    /// a measurement that isn't moving at all.
    private(set) var lastLivenessFrame: LivenessFrame?

    /// Drives mode/tuning locally rather than reading `GlanceSettings`, so experimenting here can't change what
    /// actually unlocks the Mac. Heavy by default since the point of this tab is watching the confirm cues.
    var livenessMode: LivenessMode = .heavy
    var livenessTuning = LivenessTuning.default
    var enabledLivenessCues: Set<LivenessCue> = Set(LivenessCue.allCases)

    func isLivenessCueEnabled(_ cue: LivenessCue) -> Bool {
        enabledLivenessCues.contains(cue)
    }

    func setLivenessCue(_ cue: LivenessCue, enabled: Bool) {
        if enabled {
            enabledLivenessCues.insert(cue)
        } else {
            enabledLivenessCues.remove(cue)
        }
    }

    /// Cue firing latches for a whole scan by design, so re-testing a spoof after one's been caught needs an explicit clear.
    func resetLiveness() {
        livenessAnalyzer.reset()
        currentLiveness = .empty
        currentGeometry = .empty
        log("已重置活体检测信号。")
    }

    var enrollName: String = ""
    /// Raw cosine similarity cutoff (-1...1); typical ArcFace verification cutoffs sit around 0.28-0.40.
    var threshold: Double = 0.6

    private(set) var recognitionResults: [RecognitionResult] = []
    private(set) var bestMatch: RecognitionResult?

    private(set) var logLines: [String] = []
    private(set) var sessionError: String?

    private var isProcessingFrame = false

    init() {
        observeFrames()
        livenessAnalyzer.modeProvider = { [weak self] in self?.livenessMode ?? .heavy }
        livenessAnalyzer.tuningProvider = { [weak self] in self?.livenessTuning ?? .default }
        livenessAnalyzer.enabledCuesProvider = { [weak self] in
            self?.enabledLivenessCues ?? Set(LivenessCue.allCases)
        }
        store.reloadIfUnlocked()
        if pipeline.usingFallbackEmbedder {
            log("ArcFace 不可用（\(pipeline.fallbackReason ?? "原因未知")），已改用 Vision Feature Print。")
        } else {
            log("正在使用 \(pipeline.embedder.name)。")
        }
    }

    func start() async {
        await camera.start()
        if let error = camera.errorMessage {
            log(error)
        } else {
            log("摄像头已启动。")
        }
    }

    func stop() {
        camera.stop()
        detectedFaces = []
        currentResult = nil
        livenessAnalyzer.reset()
        currentLiveness = .empty
        currentGeometry = .empty
        lastLivenessFrame = nil
        log("摄像头已停止。")
    }

    /// Mirrors `POCController.unlockSession()` so Face Lab can unlock the session without leaving this page.
    func unlockSession() async {
        sessionError = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try await SecureCredentialManager.unlockSession(reason: "验证身份以使用人脸实验室")
            }.value
            store.reloadIfUnlocked()
            log("会话已解锁。")
        } catch {
            sessionError = error.localizedDescription
        }
    }

    /// Re-subscribes on every change — `withObservationTracking` only fires once per registration.
    private func observeFrames() {
        withObservationTracking {
            _ = camera.currentFrame
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeFrames()
                await self?.processLatestFrame()
            }
        }
    }

    /// Skips frames that arrive mid-processing — an "always work on the latest frame" throttle instead of a timer.
    private func processLatestFrame() async {
        guard !isProcessingFrame, let cameraFrame = camera.currentFrame else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        let pipeline = self.pipeline
        do {
            let (result, livenessFrame) = try await Task.detached(priority: .userInitiated) {
                let result = try pipeline.recognize(in: cameraFrame.image)
                let faceCrop = CameraManager.renderCrop(from: cameraFrame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: cameraFrame.image, faceCrop: faceCrop))
            }.value
            detectedFaces = [result.face]
            currentResult = result
            lastLivenessFrame = livenessFrame
            currentLiveness = livenessAnalyzer.observe(livenessFrame)
            currentGeometry = livenessAnalyzer.lastGeometry
        } catch FaceRecognitionPipelineError.noFaceDetected {
            detectedFaces = []
            currentResult = nil
        } catch {
            detectedFaces = []
            currentResult = nil
            log("检测错误：\(error.localizedDescription)")
        }
    }

    // MARK: - Enrollment

    func captureSample() {
        guard let result = currentResult else {
            log("未检测到人脸，无法采集样本。")
            return
        }
        let trimmedName = enrollName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            log("请先输入名称，再采集样本。")
            return
        }
        do {
            try store.addSample(
                name: trimmedName,
                embedding: result.embedding,
                embedder: pipeline.embedder,
                quality: result.quality
            )
            log("已为“\(trimmedName)”采集样本（\(result.embedding.count) 维，\(result.alignmentTier.rawValue)，质量 \(Self.qualityLabel(result.quality))）。")
        } catch {
            log("无法保存样本：\(error.localizedDescription)")
        }
    }

    func deleteIdentity(_ identity: FaceIdentity) {
        do {
            try store.delete(identity)
            log("已删除“\(identity.name)”。")
        } catch {
            log("无法删除：\(error.localizedDescription)")
        }
    }

    // MARK: - Multi-identity enrollment

    /// Counts only the red band of `FaceSample.qualityTier`, so this debug list and the Your Face tick strip always
    /// agree about what "low" means. Samples with no score count as unrated, never as low.
    func lowQualityCount(in identity: FaceIdentity) -> Int {
        identity.samples.filter { $0.qualityTier == .poor }.count
    }

    /// Face Lab and onboarding each own a separate `CameraManager` on the same device — stop ours first to avoid
    /// two live sessions with different configurations.
    func startFullOnboarding() {
        camera.stop()
        log("正在启动完整的首次设置流程。")
        OnboardingController.startFlow()
    }

    func startAddIdentity() {
        camera.stop()
        log("正在启动新人脸引导录入。")
        OnboardingController.startAddIdentity()
    }

    func startRecapture(of identity: FaceIdentity) {
        camera.stop()
        log("正在为“\(identity.name)”启动引导重新采集。")
        OnboardingController.startRecapture(of: identity)
    }

    static func qualityLabel(_ quality: Float?) -> String {
        guard let quality else { return "—" }
        return String(format: "%.0f%%", quality * 100)
    }

    // MARK: - Recognition

    func recognize() {
        guard let result = currentResult else {
            log("未检测到人脸，无法识别。")
            recognitionResults = []
            bestMatch = nil
            return
        }
        guard !store.identities.isEmpty else {
            log("尚未录入人脸，请先采集样本。")
            recognitionResults = []
            bestMatch = nil
            return
        }

        let embedder = pipeline.embedder
        let scored = pipeline.score(result.embedding, against: store.identities)
        recognitionResults = scored.map { s in
            RecognitionResult(
                name: s.identity.name,
                centroidSimilarity: s.centroidSimilarity,
                maxSampleSimilarity: s.maxSampleSimilarity,
                isStale: s.identity.isStale(comparedTo: embedder)
            )
        }

        let matched = pipeline.bestMatch(in: scored, threshold: Float(threshold))
        bestMatch = matched.map {
            RecognitionResult(name: $0.identity.name, centroidSimilarity: $0.centroidSimilarity, maxSampleSimilarity: $0.maxSampleSimilarity, isStale: false)
        }

        if let best = scored.first {
            let verdict = (bestMatch != nil) ? "匹配成功" : "未匹配"
            let staleNote = best.identity.isStale(comparedTo: embedder) ? "［模型已变更，请使用当前模型重新录入］" : ""
            log("识别：最佳匹配 = \(best.identity.name)，中心相似度 = \(String(format: "%.3f", best.centroidSimilarity))，最大值 = \(String(format: "%.3f", best.maxSampleSimilarity)) → \(verdict)\(staleNote)")
        }
    }

    // MARK: - Threshold calibration

    /// Tagged similarity scores collected this session — the actual data a threshold should be picked from, not guessed.
    private(set) var calibrationSamples: [CalibrationSample] = []

    /// Tags the most recent `recognize()` top score as genuine or impostor, using centroid similarity (what the
    /// threshold slider actually gates on).
    func recordCalibrationSample(isGenuine: Bool) {
        guard let top = recognitionResults.first else {
            log("暂无可记录结果，请先开始识别。")
            return
        }
        calibrationSamples.append(CalibrationSample(centroidSimilarity: top.centroidSimilarity, isGenuine: isGenuine))
        log("校准：已记录\(isGenuine ? "本人" : "他人")样本，相似度 \(String(format: "%.3f", top.centroidSimilarity))。")
    }

    func clearCalibrationSamples() {
        calibrationSamples.removeAll()
    }

    /// Midpoint between the lowest genuine score and the highest impostor score. Nil until at least one of each is recorded.
    var suggestedThreshold: Float? {
        let genuine = calibrationSamples.filter(\.isGenuine).map(\.centroidSimilarity)
        let impostor = calibrationSamples.filter { !$0.isGenuine }.map(\.centroidSimilarity)
        guard let minGenuine = genuine.min(), let maxImpostor = impostor.max() else { return nil }
        return (minGenuine + maxImpostor) / 2
    }

    /// True if any impostor score is >= any genuine score — no single threshold perfectly separates the two groups yet.
    var calibrationDistributionsOverlap: Bool {
        let genuine = calibrationSamples.filter(\.isGenuine).map(\.centroidSimilarity)
        let impostor = calibrationSamples.filter { !$0.isGenuine }.map(\.centroidSimilarity)
        guard let minGenuine = genuine.min(), let maxImpostor = impostor.max() else { return false }
        return maxImpostor >= minGenuine
    }

    private func log(_ message: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        logLines.append("[\(timestamp)] \(message)")
        if logLines.count > 200 {
            logLines.removeFirst(logLines.count - 200)
        }
    }
}
