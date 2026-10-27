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

    func testShareEntryLoadingAndCancel() {
        app.buttons["harness.entryLoading"].tap()
        XCTAssertTrue(element("shareEntry.root").waitForExistence(timeout: 30), "连接中入口未显示")
        XCTAssertTrue(element("shareEntry.progress").exists, "连接中缺少进度状态")
        XCTAssertTrue(app.staticTexts["shareEntry.status"].label.contains("正在"), "连接中状态文案缺失")
        for identifier in ["recover", "clearSession", "diagnostics", "image", "export", "continue"] {
            XCTAssertFalse(app.buttons["shareEntry.\(identifier)"].exists, "连接中出现多余按钮：\(identifier)")
        }
        XCTAssertLessThan(element("shareEntry.root").frame.height, app.frame.height * 0.75, "连接中页面未收紧")
        capture("shareEntry-loading")
        app.buttons["shareEntry.close"].tap()
        XCTAssertTrue(app.buttons["harness.entryLoading"].waitForExistence(timeout: 30), "连接中取消未返回入口")
    }

    func testShareEntryFailureRetryAndActions() {
        app.buttons["harness.entryRecovery"].tap()
        let recover = app.buttons["shareEntry.recover"]
        XCTAssertTrue(recover.waitForExistence(timeout: 30), "失败后未出现恢复操作")
        XCTAssertTrue(app.buttons["shareEntry.clearSession"].exists, "失败后缺少退出登录按钮")
        XCTAssertTrue(app.buttons["shareEntry.diagnostics"].exists, "失败后缺少诊断按钮")
        XCTAssertFalse(app.buttons["shareEntry.image"].exists, "失败后显示了图片操作")
        XCTAssertFalse(app.buttons["shareEntry.export"].exists, "失败后显示了导出操作")
        XCTAssertFalse(element("shareEntry.progress").exists, "失败后仍显示连接进度")
        capture("shareEntry-failed")
        recover.tap()
        let image = app.buttons["shareEntry.image"]
        let export = app.buttons["shareEntry.export"]
        XCTAssertTrue(image.waitForExistence(timeout: 30) && image.isEnabled, "重试成功后缺少图片操作")
        XCTAssertTrue(export.exists && export.isEnabled, "重试成功后缺少导出操作")
        for identifier in ["recover", "clearSession", "diagnostics", "continue"] {
            XCTAssertFalse(app.buttons["shareEntry.\(identifier)"].exists, "成功后显示了恢复操作：\(identifier)")
        }
        XCTAssertLessThan(element("shareEntry.root").frame.height, app.frame.height * 0.75, "成功页面未收紧")
        capture("shareEntry-ready")
        image.tap()
        XCTAssertTrue(app.buttons["shareImage.close"].waitForExistence(timeout: 30), "入口图片按钮未打开预览")
        closePreview()
        XCTAssertTrue(export.waitForExistence(timeout: 30), "关闭图片预览后未恢复成功入口")
        export.tap()
        XCTAssertTrue(app.buttons["shareExport.close"].waitForExistence(timeout: 30), "入口导出按钮未打开导出页")
        app.buttons["shareExport.close"].tap()
        XCTAssertTrue(image.waitForExistence(timeout: 30), "关闭导出页后未恢复成功入口")
        app.buttons["shareEntry.close"].tap()
        XCTAssertTrue(app.buttons["harness.entryRecovery"].waitForExistence(timeout: 30), "成功入口关闭后未返回")
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
        let statusBeforeSave = app.staticTexts["shareExport.status"].label
        XCTAssertTrue(save.isEnabled && save.isHittable, "保存按钮未就绪")
        save.tap()
        XCTAssertTrue(waitUntil(timeout: 30) {
            self.element("shareExport.documentPicker").exists
                || self.app.staticTexts["shareExport.status"].label != statusBeforeSave
        }, "保存操作未启动")
        XCTAssertTrue(waitForDocumentPicker(timeout: 120), "保存到文件未出现系统文件 sheet")
        capture("shareExport-file-picker")
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
        let prefix = element.identifier.hasPrefix("shareExport") ? "shareExport" : "shareImage"
        let statusIdentifier = "\(prefix).status"
        let dismissed = {
            element.exists && element.isHittable
                && !self.element("shareExport.activity").exists
                && !self.element("shareImage.activity").exists
                && !self.app.otherElements["ActivityListView"].exists
                && !self.app.otherElements["UIActivityContentView"].exists
                && !self.app.collectionViews["ActivityListView"].exists
                && self.app.staticTexts[statusIdentifier].label.contains("已取消")
        }
        var action = "未找到当前 activity 的关闭控件"
        if let presentation = activityPopoverPresentation(returningTo: element) {
            // activity 的 region 与 Popover 同级，父预览页的 region 不在此容器内。
            guard let popover = presentation.children(matching: .popover).allElementsBoundByIndex.first(where: {
                containsActivity($0)
            }) else {
                attachPanelDiagnostics("activity-popover-disappeared", elements: [presentation], detail: action)
                XCTFail("操作前当前 activity 的 Popover 已消失")
                return
            }
            let regions = presentation.children(matching: .other)
                .matching(identifier: "PopoverDismissRegion").allElementsBoundByIndex
            if let region = regions.last(where: { $0.isHittable }) {
                action = "点击 activity region：\(region.frame)，popover：\(popover.frame)"
                print("[系统面板取消] \(action)")
                region.tap()
            } else {
                attachPanelDiagnostics("activity-no-dismiss-region", elements: [presentation, popover], detail: action)
                XCTFail("当前 activity 的关闭 region 不可点击，未操作父页面")
                return
            }
        } else if let panel = activitySheet(returningTo: element, identifier: "\(prefix).activity") {
            if let close = hittableButton(in: panel, titles: ["Close", "Cancel", "Done", "关闭", "取消", "完成"]) {
                action = "点击 activity 按钮：\(close.label)，\(close.frame)"
                print("[系统面板取消] \(action)")
                close.tap()
            } else if !dragTopSheetDown(panel: panel) {
                attachPanelDiagnostics("activity-no-close-control", elements: [panel], detail: action)
                XCTFail("当前 activity 没有可点击的关闭按钮或具名拖动柄")
                return
            } else {
                action = "已拖动当前 activity 的 Sheet Grabber"
            }
        } else {
            attachPanelDiagnostics("activity-no-presentation", elements: [element], detail: action)
            XCTFail("无法定位当前 activity 的呈现容器，未操作父页面")
            return
        }
        let closed = waitUntil(timeout: 30, condition: dismissed)
        if !closed {
            attachPanelDiagnostics("activity-cancel-failed", elements: [element, self.element("\(prefix).activity")], detail: action)
        }
        XCTAssertTrue(closed, "系统分享面板未完成关闭或未收到取消回调")
    }

    private func containsActivity(_ container: XCUIElement) -> Bool {
        ["shareExport.activity", "shareImage.activity", "ActivityListView", "UIActivityContentView"].contains {
            container.identifier == $0 || container.descendants(matching: .any).matching(identifier: $0).count > 0
        }
    }

    private func activityPopoverPresentation(returningTo element: XCUIElement) -> XCUIElement? {
        for window in app.windows.allElementsBoundByIndex.reversed() {
            for container in window.children(matching: .other).allElementsBoundByIndex.reversed() {
                let hasActivity = container.children(matching: .popover).allElementsBoundByIndex.contains {
                    containsActivity($0)
                }
                if hasActivity && container.descendants(matching: .button).matching(identifier: element.identifier).count == 0 {
                    return container
                }
            }
        }
        return nil
    }

    private func activitySheet(returningTo element: XCUIElement, identifier: String) -> XCUIElement? {
        let sheets = app.sheets.allElementsBoundByIndex.reversed()
        if let sheet = sheets.first(where: {
            containsActivity($0) && $0.descendants(matching: .button).matching(identifier: element.identifier).count == 0
        }) { return sheet }
        // 部分 iOS 版本将分享 sheet 暴露为 Other，而不是 Sheet。
        for window in app.windows.allElementsBoundByIndex.reversed() {
            for container in window.children(matching: .other).allElementsBoundByIndex.reversed() {
                if containsActivity(container)
                    && container.descendants(matching: .button).matching(identifier: element.identifier).count == 0 {
                    return container
                }
            }
        }
        let activity = self.element(identifier)
        if activity.exists && activity.descendants(matching: .button).matching(identifier: element.identifier).count == 0 {
            return activity
        }
        return nil
    }

    private func hittableButton(in container: XCUIElement, titles: [String]) -> XCUIElement? {
        for title in titles {
            // 文件服务会同时暴露同名 Other 代理，必须遍历真实 Button。
            let buttons = container.descendants(matching: .button).matching(identifier: title).allElementsBoundByIndex
            if let button = buttons.first(where: { $0.isHittable }) { return button }
        }
        return nil
    }

    private func dragTopSheetDown(panel: XCUIElement) -> Bool {
        // 只操作当前系统面板内的具名拖动柄，不从全屏容器推测拖动起点。
        let grabbers = panel.descendants(matching: .button).matching(identifier: "Sheet Grabber").allElementsBoundByIndex
        guard let grabber = grabbers.last(where: { $0.isHittable }) else { return false }
        let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: grabber.frame.midX - app.frame.minX, dy: app.frame.height - 16)
        )
        print("[系统面板取消] 拖动 Sheet Grabber：\(grabber.frame)，面板：\(panel.frame)")
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        return true
    }

    private func waitForDocumentPicker(timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            self.element("shareExport.documentPicker").exists
                && (self.documentCancelButton() != nil || self.documentPickerSheetContent() != nil)
        }
    }

    private func documentCancelButton() -> XCUIElement? {
        for sidebar in app.navigationBars.matching(identifier: "DOCSidebarView").allElementsBoundByIndex {
            if let cancel = hittableButton(in: sidebar, titles: ["Cancel", "取消"]) { return cancel }
        }
        if let cancel = hittableButton(in: app, titles: ["Cancel", "取消", "Close"]) { return cancel }
        let picker = element("shareExport.documentPicker")
        guard picker.exists else { return nil }
        // 仅接受当前 picker 中确实可点击的 Other，不点击宿主侧的失效 Cancel 代理。
        for title in ["Cancel", "取消"] {
            let controls = picker.descendants(matching: .other).matching(identifier: title).allElementsBoundByIndex
            if let cancel = controls.first(where: { $0.isHittable }) { return cancel }
        }
        return nil
    }

    private func documentPickerSheetContent() -> XCUIElement? {
        let picker = element("shareExport.documentPicker")
        guard picker.exists else { return nil }
        let screen = app.frame
        let contents = picker.otherElements.matching(identifier: "Browse View (Picker)").allElementsBoundByIndex
        return contents.first { content in
            let frame = content.frame
            // iPhone 文件 sheet 占满宽度但不占满屏幕，不能把全屏 picker 当作可拖动面板。
            guard abs(frame.width - screen.width) < 2, abs(frame.minX - screen.minX) < 2,
                  abs(frame.maxY - screen.maxY) < 2,
                  frame.minY > screen.minY + 24, frame.minY < screen.minY + screen.height * 0.25 else { return false }
            return content.navigationBars.matching(identifier: "FullDocumentManagerViewControllerNavigationBar")
                .allElementsBoundByIndex.contains { navigation in
                    let gap = navigation.frame.minY - frame.minY
                    return gap > 0 && gap <= 44 && content.isHittable
                }
        }
    }

    private func dragDocumentPickerSheetDown(_ sheet: XCUIElement) -> Bool {
        let frame = sheet.frame
        let navigations = sheet.navigationBars.matching(identifier: "FullDocumentManagerViewControllerNavigationBar")
            .allElementsBoundByIndex
        guard let navigation = navigations.first(where: {
            let gap = $0.frame.minY - frame.minY
            return gap > 0 && gap <= 44
        }) else { return false }
        // 从实际 sheet 顶边与导航栏之间的空白带下拉，避免依赖文件服务的返回导航。
        let inset = (navigation.frame.minY - frame.minY) / 2
        let start = sheet.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.width / 2, dy: inset))
        let end = sheet.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.width / 2, dy: frame.height - 16))
        print("[系统面板取消] 下拉文件 sheet：\(frame)，导航栏：\(navigation.frame)，顶部偏移：\(inset)")
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        return true
    }

    private func documentPickerPresentation() -> XCUIElement? {
        for window in app.windows.allElementsBoundByIndex.reversed() {
            for container in window.children(matching: .other).allElementsBoundByIndex.reversed() {
                if container.descendants(matching: .any).matching(identifier: "shareExport.documentPicker").count > 0
                    && container.descendants(matching: .button).matching(identifier: "shareExport.save").count == 0 {
                    return container
                }
            }
        }
        return nil
    }

    private func cancelDocumentPicker() {
        let picker = element("shareExport.documentPicker")
        let cancel = documentCancelButton()
        var action = "未找到文件面板取消按钮"
        if let cancel = cancel {
            action = "点击文件取消按钮：\(cancel.label)，\(cancel.frame)"
            print("[系统面板取消] \(action)")
            cancel.tap()
        } else if let sheet = documentPickerSheetContent(), dragDocumentPickerSheetDown(sheet) {
            action = "已从实际文件 sheet 顶部下拉取消"
        } else if let panel = documentPickerPresentation(), dragTopSheetDown(panel: panel) {
            action = "已拖动文件面板的 Sheet Grabber"
        } else {
            attachPanelDiagnostics("document-picker-no-cancel", elements: [picker], detail: action)
            XCTFail("系统文件面板没有可点击的取消按钮或具名拖动柄")
            return
        }
        let closed = waitUntil(timeout: 30) {
            !self.element("shareExport.documentPicker").exists
                && self.app.buttons["shareExport.save"].isHittable
                && self.app.staticTexts["shareExport.status"].label.contains("已取消保存")
        }
        if !closed { attachPanelDiagnostics("document-picker-cancel-failed", elements: [picker], detail: action) }
        XCTAssertTrue(closed, "系统文件面板未关闭或未收到取消回调")
    }

    private func attachPanelDiagnostics(_ name: String, elements: [XCUIElement], detail: String) {
        let identifiers = [
            "PopoverDismissRegion", "ActivityListView", "shareExport.documentPicker",
            "shareImage.status", "shareExport.status", "Sheet Grabber", "Cancel"
        ]
        let related = identifiers.flatMap { app.descendants(matching: .any).matching(identifier: $0).allElementsBoundByIndex }
        let frames = (elements + related).map {
            $0.exists ? "\($0.elementType) \($0.identifier) \($0.label)：\($0.frame)，可点击=\($0.isHittable)" : "元素已消失"
        }.joined(separator: "\n")
        let attachment = XCTAttachment(string: "\(detail)\n\(frames)\n\(app.debugDescription)")
        attachment.name = "\(name)-hierarchy"
        attachment.lifetime = .keepAlways
        add(attachment)
        capture(name)
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
