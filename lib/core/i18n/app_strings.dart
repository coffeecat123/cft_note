// lib/core/i18n/app_strings.dart
//
// 輕量多語系：不需要額外套件、不需要 codegen。
//  - 每個字串在同一處同時寫 繁體中文 / English，新增或修改時不會漏掉其中一邊。
//  - Widget 內用 `S.of(context)`：語言切換時會自動重建。
//  - 沒有 context 的地方 (controller / service) 用 `S.current`。
import 'package:flutter/material.dart';

import '../../app/settings/app_settings.dart';

/// 使用者可選的語言
enum AppLanguage {
  /// 跟隨系統 (系統是中文就用中文，其餘用英文)
  system,
  zhTW,
  en,
}

class S {
  final bool zh;
  const S._(this.zh);

  static const S zhTw = S._(true);
  static const S en = S._(false);

  /// 目前生效的語言。AppSettings 變更語言時會更新，供沒有 context 的程式碼使用。
  static S current = zhTw;

  /// 在 build 中呼叫 → 語言改變時 Widget 會自動重建
  static S of(BuildContext context) {
    final settings = AppSettingsScope.maybeOf(context);
    return settings?.strings ?? current;
  }

  static S forLanguage(AppLanguage lang, {Locale? systemLocale}) {
    switch (lang) {
      case AppLanguage.zhTW:
        return zhTw;
      case AppLanguage.en:
        return en;
      case AppLanguage.system:
        final code = (systemLocale ??
                WidgetsBinding.instance.platformDispatcher.locale)
            .languageCode;
        return code == 'zh' ? zhTw : en;
    }
  }

  String _t(String zhText, String enText) => zh ? zhText : enText;

  /// 英文單複數：1 page / 2 pages
  String _n(int n, String one, String many) => n == 1 ? one : many;

  // ============================================================
  // 通用
  // ============================================================
  String get appTitle => 'CFT Note';
  String get cancel => _t('取消', 'Cancel');
  String get delete => _t('刪除', 'Delete');
  String get create => _t('建立', 'Create');
  String get save => _t('儲存', 'Save');
  String get confirm => _t('確認', 'OK');
  String get rename => _t('重新命名', 'Rename');
  String get copy => _t('複製', 'Copy');
  String get cut => _t('剪下', 'Cut');
  String get paste => _t('貼上', 'Paste');
  String get share => _t('分享', 'Share');
  String get more => _t('更多', 'More');
  String get name => _t('名稱', 'Name');
  String get listSeparator => _t('、', ', ');

  // ============================================================
  // 設定
  // ============================================================
  String get settings => _t('設定', 'Settings');
  String get appearance => _t('外觀', 'Appearance');
  String get theme => _t('主題', 'Theme');
  String get themeSystem => _t('跟隨系統', 'System');
  String get themeLight => _t('淺色', 'Light');
  String get themeDark => _t('深色', 'Dark');
  String get language => _t('語言', 'Language');
  String get languageSystem => _t('跟隨系統', 'System');
  String get languageZhTw => '繁體中文';
  String get languageEn => 'English';
  String get close => _t('關閉', 'Close');

  // App 資訊
  String get appInfo => _t('App 資訊', 'App info');
  String get appVersion => _t('版本', 'Version');

  // ============================================================
  // 書架
  // ============================================================
  String get myShelf => _t('我的筆記櫃', 'My Notebooks');
  String get untitledNotebook => _t('未命名筆記', 'Untitled Note');
  String get untitledFolder => _t('未命名資料夾', 'Untitled Folder');
  String get defaultNotebookTitle => _t('日常速記', 'Quick Notes');

  String get deleteFolder => _t('刪除資料夾', 'Delete Folder');
  String confirmDeleteEmptyFolder(String name) =>
      _t('確定要刪除空資料夾「$name」嗎？', 'Delete the empty folder “$name”?');
  String deleteFolderMovesContents(String name, int notebooks, int folders) =>
      _t(
        '刪除「$name」後，裡面的 $notebooks 本筆記本與 $folders 個子資料夾會移到上一層，不會被刪除。',
        'After deleting “$name”, its $notebooks '
            '${_n(notebooks, 'notebook', 'notebooks')} and $folders '
            '${_n(folders, 'subfolder', 'subfolders')} will move up one level. '
            'Nothing else is deleted.',
      );
  String get deleteWithContents => _t('連同內容刪除…', 'Delete with contents…');
  String get deleteWithContentsTitle =>
      _t('連同內容一併刪除？', 'Delete everything inside?');
  String permanentlyDeleteFolder(String name, int notebooks, int folders) =>
      _t(
        '將永久刪除「$name」以及其中的 $notebooks 本筆記本與 $folders 個子資料夾，無法復原。',
        'This will permanently delete “$name” along with its $notebooks '
            '${_n(notebooks, 'notebook', 'notebooks')} and $folders '
            '${_n(folders, 'subfolder', 'subfolders')}. This can’t be undone.',
      );
  String get deletePermanently => _t('永久刪除', 'Delete Permanently');

  String get newFolder => _t('新增資料夾', 'New Folder');
  String get folderName => _t('資料夾名稱', 'Folder name');
  String get renameFolder => _t('重新命名資料夾', 'Rename Folder');

  String get deleteNotebook => _t('刪除筆記本', 'Delete Notebook');
  String confirmDeleteNotebook(String title) =>
      _t('確定要刪除「$title」嗎？', 'Delete “$title”?');

  String get exportingPdf => _t('正在合成向量 PDF...', 'Building vector PDF...');
  String get pdfExported => _t('PDF 匯出成功！', 'PDF exported!');
  String get exportAsPdf => _t('匯出為 PDF', 'Export as PDF');
  String get exportDialogTitle => _t('匯出筆記為 PDF', 'Export notebook as PDF');

  String movedTo(String item, String target) =>
      _t('已將「$item」移到「$target」', 'Moved “$item” to “$target”');
  String dropHereToMove(String parent) =>
      _t('拖到這裡，移到「$parent」', 'Drop here to move to “$parent”');

  String get sortBy => _t('排序方式', 'Sort by');
  String get modifiedTime => _t('修改時間', 'Date modified');
  String get ascending => _t('升序', 'Ascending');
  String get descending => _t('降序', 'Descending');
  String get switchToList => _t('切換為精簡清單', 'Switch to compact list');
  String get switchToGrid => _t('切換為小圖示', 'Switch to grid');
  String get backUpOneLevel => _t('返回上一層', 'Back');
  String continueEditing(int n) => _t('繼續編輯 ($n)', 'Continue editing ($n)');
  String get info => _t('內容', 'Contents');
  String get exitAppTitle => _t('離開 App？', 'Exit the app?');
  String get exitAppMessage => _t('確定要離開 CFT Note 嗎？', 'Do you want to exit CFT Note?');
  String get exit => _t('離開', 'Exit');

  String itemCount(int n) => _t('$n 個項目', '$n ${_n(n, 'item', 'items')}');
  String pageCount(int n) => _t('$n 頁', '$n ${_n(n, 'page', 'pages')}');
  String notebookSubtitle(int pages, int current, String date) => _t(
        '$pages 頁 (第 $current 頁) • $date',
        '$pages ${_n(pages, 'page', 'pages')} (page $current) • $date',
      );
  String minutesAgo(int n) =>
      _t('$n 分鐘前', '$n ${_n(n, 'min', 'mins')} ago');
  String hoursAgo(int n) => _t('$n 小時前', '$n ${_n(n, 'hr', 'hrs')} ago');

  String get addEllipsis => _t('新增...', 'New...');
  String get newNotebook => _t('新增筆記本', 'New Notebook');
  String get newItem => _t('新增項目', 'New Item');
  String get importPdf => _t('匯入 PDF', 'Import PDF');
  String get importPdfFailed =>
      _t('無法匯入這個 PDF', 'Could not import this PDF');
  String get notebookName => _t('筆記本名稱', 'Notebook name');
  String get chooseCoverColor => _t('選擇封面顏色', 'Choose a cover color');
  String get duplicate => _t('製作副本', 'Duplicate');
  String get copySuffix => _t('(副本)', '(Copy)');

  String loadError(Object e) => _t(
        '讀取存檔時發生錯誤，為保護現有資料，本次使用期間不會寫入存檔。\n$e',
        'Couldn’t read your saved data. To protect it, nothing will be '
            'written to disk during this session.\n$e',
      );

  // ============================================================
  // 畫布 / 工具列
  // ============================================================
  String get backToShelf => _t('返回我的筆記櫃', 'Back to My Notebooks');
  String get openBrushStudio => _t('開啟筆刷工作室', 'Open Brush Studio');
  String get brush => _t('筆刷', 'Brush');
  String get eraser => _t('筆畫橡皮擦', 'Stroke eraser');
  String get eraserSettings => _t('橡皮擦大小', 'Eraser size');
  String get eraserSize => _t('半徑', 'Radius');
  String get lasso => _t('套索工具', 'Lasso');
  String get insertImage => _t('插入圖片', 'Insert image');
  String get imageMode => _t('圖片模式', 'Image mode');
  String get undo => _t('復原', 'Undo');
  String get redo => _t('重做', 'Redo');
  String get pageList => _t('頁面列表', 'All pages');
  String get prevPage => _t('上一頁', 'Previous page');
  String get nextPage => _t('下一頁', 'Next page');
  String get insertAfterThisPage => _t('在此頁後插入...', 'Insert after this page...');
  String get insertBlankAfter =>
      _t('在此頁後插入空白頁', 'Insert blank page after this one');
  String get insertPdfAfter => _t('在此頁後插入 PDF...', 'Insert PDF after this one...');
  String allPagesTitle(int n) =>
      _t('所有頁面 (共 $n 頁)', 'All pages ($n)');

  String get sysGallery => _t('系統圖庫', 'Photo library');
  String get sysFiles => _t('系統檔案', 'Files');
  String get imageLoadFailed => _t('無法載入這張圖片', 'Couldn’t load this image');
  String imagePickFailed(Object e) =>
      _t('選取圖片失敗：$e', 'Couldn’t pick the image: $e');

  String get pageLayout => _t('頁面顯示方式', 'Page layout');
  String get layoutSingle => _t('單頁顯示', 'Single page');
  String get layoutVertical => _t('往下連續捲動', 'Continuous (vertical)');
  String get layoutHorizontal => _t('往右連續捲動', 'Continuous (horizontal)');

  String get deleteCurrentPage => _t('刪除當前頁面', 'Delete current page');
  String get deleteCurrentPageKeepOne =>
      _t('刪除當前頁面 (至少保留一頁)', 'Delete current page (keep at least one)');
  String confirmDeletePage(int n) => _t(
        '確定要刪除第 $n 頁嗎？頁面上的筆跡會一併刪除，無法復原。',
        'Delete page $n? Everything on it will be deleted. This can’t be undone.',
      );

  String get clearCurrentPage => _t('清除當前頁面內容', 'Clear current page');
  String confirmClearPage(int n) => _t(
        '確定要清除第 $n 頁的所有筆跡與圖片嗎？只會保留背景或 PDF 內容。(可用復原還原)',
        'Clear all strokes and images on page $n? Only the background or PDF stays. (You can undo this.)',
      );
  String get clear => _t('清除', 'Clear');
  String get pageCleared => _t('已清除當前頁面', 'Page cleared');
  String get pageAlreadyEmpty => _t('當前頁面沒有內容', 'Nothing to clear');

  String get palmRejection => _t('防誤觸', 'Palm rejection');
  String get palmRejectionOn => _t('防誤觸：開 (僅限 Pencil)', 'Palm rejection on (pen only)');
  String get palmRejectionOff => _t('防誤觸：關', 'Palm rejection off');
  String get stateOn => _t('開', 'On');
  String get stateOff => _t('關', 'Off');

  // 套索 / 截圖
  String get screenshot => _t('截圖', 'Screenshot');
  String get pasteStrokes => _t('貼上筆跡', 'Paste strokes');
  String get pasteImage => _t('貼上圖片', 'Paste image');
  String get screenshotOutsidePage =>
      _t('截圖失敗：圈選範圍在紙張之外', 'Screenshot failed: the selection is outside the page');
  String get screenshotNamePart => _t('截圖', 'screenshot');
  String get saveScreenshotTitle => _t('儲存截圖', 'Save screenshot');
  String operationFailed(Object e) => _t('操作失敗：$e', 'Action failed: $e');
  String get imageCopied => _t('已複製圖片到剪貼簿', 'Image copied to clipboard');
  String get saveToGallery => _t('存到相簿', 'Save to Photos');
  String get noGalleryPermission => _t(
        '沒有相簿存取權限，請到系統設定開啟',
        'No photo library access. Please enable it in system settings.',
      );
  String get savedToGallery => _t('已存到相簿', 'Saved to Photos');
  String get saveFile => _t('儲存檔案', 'Save file');
  String get screenshotSaved => _t('截圖已儲存', 'Screenshot saved');

  // HUD 提示
  String get imageDeleted => _t('已刪除圖片', 'Image deleted');
  String get undone => _t('已復原', 'Undone');
  String get nothingToUndo => _t('無可復原項目', 'Nothing to undo');
  String get clipboardNoImage => _t('剪貼簿沒有圖片', 'No image on the clipboard');
  String strokesCount(int n) => _t('$n 筆', '$n ${_n(n, 'stroke', 'strokes')}');
  String imagesCount(int n) =>
      _t('$n 張圖片', '$n ${_n(n, 'image', 'images')}');
  String copiedX(String x) => _t('已複製 $x', 'Copied $x');
  String cutX(String x) => _t('已剪下 $x', 'Cut $x');
  String deletedX(String x) => _t('已刪除 $x', 'Deleted $x');
  String get pasted => _t('已貼上', 'Pasted');

  // 筆刷
  String get brushStudio => _t('筆刷工作室 (Brush Studio)', 'Brush Studio');
  String get presetFountain => _t('鋼筆 (書法)', 'Fountain pen');
  String get presetBallpoint => _t('原子筆 (筆記)', 'Ballpoint');
  String get presetMarker => _t('麥克筆 (繪圖)', 'Marker');
  String get brushSize => _t('粗細 (Size)', 'Size');
  String get brushThinning => _t('壓感變化 (Thinning)', 'Pressure');
  String get brushStreamline => _t('防手抖牽引 (Streamline)', 'Stabilizer');
  String get brushSmoothing => _t('平滑修正 (Smoothing)', 'Smoothing');

  // 顏色
  String get removeFavoriteTitle => _t('刪除收藏顏色', 'Remove favorite color');
  String get removeFavoriteMessage =>
      _t('確定要從喜愛清單中移除此顏色？', 'Remove this color from your favorites?');
  String get confirmRemove => _t('確定刪除', 'Remove');
  String get colorStudio => _t('色彩工作台', 'Color Studio');
  String get hueLabel => _t('H (色相)', 'H (Hue)');
  String get saturationLabel => _t('S (彩度)', 'S (Saturation)');
  String get brightnessLabel => _t('B (明度)', 'B (Brightness)');
  String get favoriteColors => _t('喜愛的顏色 (長按刪除)', 'Favorites (long-press to remove)');
  String get saveCurrentColor => _t('收藏當前色', 'Save current');
  String get recentColors => _t('最近使用 (畫過自動收錄)', 'Recent (added automatically)');

  // ============================================================
  // ★ 頁面背景 (空白頁設定)
  // ============================================================
  String get pageBackground => _t('頁面背景', 'Page background');
  String get paperColor => _t('紙張顏色', 'Paper color');
  String get customColor => _t('自訂顏色', 'Custom color');
  String get gridLines => _t('格線', 'Grid lines');
  String get gridNone => _t('無', 'None');
  String get gridHorizontal => _t('橫線', 'Horizontal');
  String get gridVertical => _t('直線', 'Vertical');
  String get gridBoth => _t('方格', 'Grid');
  String get applyTo => _t('套用範圍', 'Apply to');
  String get scopeCurrentPage => _t('僅目前頁面', 'This page only');
  String get scopeAllBlankPages => _t('所有空白頁', 'All blank pages');
  String get scopeAllBlankPagesHint =>
      _t('套用到此筆記本的所有空白頁 (PDF 頁面不受影響)',
          'Applies to every blank page in this notebook (PDF pages are not affected)');
  String get newPageStyle => _t('新增空白頁的樣式', 'Style for new blank pages');
  String get newPageLastUsed => _t('上次修改的', 'Last used');
  String get newPageSameAsCurrent => _t('與目前頁面相同', 'Same as current');
  String get currentPageIsPdf => _t(
        '目前是 PDF 頁面，背景設定只對空白頁有效。可切換到「所有空白頁」一次修改。',
        'This is a PDF page, so these settings only affect blank pages. '
            'Switch to “All blank pages” to change them all at once.',
      );
  String get gridSpacing => _t('格線間隔', 'Grid spacing');
  String get recentBackgrounds => _t('最近使用 (長按移除)', 'Recent (long-press to remove)');
  String get noBlankPages =>
      _t('這本筆記本沒有空白頁。', 'This notebook has no blank pages.');

  // ============================================================
  // 儲存 (警告訊息)
  // ============================================================
  String saveFailed(String file, Object e) =>
      _t('儲存「$file」失敗：$e', 'Couldn’t save “$file”: $e');
  String fileCorruptMovedAside(String file, String aside) => _t(
        '「$file」內容損毀，已另存為 $aside',
        '“$file” is corrupted and was moved to $aside',
      );
  String fileCorruptCantMove(String file, Object e) => _t(
        '「$file」內容損毀且無法另存：$e',
        '“$file” is corrupted and couldn’t be moved aside: $e',
      );
  String get restoredFromBackup => _t(
        '偵測到資料檔異常，已從備份還原 (可能遺失最近一次的修改)。',
        'A data file was damaged and has been restored from backup '
            '(your most recent changes may be lost).',
      );
  String get noUsableBackup => _t(
        '資料檔損毀且沒有可用的備份，已保留原檔供救援。',
        'A data file is corrupted and no usable backup exists. '
            'The original file was kept for recovery.',
      );
  String foldersEncodeFailed(Object e) =>
      _t('資料夾資料無法編碼，已略過儲存：$e', 'Couldn’t encode folders; save skipped: $e');
  String notebooksEncodeFailed(Object e) => _t(
        '筆記資料無法編碼，已保留先前的存檔：$e',
        'Couldn’t encode notes; your previous save was kept: $e',
      );
  String notebooksSkipped(int n, String file) => _t(
        '有 $n 本筆記無法讀取，原始資料已另存為 $file',
        '$n ${_n(n, 'notebook', 'notebooks')} couldn’t be read. '
            'The raw data was saved as $file',
      );
  String notebooksSkippedNoDump(int n, Object e) => _t(
        '有 $n 本筆記無法讀取，且無法另存原始資料：$e',
        '$n ${_n(n, 'notebook', 'notebooks')} couldn’t be read, and the raw '
            'data couldn’t be saved: $e',
      );
  String canvasPrefsEncodeFailed(Object e) =>
      _t('畫布設定無法編碼，已略過儲存：$e', 'Couldn’t encode canvas settings; save skipped: $e');
  String appSettingsEncodeFailed(Object e) =>
      _t('設定無法編碼，已略過儲存：$e', 'Couldn’t encode settings; save skipped: $e');
}