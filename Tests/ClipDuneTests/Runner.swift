import Foundation

@main
struct CheckRunner {
    @MainActor
    static func main() async {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("同一窗口无辅助功能输入控件仍可粘贴", { PasteFocusTests().unchangedWindowWithoutAccessibilityElementCanPaste() }),
            ("窗口回退需肯定证据且不得与切换矛盾", { PasteFocusTests().windowFallbackRequiresPositiveIdentityAndNoContradictions() }),
            ("已知焦点丢失和权限失败不回退", { PasteFocusTests().knownChangedOrLostFocusDoesNotUseWindowFallback() }),
            ("焦点恢复需要持续稳定", { PasteFocusTests().recoveryWaitsForContinuousStableFocus() }),
            ("辅助功能未提供属性与读取错误分开", { PasteFocusTests().unsupportedAXAttributesAreNotConfusedWithErrors() }),
            ("窗口编号识别切换并拒绝浮层回退", { try await PasteFocusTests().windowServerTracksWindowSwitchesWithoutReadingContents() }),
            ("粘贴降级原因分开提示", { PasteFocusTests().failureMessagesExplainWhatWasRejected() }),
            ("使用前移且保留原文与采集时间", { try await HistoryActivityTests().successfulUseMovesWithoutChangingContentOrCaptureTime() }),
            ("去重保留不同粘贴格式", { try await HistoryActivityTests().deduplicationRetainsFormattingDifferences() }),
            ("时间筛选与过期依据最近使用", { try await HistoryActivityTests().filtersAndExpirationUseRecentActivity() }),
            ("降容清理最久未使用且保护收藏", { try await HistoryActivityTests().capacityEvictsLeastRecentlyUsedAndProtectsPins() }),
            ("降容和新增失败完整回滚", { try await HistoryActivityTests().rejectedReductionAndCaptureRollBack() }),
            ("条数清理依据最近使用", { try await HistoryActivityTests().countLimitAlsoUsesRecentActivity() }),
            ("最近使用备份重开且不被旧备份倒退", { try await HistoryActivityTests().archiveAndReopenPreserveRecencyWithoutRewinding() }),
            ("旧数据库活动回填与旧版写入兼容", { try await HistoryActivityTests().legacyDatabaseBackfillsAndLegacyWriterUpdatesActivity() }),
            ("容量偏好持久化与异常值回退", { try HistoryActivityTests().storagePreferencesPersistAndRejectInvalidValues() }),
            ("旧备份兼容与异常活动和超大备份拒绝", { try await HistoryActivityTests().legacyAndInvalidActivityArchivesAreHandledSafely() }),
            ("存储与重开保真", { try await HistoryStoreTests().testPersistsAndReopensWithoutLosingRepresentations() }),
            ("去重与收藏状态", { try await HistoryStoreTests().testDuplicateMovesToFrontAndPreservesPin() }),
            ("中文与全文搜索", { try await HistoryStoreTests().testShortChineseAndTrigramSearch() }),
            ("检索字面量与注入", { try await HistoryStoreTests().testSearchTreatsOperatorsAndQuotesAsLiteralText() }),
            ("删除同步清理索引", { try await HistoryStoreTests().testDeletingAlsoRemovesSearchEntries() }),
            ("条数清理保护收藏", { try await HistoryStoreTests().testCountLimitDoesNotRemovePinnedItems() }),
            ("过期清理保护收藏", { try await HistoryStoreTests().testExpirationKeepsPins() }),
            ("容量不足事务回滚", { try await HistoryStoreTests().testCapacityFailureRollsBackNewCapture() }),
            ("容量清理最早历史", { try await HistoryStoreTests().testByteLimitEvictsOldestUnpinnedItem() }),
            ("大小与类型校验", { try await HistoryStoreTests().testRejectsOversizedAndUnknownRepresentations() }),
            ("清空与索引一致性", { try await HistoryStoreTests().testClearPreservesPinnedAndDoesNotResurrectSearchRows() }),
            ("备份往返", { try await HistoryStoreTests().testArchiveRoundTripPreservesPins() }),
            ("导入尊重排除策略", { try await HistoryStoreTests().testArchiveRespectsExcludedApplications() }),
            ("无效备份不损坏历史", { try await HistoryStoreTests().testMalformedImportDoesNotDestroyHistory() }),
            ("数据库文件权限", { try await HistoryStoreTests().testDatabasePermissionsArePrivate() }),
            ("指纹与条目顺序", { HistoryStoreTests().testFingerprintIsOrderIndependentWithinItemButNotAcrossItems() }),
            ("敏感标记拦截", { try PasteboardTests().testConfidentialMarkerPreventsCapture() }),
            ("应用排除拦截", { try PasteboardTests().testExcludedApplicationPreventsCapture() }),
            ("富文本与自身写入抑制", { try PasteboardTests().testRichTextRepresentationsArePreservedAndOwnWritesIgnored() }),
            ("纯文本粘贴", { try PasteboardTests().testPlainTextPasteOmitsFormatting() }),
            ("多文件引用保真", { try PasteboardTests().testMultipleFileReferencesStaySeparate() }),
            ("暂停与隐私策略", { PasteboardTests().testPrivacyPolicyHandlesPauseAndKnownMarkers() }),
            ("更新签名拒绝篡改", { try UpdateTests().signatureRejectsTamperingAndWrongKey() }),
            ("更新包哈希与大小", { try UpdateTests().archiveHashAndLengthAreVerified() }),
            ("更新系统与架构校验", { try UpdateTests().architectureAndSystemCompatibility() }),
            ("Universal 更新清单签名与双架构兼容", { try UpdateTests().universalManifestSupportsBothArchitectures() }),
            ("重定向不泄漏授权", { try UpdateTests().redirectPolicyDoesNotLeakAuthorization() }),
            ("ZIP 路径与符号链接", { try UpdateTests().zipEntriesRejectTraversalAndSymlinks() }),
            ("原子替换与回滚", { try UpdateTests().atomicSwapAndRollbackPreserveBothVersions() }),
            ("重启失败触发安装事务回滚", { try UpdateTests().failedRelaunchRollsBackThroughProductionTransaction() }),
            ("安装事务保留旧版本", { try UpdateTests().successfulTransactionPreservesOldApplicationAsBackup() }),
            ("设置持久化与格式切换", { try UpdateTests().preferencesRoundTripAndPasteOverride() }),
            ("拒绝错误粘贴目标", { try UpdateTests().destinationPolicyRejectsWrongApplicationsAndWindows() }),
            ("系统权限页定位", { try UpdateTests().permissionURLsTargetCorrectPanes() }),
            ("Release 资产选择", { try UpdateTests().releaseMetadataRequiresUniqueAssets() }),
            ("重命名检索与收藏去重", { try await CardMetadataTests().renameSearchPinDuplicateAndReopen() }),
            ("重命名校验与注入防护", { try await CardMetadataTests().rejectsInvalidTitlesWithoutMutatingData() }),
            ("名称类型时间收藏组合检索", { try await CardMetadataTests().combinedTypeDateNameAndPinFilters() }),
            ("时间筛选时区与夏令时", { CardMetadataTests().calendarFiltersRespectDSTAndHalfOpenBounds() }),
            ("名称备份与旧归档兼容", { try await CardMetadataTests().namedArchiveRoundTripAndLegacyImport() }),
            ("旧数据库回填与删除一致性", { try await CardMetadataTests().backfillsOldRowsAndKeepsLegacySchemaWritable() }),
            ("新类型旧载荷兼容", { try CardMetadataTests().newKindsKeepLegacyPayloadReadable() }),
            ("八种类型与原始表示往返", { try CardMetadataTests().codecHandlesEightKindsAndOpaqueBytes() }),
            ("字符数图片数据量文件引用数", { try await CardMetadataTests().summaryShowsCharactersImageBytesAndFileCount() }),
            ("八种内容类型独立筛选", { try await CardMetadataTests().everyKindIsIndependentlySearchable() }),
            ("旧版本载荷和写入语句兼容", { try await CardMetadataTests().oldVersionCanReadPayloadAndInsertOriginalSchema() }),
            ("面板宽屏和负坐标显示器", { CardMetadataTests().panelUsesScreenWidthWithSmallSafeInsets() })
        ]
        for (name, check) in checks {
            let previous = CheckResults.shared.failures
            do { try await check() }
            catch { fail("\(name)：\(error.localizedDescription)") }
            print("\(CheckResults.shared.failures == previous ? "PASS" : "FAIL") \(name)")
        }
        print("\(checks.count) scenarios; \(CheckResults.shared.assertions) assertions; \(CheckResults.shared.failures) failures")
        exit(CheckResults.shared.failures == 0 ? 0 : 1)
    }
}
