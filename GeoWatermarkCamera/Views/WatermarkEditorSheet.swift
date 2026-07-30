import SwiftUI

struct WatermarkEditorSheet: View {
    @Binding var configuration: WatermarkConfiguration
    let automaticAddress: String?
    let refreshLocation: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("模板") {
                    Picker("水印模板", selection: $configuration.template) {
                        ForEach(WatermarkTemplate.allCases) { template in
                            Text(template.title).tag(template)
                        }
                    }
                    .pickerStyle(.segmented)

                    preview
                        .listRowInsets(EdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12))
                        .listRowBackground(Color(white: 0.13))
                }

                Section {
                    HStack {
                        Label("背景透明度", systemImage: "circle.lefthalf.filled")
                        Spacer()
                        Text("\(backgroundOpacityPercentage)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: backgroundOpacityBinding, in: 0...1, step: 0.05)
                        .accessibilityLabel("水印背景透明度")
                        .accessibilityValue("\(backgroundOpacityPercentage)%")
                } header: {
                    Text("背景")
                } footer: {
                    Text("0% 为完全透明，只显示文字；100% 为完全不透明。画面较复杂时建议保持 40% 以上，以免文字难以辨认。")
                }

                Section("显示内容") {
                    Toggle("日期和时间", isOn: $configuration.showDateTime)
                    Toggle("经纬度", isOn: $configuration.showCoordinates)
                    Toggle("地址", isOn: $configuration.showAddress)
                    Toggle("自定义文字", isOn: $configuration.showCustomText)
                }

                if configuration.showCoordinates {
                    Section("坐标格式") {
                        Picker("显示格式", selection: $configuration.coordinateFormat) {
                            ForEach(CoordinateDisplayFormat.allCases) { format in
                                Text(format.title).tag(format)
                            }
                        }
                    }
                }

                if configuration.showAddress {
                    Section("地址名称") {
                        TextField("输入地址或自定义名称", text: customAddressBinding, axis: .vertical)
                            .lineLimit(2...4)
                        Button {
                            configuration.usesCustomAddress = false
                            configuration.addressText = automaticAddress ?? "未获取位置"
                            refreshLocation()
                        } label: {
                            Label("使用当前定位地址", systemImage: "location.fill")
                        }
                        Text(configuration.usesCustomAddress ? "当前使用自定义地址名称" : "地址会随当前定位自动更新")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if configuration.showCustomText {
                    Section {
                        TextField("姓名、项目名或备注", text: $configuration.customText, axis: .vertical)
                            .lineLimit(2...4)
                        Text("自定义文字会单独显示在取景框中，可拖动、缩放，也可点右上角打叉关闭。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("自定义文字")
                    }
                }

                Section {
                    Picker("识别方式", selection: $configuration.textRecognitionMode) {
                        ForEach(TextRecognitionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if configuration.textRecognitionMode == .suggest {
                        HStack {
                            Label("提示停留", systemImage: "timer")
                            Spacer()
                            Text("\(Int(configuration.recognitionSuggestionDuration)) 秒")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: suggestionDurationBinding,
                            in: 2...15,
                            step: 1
                        )
                        .accessibilityLabel("加入水印提示停留时长")
                        .accessibilityValue("\(Int(configuration.recognitionSuggestionDuration)) 秒")
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "text.viewfinder")
                            .foregroundStyle(.blue)
                            .padding(.top, 2)
                        Text(textRecognitionDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("画面文字识别")
                } footer: {
                    Text("识别在本机完成，不会上传相机画面。门牌号、企业名称等仍可能误识别，加入后可在“自定义文字”中修改。")
                }

                Section {
                    Button("恢复默认位置和大小") {
                        configuration.placement = .default
                        configuration.customTextPlacement = .default
                    }
                } footer: {
                    Text("主水印与自定义文字可分别拖动和双指缩放，位置与大小会自动记住。")
                }
            }
            .navigationTitle("编辑水印")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var customAddressBinding: Binding<String> {
        Binding(
            get: { configuration.addressText },
            set: {
                configuration.addressText = $0
                configuration.usesCustomAddress = true
            }
        )
    }

    private var backgroundOpacityBinding: Binding<Double> {
        Binding(
            get: { min(max(configuration.backgroundOpacity, 0), 1) },
            set: { configuration.backgroundOpacity = min(max($0, 0), 1) }
        )
    }

    private var suggestionDurationBinding: Binding<Double> {
        Binding(
            get: { configuration.recognitionSuggestionDuration },
            set: { configuration.recognitionSuggestionDuration = $0 }
        )
    }

    private var backgroundOpacityPercentage: Int {
        Int((backgroundOpacityBinding.wrappedValue * 100).rounded())
    }

    private var textRecognitionDescription: String {
        switch configuration.textRecognitionMode {
        case .off:
            "相机运行时不识别画面中的文字。"
        case .suggest:
            "识别到稳定文字后先显示提示，由你确认是否加入水印。提示会在设定时长后自动消失。"
        case .automatic:
            "识别到稳定文字后自动追加到独立的自定义文字模块中。"
        }
    }

    private var preview: some View {
        let previewConfiguration: WatermarkConfiguration = {
            var value = configuration
            if value.addressText.isEmpty { value.addressText = "示例地址" }
            if value.customText.isEmpty { value.customText = "现场记录" }
            value.placement.scale = 0.86
            value.customTextPlacement.scale = 0.86
            return value
        }()
        let snapshot = WatermarkSnapshot(
            configuration: previewConfiguration,
            capturedAt: Date(),
            latitude: 31.230416,
            longitude: 121.473701
        )
        return WatermarkPreview(
            snapshot: snapshot,
            scale: 0.86,
            maximumTextWidth: 280,
            showsCloseControl: false
        )
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
    }
}
