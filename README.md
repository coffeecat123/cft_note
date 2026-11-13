# CFT Note

<p align="center">
  <a href="https://github.com/coffeecat123/cft_note/releases/latest">
    <img src="https://img.shields.io/github/v/release/coffeecat123/cft_note?style=for-the-badge&label=Release&logo=github" alt="Latest Release">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge" alt="MIT License">
  </a>
</p>

使用 Flutter 打造的手寫筆記 App，支援 Apple Pencil / 觸控筆，可匯入 PDF 批註、插入圖片，並匯出為向量 PDF。

> A handwriting note app built with Flutter, designed for stylus and Apple Pencil. Annotate PDFs, insert images, and export to vector PDF.

## 下載

到 [Releases](https://github.com/coffeecat123/cft_note/releases/latest) 頁面下載最新版本。

## 功能特色

### 筆記櫃 (Shelf)
- 以筆記本、資料夾整理筆記，支援巢狀資料夾與拖曳移動
- 重新命名、製作副本、刪除（可選擇連同內容刪除）
- 可依修改時間排序，並在卡片檢視與精簡清單間切換
- 筆記本可匯出為 PDF

### 畫布 (Canvas)
- **筆刷工作室**：鋼筆、原子筆、麥克筆預設，可調整粗細、壓感、防手抖與平滑度（基於 `perfect_freehand`）
- **筆畫橡皮擦**：可調整半徑
- **套索工具**：圈選後剪下、複製、刪除、截圖，並可貼上筆跡或圖片
- **色彩工作台**：HSB 調色、收藏顏色、最近使用顏色
- **復原 / 重做**
- **防誤觸 (Palm rejection)**：僅接受 Pencil 輸入
- **頁面顯示方式**：單頁、往下連續捲動、往右連續捲動
- **頁面背景**：紙張顏色、橫線 / 直線 / 方格、格線間隔，可套用到目前頁面或所有空白頁

### PDF 與圖片
- 匯入 PDF 並在上面批註（基於 `pdfrx`）
- 在任意頁面後插入空白頁或 PDF
- 從相簿、檔案或剪貼簿插入圖片，可平移、縮放、刪除
- 截圖：複製到剪貼簿、存到相簿或儲存為檔案
- 匯出為向量 PDF（基於 `syncfusion_flutter_pdf`）

### 設定
- **主題**：跟隨系統 / 淺色 / 深色
- **語言**：跟隨系統 / 繁體中文 / English，切換後立即生效
- **App 資訊**：版本與 GitHub 連結

## 專案結構

```
lib/
├── main.dart                      # Entry point: load settings, restore canvas prefs
├── app/
│   ├── settings/                  # Global settings (theme, language) and app info
│   │   ├── app_settings.dart
│   │   ├── app_info.dart
│   │   └── settings_dialog.dart
│   └── theme/                     # Light / dark themes
├── core/
│   ├── algorithms/                # Geometry: ray casting, segment math
│   ├── engine/                    # Repaint signal, tile planner
│   └── i18n/app_strings.dart      # Lightweight i18n (no codegen)
└── features/
    ├── canvas/                    # Models, commands (undo/redo), controllers, toolbars, painters
    ├── document/                  # Pages, backgrounds, images, storage
    ├── pdf_import_export/         # PDF import/export, image picking, clipboard, screenshots
    └── shelf/                     # Notebooks, folders, list and card views
```

## 開發環境

- [Flutter SDK](https://docs.flutter.dev/get-started/install)（Dart 3 以上）
- iOS：Xcode；Android：Android Studio / Android SDK

### 主要套件

| 套件 | 用途 |
| --- | --- |
| `perfect_freehand` | 壓感筆跡輪廓 |
| `pdfrx` | PDF 渲染 |
| `syncfusion_flutter_pdf` | 向量 PDF 匯出 |
| `file_picker` / `image_picker` | 選取檔案 / 圖片 |
| `path_provider` | 取得儲存路徑 |
| `super_clipboard` | 剪貼簿圖片讀寫 |
| `share_plus` | 分享檔案 |
| `gal` | 儲存到相簿 |
| `package_info_plus` | 讀取 App 版本號（App 資訊視窗） |
| `url_launcher` | 開啟 GitHub 連結 |

## 執行

```bash
flutter pub get
flutter run
```

建置發佈版本：

```bash
flutter build apk --release      # Android
flutter build ios --release      # iOS
```

## 多語系

字串集中在 `lib/core/i18n/app_strings.dart`，每個字串在同一處同時寫繁體中文與 English：

```dart
String get appInfo => _t('App 資訊', 'App info');
```

- Widget 內使用 `S.of(context)`，語言切換時會自動重建
- 沒有 `context` 的地方（controller / service）使用 `S.current`

## 新增設定項目

1. 在 `AppSettings` 加欄位，並補上 `toJson` / `fromJson`
2. 在 `settings_dialog.dart` 的 `_SettingsBody` 多放一個 `_Section`

設定會存成 `cft_app_settings.json`，讀取失敗時使用預設值，不影響啟動。

## 版本號

App 資訊視窗的版本由 `package_info_plus` 在執行時讀取，來源是 `pubspec.yaml`：

```yaml
version: 1.0.0+1   # 1.0.0 = 版本，1 = 建置編號
```

發佈新版時只需修改 `pubspec.yaml`，不用改程式碼。

## 授權

本專案以 [MIT License](LICENSE) 授權。