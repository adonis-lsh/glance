//
//  FaceLabView.swift
//  glance
//
//  Debug console: camera preview, face detection + alignment, enrollment,
//  and recognition — all in one tab, independent of the credential/unlock
//  POC in the other tab.
//

import SwiftUI
import Charts

struct FaceLabView: View {
    /// Retained only while the hidden debug tab is visible.
    @Bindable var controller: FaceLabController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("人脸实验室 · 本机人脸识别（调试）")
                        .font(.headline)
                    Spacer()
                    Button("成功预览 ✓") {
                        NotchOverlayController.shared.present()
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            NotchOverlayController.shared.finish(success: true)
                        }
                    }
                    Button("失败预览 ✗") {
                        NotchOverlayController.shared.present(onRetry: {
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                NotchOverlayController.shared.finish(success: false)
                            }
                        })
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            NotchOverlayController.shared.finish(success: false)
                        }
                    }
                    Button("开始首次设置") {
                        controller.startFullOnboarding()
                    }
                    .disabled(enrollmentFlowIsRunning)
                }

                modelStatusSection
                sessionLockSection
                previewSection
                detectionSection
                livenessSection
                enrollSection
                identitiesSection
                recognizeSection
                calibrationSection
                logSection
            }
            .padding(20)
        }
        .onDisappear {
            controller.stop()
        }
        // Guided enrollment runs in the notch, outside this view hierarchy, so nothing else prompts a re-read once
        // it closes. Same trick YourFaceSettingsPage uses.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            controller.store.reloadIfUnlocked()
        }
    }

    /// True while the notch (a single shared panel) is already hosting an onboarding flow.
    private var enrollmentFlowIsRunning: Bool {
        NotchOverlayController.shared.phase == .onboarding
    }

    // MARK: - Which embedder is active

    private var modelStatusSection: some View {
        HStack {
            Circle()
                .fill(controller.pipeline.usingFallbackEmbedder ? .orange : .green)
                .frame(width: 8, height: 8)
            Text("特征模型：\(controller.pipeline.embedder.name)")
                .font(.caption)
            if controller.pipeline.usingFallbackEmbedder {
                Text("（ArcFace 不可用，详见日志）")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
    }

    // MARK: - Session lock (face data is encrypted under the session key)

    private var sessionLockSection: some View {
        Group {
            if controller.store.isLocked {
                HStack {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("会话已锁定，暂时无法读取或保存加密的人脸数据。")
                        .font(.caption)
                    Spacer()
                    Button("解锁") {
                        Task { await controller.unlockSession() }
                    }
                }
                if let error = controller.sessionError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        GroupBox("摄像头预览") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(controller.camera.isRunning ? .green : .gray)
                        .frame(width: 10, height: 10)
                    Text(controller.camera.isRunning ? "运行中" : "已停止")
                    Spacer()
                    Button(controller.camera.isRunning ? "停止" : "开始") {
                        if controller.camera.isRunning {
                            controller.stop()
                        } else {
                            Task { await controller.start() }
                        }
                    }
                }

                if let error = controller.camera.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                CameraPreviewView(session: controller.camera.session, faces: controller.detectedFaces)
                    .frame(height: 300)
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Detection + alignment + embedding

    private var detectionSection: some View {
        GroupBox("检测") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("检测到的人脸：\(controller.detectedFaces.count)")
                    if let quality = controller.currentResult?.quality {
                        Text("采集质量：\(String(format: "%.0f%%", quality * 100))")
                    } else {
                        Text("采集质量：—")
                            .foregroundStyle(.secondary)
                    }
                    if let result = controller.currentResult {
                        Text("对齐方式：\(result.alignmentTier.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("特征向量：\(result.embedding.count) 维")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // Calibration aid for onboarding's pose gating (see OnboardingController's poseMatches).
                        Text("左右转角：\(yawPitchString(result.face.yaw))  俯仰角：\(yawPitchString(result.face.pitch))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(spacing: 4) {
                    Text("对齐后的输入").font(.caption).foregroundStyle(.secondary)
                    if let aligned = controller.currentResult?.alignedImage {
                        Image(aligned, scale: 1, orientation: .up, label: Text("对齐后的人脸"))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: 96, height: 96)
                            .overlay(Text("无人脸").font(.caption2).foregroundStyle(.secondary))
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Liveness

    /// All five cues, split by role (deny vs. confirm) rather than which checker they live in.
    private var livenessSection: some View {
        GroupBox("活体检测") {
            VStack(alignment: .leading, spacing: 12) {
                decisionStrip

                Picker("模式", selection: $controller.livenessMode) {
                    ForEach(LivenessMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Text(controller.livenessMode == .light
                     ? "轻度：仅检测伪造特征，未被拒绝即视为真人。"
                     : "严格：出现伪造特征即拒绝，且至少需要一项真人特征才能通过。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()

                cueGroup(
                    title: "拒绝依据 · 伪造特征",
                    caption: "任意一项触发即拒绝解锁，优先于所有真人确认结果。",
                    cues: LivenessCue.allCases.filter { $0.role == .deny }
                )

                cueGroup(
                    title: "确认依据 · 真人特征",
                    caption: "任意一项触发即可确认活体。尚未触发时继续检测。",
                    cues: LivenessCue.allCases.filter { $0.role == .confirm }
                )

                rawMeasurementsBlock
                geometryDiagnosticsBlock

                HStack {
                    Button("重置检测信号") { controller.resetLiveness() }
                    Text("触发结果在本次扫描中保留，重新测试前请重置。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var decisionStrip: some View {
        let decision = controller.currentLiveness.decision
        let (color, label): (Color, String) = {
            switch decision {
            case .pending:
                return (.secondary, "等待中，尚无结果")
            case .confirmed(let cue):
                return (.green, cue.map { "真人，通过“\($0.title)”确认" } ?? "真人，轻度模式自动确认")
            case .denied(let cue):
                return (.red, "疑似伪造，因“\(cue.title)”被拒绝")
            }
        }()
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.system(.body, design: .monospaced))
            Spacer()
            Text("\(controller.currentLiveness.frameCount) 帧")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cueGroup(title: String, caption: String, cues: [LivenessCue]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(cues) { cue in
                cueRow(cue)
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    /// Level bar plus fire counter — the level only matters insofar as it crosses the fire threshold enough frames.
    private func cueRow(_ cue: LivenessCue) -> some View {
        let state = controller.currentLiveness.state(for: cue)
        let isEnabled = controller.isLivenessCueEnabled(cue)
        let threshold = controller.livenessTuning.level(for: cue)
        let framesNeeded = controller.livenessTuning.frames(for: cue)
        let hasEvidence = state.reading.confidence > 0

        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { controller.isLivenessCueEnabled(cue) },
                set: { controller.setLivenessCue(cue, enabled: $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(cue.explanation)

            Text(cue.title)
                .font(.caption)
                .frame(width: 110, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(hasEvidence ? (cue.role == .deny ? Color.orange : Color.accentColor) : Color.gray.opacity(0.3))
                        .frame(width: geometry.size.width * CGFloat(state.reading.level))
                    // Where this cue starts counting frames.
                    Rectangle()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 1)
                        .offset(x: geometry.size.width * CGFloat(threshold))
                }
            }
            .frame(height: 8)

            Text(hasEvidence ? String(format: "%.0f%%", state.reading.level * 100) : "—")
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)

            Text("\(state.framesCounted)/\(framesNeeded)")
                .font(.caption2.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.secondary)

            Text(state.hasFired ? "已触发" : "")
                .font(.caption2.weight(.bold))
                .foregroundStyle(cue.role == .deny ? Color.red : Color.green)
                .frame(width: 44, alignment: .leading)
        }
        .opacity(isEnabled ? 1 : 0.45)
    }

    /// The actual measurements each cue level is derived from.
    private var rawMeasurementsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let frame = controller.lastLivenessFrame {
                Text("左眼宽高比：\(ratioString(frame.leftEyeAspectRatio))  右眼宽高比：\(ratioString(frame.rightEyeAspectRatio))  鼻部偏移：\(ratioString(frame.noseOffsetRatio))")
                Text("设备重叠比例：\(percentString(frame.deviceOverlapFraction))")
                if let glare = frame.glare {
                    Text("镜面反光：\(String(format: "%.4f", glare.specularFraction))  聚集度：\(String(format: "%.2f", glare.specularClusterRatio))  裁切：\(Int(glare.cropPixelWidth))px")
                } else {
                    Text("镜面反光：—（当前帧没有原始分辨率裁切图）")
                }
            } else {
                Text("尚无活体检测帧。")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private var geometryDiagnosticsBlock: some View {
        let geo = controller.currentGeometry
        return VStack(alignment: .leading, spacing: 6) {
            Text("平面与立体诊断")
                .font(.caption.weight(.semibold))
            Text("关键点：\(geo.validLandmarkCount)  配对：\(geo.pairsAnalyzed)  已拒绝：\(geo.rejectedPairCount)")
            Text("拟合残差：\(ratioString(geo.medianFitResidual))  验证残差：\(ratioString(geo.medianProbeResidual))  超额比：\(ratioString(geo.excessRatio))")
            Text("一致性：\(ratioString(geo.coherence))  运动幅度：\(ratioString(geo.motionMagnitude))")
            if !geo.diagnosticRatios.isEmpty {
                Text(geo.diagnosticRatios.keys.sorted().map { key in
                    "\(key) \(ratioString(geo.diagnosticRatios[key]))"
                }.joined(separator: "  "))
            }
            if geo.planarConfidence == 0 {
                Text("暂不判断：头部转动不足，无法区分平面和静止的立体人脸。")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private func ratioString(_ value: CGFloat?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.3f", value)
    }

    private func percentString(_ value: CGFloat?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    // MARK: - Enrollment

    private var enrollSection: some View {
        GroupBox("录入") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("名称", text: $controller.enrollName)
                        .textFieldStyle(.roundedBorder)
                    Button("采集样本") {
                        controller.captureSample()
                    }
                    .disabled(controller.currentResult == nil || controller.store.isLocked)
                }

                if controller.store.identities.isEmpty {
                    Text(controller.store.isLocked ? "请先解锁会话，再查看已录入的人脸。" : "尚未录入人脸。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.store.identities) { identity in
                        HStack {
                            Text(identity.name)
                            Text("\(identity.samples.count) 个样本")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if identity.isStale(comparedTo: controller.pipeline.embedder) {
                                Text("模型已变更")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                controller.deleteIdentity(identity)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Multi-identity enrollment

    private var identitiesSection: some View {
        GroupBox("已录入的人脸") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("已录入 \(controller.store.identities.count) 个人脸")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("添加人脸") {
                        controller.startAddIdentity()
                    }
                    .disabled(controller.store.isLocked || enrollmentFlowIsRunning)
                }

                if controller.store.identities.isEmpty {
                    Text(controller.store.isLocked
                         ? "请先解锁会话，再查看已录入的人脸。"
                         : "尚未录入人脸，请点击“添加人脸”完成九方向引导采集。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.store.identities) { identity in
                        IdentityRow(
                            identity: identity,
                            isStale: identity.isStale(comparedTo: controller.pipeline.embedder),
                            lowQualityCount: controller.lowQualityCount(in: identity),
                            canStartFlow: !enrollmentFlowIsRunning,
                            recapture: { controller.startRecapture(of: identity) },
                            delete: { controller.deleteIdentity(identity) }
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Recognition

    private var recognizeSection: some View {
        GroupBox("识别") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("开始识别") {
                        controller.recognize()
                    }
                    .disabled(controller.currentResult == nil || controller.store.identities.isEmpty)

                    Spacer()

                    Text("阈值：\(String(format: "%.2f", controller.threshold))")
                        .font(.caption)
                    Slider(value: $controller.threshold, in: -1...1)
                        .frame(width: 160)
                }

                if let best = controller.bestMatch {
                    HStack {
                        Circle().fill(.green).frame(width: 10, height: 10)
                        Text("最佳匹配：\(best.name) · 中心相似度 \(String(format: "%.3f", best.centroidSimilarity))，最大值 \(String(format: "%.3f", best.maxSampleSimilarity))")
                        Text("匹配成功").font(.caption.bold()).foregroundStyle(.green)
                    }
                } else if let first = controller.recognitionResults.first {
                    HStack {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text("最接近：\(first.name) · 中心相似度 \(String(format: "%.3f", first.centroidSimilarity))，最大值 \(String(format: "%.3f", first.maxSampleSimilarity))")
                        Text("未匹配").font(.caption.bold()).foregroundStyle(.red)
                    }
                }

                if !controller.recognitionResults.isEmpty {
                    Divider()
                    ForEach(controller.recognitionResults) { result in
                        HStack {
                            Text(result.name)
                            if result.isStale {
                                Text("模型已变更").font(.caption2.bold()).foregroundStyle(.orange)
                            }
                            Spacer()
                            Text("中心相似度 \(String(format: "%.3f", result.centroidSimilarity))")
                                .foregroundStyle(.secondary)
                            Text("最大值 \(String(format: "%.3f", result.maxSampleSimilarity))")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Threshold calibration

    private var calibrationSection: some View {
        GroupBox("阈值校准") {
            VStack(alignment: .leading, spacing: 8) {
                Text("点击“开始识别”，再标记是否为本人。在不同光线、角度和表情下反复采集，并请其他人测试，以观察两类分数的实际分布。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("标记为本人") {
                        controller.recordCalibrationSample(isGenuine: true)
                    }
                    Button("标记为他人") {
                        controller.recordCalibrationSample(isGenuine: false)
                    }
                    .disabled(controller.recognitionResults.isEmpty)
                    Spacer()
                    Button("清空", role: .destructive) {
                        controller.clearCalibrationSamples()
                    }
                    .disabled(controller.calibrationSamples.isEmpty)
                }
                .disabled(controller.recognitionResults.isEmpty && controller.calibrationSamples.isEmpty)

                if !controller.calibrationSamples.isEmpty {
                    Chart {
                        ForEach(controller.calibrationSamples) { sample in
                            PointMark(
                                x: .value("相似度", sample.centroidSimilarity),
                                y: .value("类型", sample.isGenuine ? "本人" : "他人")
                            )
                            .foregroundStyle(sample.isGenuine ? Color.green : Color.red)
                        }
                        RuleMark(x: .value("阈值", controller.threshold))
                            .foregroundStyle(.blue)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    }
                    .chartXScale(domain: -1...1)
                    .frame(height: 100)

                    if let suggested = controller.suggestedThreshold {
                        HStack {
                            Text("建议阈值：\(String(format: "%.3f", suggested))")
                                .font(.caption)
                            Button("使用此值") {
                                controller.threshold = Double(suggested)
                            }
                            if controller.calibrationDistributionsOverlap {
                                Text("分数分布存在重叠，暂时无法用单一阈值完全区分这些样本。")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    } else {
                        Text("请至少记录一个本人样本和一个他人样本，以获得建议阈值。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Debug log

    private var logSection: some View {
        GroupBox("日志") {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
        }
    }

    private func yawPitchString(_ value: Float?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.2f", value)
    }
}

/// One enrolled person: a summary line, actions, and a disclosure listing every stored sample's capture quality.
private struct IdentityRow: View {
    let identity: FaceIdentity
    let isStale: Bool
    let lowQualityCount: Int
    let canStartFlow: Bool
    let recapture: () -> Void
    let delete: () -> Void

    private var posesCaptured: Int {
        Set(identity.samples.compactMap(\.pose)).count
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(identity.samples.enumerated()), id: \.offset) { index, sample in
                    HStack(spacing: 8) {
                        Text(String(format: "%2d", index + 1))
                            .foregroundStyle(.tertiary)
                        Text(sample.pose ?? "未标记")
                            .frame(width: 90, alignment: .leading)
                        Text(FaceLabController.qualityLabel(sample.quality))
                            .frame(width: 44, alignment: .trailing)
                            .foregroundStyle(isLow(sample) ? .orange : .primary)
                        Text(sample.capturedAt.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.caption.monospaced())
                }
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(identity.name).bold()
                    if isStale {
                        Text("模型已变更")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("重新采集", action: recapture)
                        .disabled(!canStartFlow)
                    Button(role: .destructive, action: delete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }

                Text("\(posesCaptured)/9 个方向 · \(identity.samples.count) 个样本 · 录入于 \(identity.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if lowQualityCount > 0 {
                    Text("\(identity.samples.count) 个样本中有 \(lowQualityCount) 个质量较低")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func isLow(_ sample: FaceSample) -> Bool {
        sample.qualityTier == .poor
    }
}

#Preview {
    FaceLabView(controller: FaceLabController())
}
