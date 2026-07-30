# 项目结构规划

`GeoWatermarkCamera` 采用轻量 MVVM/Service 分层，MVP 主链路不依赖第三方库：

```text
GeoWatermarkCamera/
├── GeoWatermarkCamera.xcodeproj
├── GeoWatermarkCamera/
│   ├── App/
│   │   └── GeoWatermarkCameraApp.swift       # SwiftUI App 入口
│   ├── Models/
│   │   ├── WatermarkConfiguration.swift      # 模板、显示项、文字识别模式、归一化位置
│   │   ├── WatermarkSnapshot.swift           # 某一拍摄时刻的冻结水印内容
│   │   └── PreviewGeometryMapper.swift        # 预览坐标到照片像素坐标换算
│   ├── Services/
│   │   ├── CameraService.swift               # AVCaptureSession、拍照、闪光灯、变焦、Vision 文字识别
│   │   ├── LocationService.swift             # 定位、权限和逆地理编码
│   │   ├── PhotoProcessingService.swift      # 像素合成、EXIF/GPS、Photos 保存
│   │   └── WatermarkSettingsStore.swift      # 模板/位置持久化
│   ├── Views/
│   │   ├── CameraScreen.swift                # 相机主页和完整拍摄工作流
│   │   ├── CameraPreview.swift               # AVCaptureVideoPreviewLayer 桥接
│   │   ├── WatermarkPreview.swift            # 实时预览、拖动、吸附、缩放
│   │   └── WatermarkEditorSheet.swift        # 水印模板和内容编辑面板
│   └── Resources/
│       ├── Info.plist                         # 相机/定位/相册权限声明
│       ├── PrivacyInfo.xcprivacy              # Privacy Manifest
│       └── Assets.xcassets
└── GeoWatermarkCameraTests/
    └── GeoWatermarkCameraTests.swift          # 坐标格式和映射核心测试
```

## 主数据流

1. `CameraService` 配置 `.photo` 会话并把画面交给 `CameraPreview`。
2. `LocationService` 获取坐标并用 `CLGeocoder` 生成可编辑地址。
3. 水印位置按取景框宽高保存为 `0...1` 的中心坐标；拖动时提供三分线、中心线和边缘吸附。
4. 按下快门时冻结时间、坐标、地址、文字和水印位置，避免处理期间内容变化。
5. `PhotoProcessingService` 应用原图方向元数据，通过 aspect-fill 逆变换映射水印位置，再用 Core Graphics 烧录水印。
6. 输出 JPEG 复制原元数据、将方向归一化为 1，并写入 GPS 字典；最后通过 Photos 新建资源，不改动任何原文件。
7. 相机会话约每秒抽取一帧交给 Vision，在设备端识别中英文；同一候选连续稳定出现后，才按用户设置提示或追加到自定义文字。

## MVP 边界

已实现拍照、实时水印预览/拖动、双指缩放、背景透明度、2 套模板、时间/坐标/地址/自定义文字、画面文字本地识别、地址编辑、前后摄像头、闪光灯、变焦、竖屏/左右横屏、GPS EXIF、正式 App Icon 和相册保存。视频、已有照片导入、批量处理与常用地址标签留给第二阶段。
