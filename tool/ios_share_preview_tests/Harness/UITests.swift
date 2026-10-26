import XCTest

final class ShareHarnessUITests: XCTestCase {
    private var app: XCUIApplication!
    private let themes = ["classic", "light", "dark", "black", "blue", "green", "mojian"]
    private let capturedThemes: Set<String> = ["classic", "dark", "mojian"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        _ = addUIInterruptionMonitor(withDescription: "照片与系统权限") { alert in
            let labels = [
                "允许", "Allow", "允许访问所有照片", "Allow Full Access",
                "允许添加", "Add Only", "Allow Adding Photos", "Allow Photos to Be Added", "好", "OK", "继续", "Continue"
            ]
            for label in labels where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        XCTAssertTrue(app.buttons["harness.shareImage"].waitForExistence(timeout: 30), "离线入口未出现")
    }

    func testWholeImagePixelsAndStitchBoundaries() {
        app.buttons["harness.longImage"].tap()
        let result = app.staticTexts["harness.longImage.result"]
        XCTAssertTrue(waitUntil(timeout: 180) {
            result.exists && (result.label.contains("校验通过") || result.label.contains("校验失败"))
        }, "长图校验未完成")
        XCTAssertTrue(result.label.contains("完整长图校验通过：750×10000"), result.label)
        capture("whole-image-pixel-check")
    }

    func testShareImageThemesPhotosShareCloseReopen() {
        openImagePreview()
        XCTAssertTrue(waitUntil(timeout: 180) { self.app.buttons["shareImage.save"].isEnabled }, "图片预览未就绪")

        for theme in themes {
            let button = element("shareImage.theme.\(theme)")
            XCTAssertTrue(button.waitForExistence(timeout: 15), "缺少主题按钮 \(theme)")
            XCTAssertTrue(waitUntil(timeout: 30) { button.isEnabled }, "主题按钮 \(theme) 未就绪")
            if !button.isHittable { self.app.scrollViews["shareImage.themes"].swipeLeft() }
            button.tap()
            XCTAssertTrue(
                waitUntil(timeout: 30) { button.isSelected || (button.value as? String) == "已选择" },
                "未切换到 \(theme)"
            )
            XCTAssertTrue(waitUntil(timeout: 90) { self.previewExists() }, "切换到 \(theme) 后预览消失")
            XCTAssertTrue(waitUntil(timeout: 90) {
                self.app.buttons["shareImage.save"].isEnabled
                    && self.app.staticTexts["shareImage.status"].label.contains("配色已更新")
            }, "主题渲染未完成")
            if !button.isHittable { self.app.scrollViews["shareImage.themes"].swipeLeft() }
            if capturedThemes.contains(theme) {
                capture("shareImage-theme-\(theme)")
            }
        }

        let save = app.buttons["shareImage.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 15), "缺少保存按钮")
        save.tap()
        // 模拟器首次相册权限由 interruption monitor 允许；真机相册写入不在本 UI 回归范围内。
        guard let feedback = waitForPhotoFeedback(timeout: 180) else {
            XCTFail("保存到相册后没有反馈")
            return
        }
        XCTAssertTrue(feedback.label.contains("已保存 1 张完整长图"), "保存到相册失败：\(feedback.label)")
        capture("shareImage-save-photos")

        let share = app.buttons["shareImage.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 15), "缺少分享按钮")
        share.tap()
        XCTAssertTrue(waitForActivity(timeout: 240), "长图分享后未出现系统 activity")
        capture("shareImage-activity")
        dismissActivity(returningTo: share)
        XCTAssertTrue(waitUntil(timeout: 30) { share.isHittable }, "取消系统 activity 后未返回预览")

        closePreview()
        XCTAssertTrue(app.buttons["harness.shareImage"].waitForExistence(timeout: 30), "关闭预览后未返回入口")

        openImagePreview()
        XCTAssertTrue(element("shareImage.theme.classic").exists, "重新打开后主题控件未恢复")
    }

    func testExportHtmlShareMarkdownFileCancel() {
        app.buttons["harness.export"].tap()
        let scope = app.segmentedControls["shareExport.scope"]
        let format = app.segmentedControls["shareExport.format"]
        XCTAssertTrue(scope.waitForExistence(timeout: 30), "导出页范围控件未出现")
        XCTAssertTrue(format.waitForExistence(timeout: 15), "导出页格式控件未出现")
        capture("shareExport-page")

        format.buttons.element(boundBy: 1).tap()
        scope.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(waitUntil(timeout: 10) { format.buttons.element(boundBy: 1).isSelected }, "未选中 HTML")
        XCTAssertTrue(waitUntil(timeout: 10) { scope.buttons.element(boundBy: 1).isSelected }, "未选中全部楼层")

        let share = app.buttons["shareExport.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 15), "缺少导出分享按钮")
        share.tap()
        XCTAssertTrue(waitForActivity(timeout: 240), "HTML 全部楼层分享未出现系统 activity")
        capture("shareExport-activity")
        dismissActivity(returningTo: share)
        XCTAssertTrue(waitUntil(timeout: 30) { share.isHittable }, "取消导出分享后未返回导出页")
        XCTAssertTrue(format.buttons.element(boundBy: 1).isSelected, "取消分享后 HTML 选项未保留")
        XCTAssertTrue(scope.buttons.element(boundBy: 1).isSelected, "取消分享后全部楼层选项未保留")

        format.buttons.element(boundBy: 0).tap()
        scope.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntil(timeout: 10) { format.buttons.element(boundBy: 0).isSelected }, "未选中 Markdown")
        XCTAssertTrue(waitUntil(timeout: 10) { scope.buttons.element(boundBy: 0).isSelected }, "未选中仅主帖")

        let save = app.buttons["shareExport.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 15), "缺少导出保存按钮")
        save.tap()
        XCTAssertTrue(waitForDocumentPicker(timeout: 120), "保存到文件未出现系统文件 sheet")
        cancelDocumentPicker()
        XCTAssertTrue(waitUntil(timeout: 30) { save.isHittable }, "取消文件 sheet 后未返回导出页")
        XCTAssertTrue(format.buttons.element(boundBy: 0).isSelected, "取消文件 sheet 后 Markdown 选项未保留")
        XCTAssertTrue(scope.buttons.element(boundBy: 0).isSelected, "取消文件 sheet 后仅主帖选项未保留")
        capture("shareExport-after-file-cancel")

        app.buttons["shareExport.close"].tap()
        XCTAssertTrue(app.buttons["harness.export"].waitForExistence(timeout: 30), "关闭导出页后未返回入口")
    }

    // MARK: - 元素查询

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func previewExists() -> Bool {
        for identifier in ["shareImage.preview", "shareImage.root", "shareImage.canvas", "shareImage.page"] {
            if element(identifier).exists { return true }
        }
        return app.buttons["shareImage.save"].isEnabled && app.buttons["shareImage.share"].isEnabled
    }

    private func openImagePreview() {
        app.buttons["harness.shareImage"].tap()
        XCTAssertTrue(element("shareImage.theme.classic").waitForExistence(timeout: 60), "图片分享界面未打开")
    }

    private func closePreview() {
        for identifier in ["shareImage.close", "shareImage.done", "shareImage.cancel"] {
            let button = app.buttons[identifier]
            if button.exists && button.isHittable {
                button.tap()
                return
            }
        }
        for title in ["关闭", "完成", "取消", "Close", "Done", "Cancel"] {
            let button = app.buttons[title]
            if button.exists && button.isHittable {
                button.tap()
                return
            }
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    // MARK: - 系统 activity / 文件 sheet

    private func waitForActivity(timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            self.element("shareExport.activity").exists
                || self.element("shareImage.activity").exists
                || self.app.otherElements["ActivityListView"].exists
                || self.app.otherElements["UIActivityContentView"].exists
                || self.app.collectionViews["ActivityListView"].exists
                || self.app.buttons["Close"].exists
                || self.app.buttons["Copy"].exists
                || self.app.buttons["拷贝"].exists
                || self.app.staticTexts["AirDrop"].exists
                || self.app.staticTexts["隔空投送"].exists
        }
    }

    private func dismissActivity(returningTo element: XCUIElement) {
        let list = app.otherElements["ActivityListView"]
        if app.buttons["Close"].exists {
            app.buttons["Close"].tap()
        } else if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
        } else if app.frame.width > 700 {
            // iPad 分享面板是 popover，点外部关闭。
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.1)).tap()
        } else if list.exists {
            list.swipeDown()
        } else {
            // 中文系统下点分享面板右上角，避免误点底层页面的“关闭”。
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.08)).tap()
        }

        if !waitUntil(timeout: 10, condition: {
            element.isHittable && !self.element("shareExport.activity").exists && !self.element("shareImage.activity").exists
        }) {
            if app.frame.width > 700 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.1)).tap()
            } else if list.exists {
                list.swipeDown()
            }
        }
    }

    private func waitForDocumentPicker(timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            self.element("shareExport.documentPicker").exists
                || self.app.buttons["Save"].exists
                || self.app.navigationBars["On My iPhone"].exists
                || self.app.navigationBars["On My iPad"].exists
                || self.app.buttons["Cancel"].exists
                || self.app.buttons["取消"].exists
                || self.app.navigationBars["Browse"].exists
                || self.app.navigationBars["浏览"].exists
                || self.app.navigationBars["Recents"].exists
                || self.app.navigationBars["最近使用"].exists
                || self.app.navigationBars["保存到文件"].exists
        }
    }

    private func cancelDocumentPicker() {
        for title in ["Cancel", "取消"] {
            let button = app.buttons[title]
            if button.exists && button.isHittable {
                button.tap()
                return
            }
        }
        let picker = element("shareExport.documentPicker")
        let start = picker.exists
            ? picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
            : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(waitUntil(timeout: 15) { !self.element("shareExport.documentPicker").exists }, "系统文件面板未关闭")
    }

    private func waitForPhotoFeedback(timeout: TimeInterval) -> XCUIElement? {
        let feedback = app.staticTexts["shareImage.status"]
        let deadline = Date().addingTimeInterval(timeout)
        let started = Date()
        var lastTap = Date.distantPast
        while Date() < deadline {
            if feedback.exists && (feedback.label.contains("已保存") || feedback.label.contains("失败") || feedback.label.contains("未获得")) { return feedback }
            if Date().timeIntervalSince(started) > 5, Date().timeIntervalSince(lastTap) > 5 {
                // 相册权限弹窗出现后，任意交互会交给 interruption monitor 处理。
                app.tap()
                lastTap = Date()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return feedback.exists && feedback.label.contains("已保存") ? feedback : nil
    }

    // MARK: - 工具

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        } while Date() < deadline
        return condition()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
