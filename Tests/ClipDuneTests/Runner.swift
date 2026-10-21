import Foundation

@main
struct CheckRunner {
    @MainActor
    static func main() async {
        let checks: [(String, @MainActor () async throws -> Void)] = [
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
            ("重定向不泄漏授权", { try UpdateTests().redirectPolicyDoesNotLeakAuthorization() }),
            ("ZIP 路径与符号链接", { try UpdateTests().zipEntriesRejectTraversalAndSymlinks() }),
            ("原子替换与回滚", { try UpdateTests().atomicSwapAndRollbackPreserveBothVersions() }),
            ("重启失败触发安装事务回滚", { try UpdateTests().failedRelaunchRollsBackThroughProductionTransaction() }),
            ("安装事务保留旧版本", { try UpdateTests().successfulTransactionPreservesOldApplicationAsBackup() }),
            ("设置持久化与格式切换", { try UpdateTests().preferencesRoundTripAndPasteOverride() }),
            ("拒绝错误粘贴目标", { try UpdateTests().destinationPolicyRejectsWrongApplicationsAndWindows() }),
            ("系统权限页定位", { try UpdateTests().permissionURLsTargetCorrectPanes() }),
            ("Release 资产选择", { try UpdateTests().releaseMetadataRequiresUniqueAssets() })
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
