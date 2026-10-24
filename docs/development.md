# 开发环境与日常命令

## 分层约定

- `melos`：仅用于 workspace bootstrap
- `just`：本地开发者入口，定位接近 `npm run`
- `tool/*.dart`：真实脚本实现，也是 CI / IDE / 自动化调用入口

## 快速开始

1. 初始化 workspace：

   ```bash
   melos bootstrap
   ```

   如果没有全局 `melos`，可改用：

   ```bash
   dart run melos bootstrap
   ```

2. 安装 `just`：

   - Windows：`winget install --id Casey.Just --exact`
   - Windows：`scoop install just`
   - Windows：`choco install just`
   - 通用：`cargo install just`

3. 显式同步项目状态：

   ```bash
   just sync
   ```

4. 运行应用：

   ```bash
   just run -- -d windows
   just run -- -d macos
   just run -- --dart-define=cronetHttpNoPlay=true
   ```

如果你不想安装 `just`，可以直接调用 Dart 入口：

```bash
dart run tool/project_prep.dart app
dart run tool/flutterw.dart run -d windows
```

## 常用命令

- `just sync`：显式同步依赖、l10n 生成物和代理证书资源；适合首次拉代码、切分支、修改 ARB 后或 IDE 调试前预热
- `just l10n`：单独生成国际化代码
- `just l10n-check`：检查国际化生成物是否最新
- `just clean`：执行 `flutter clean` 并重置依赖指纹
- `just rebuild -- <flutter build args...>`：先清理，再执行 `flutter build`
- `just run -- <flutter run args...>`：执行 `flutter run`
- `just build -- <flutter build args...>`：执行 `flutter build`
- `just test -- <flutter test args...>`：执行 `flutter test`
- `just drive -- <flutter drive args...>`：执行 `flutter drive`
- `just native -- <args...>`：显式准备原生产物
- `just doctor`：检查 Flutter / Dart / Cargo、l10n 状态、证书状态和 Android 本地签名状态
- `just analyze -- <args...>`：执行 `flutter analyze`
- `just release-check`：执行发版前检查
- `just release`：稳定版发版入口
- `just prerelease`：预发布发版入口
- `just ipa`：构建无签名 iOS IPA

当透传参数以 `-` 开头时，记得用 `--` 分隔，例如：

```bash
just run -- -d windows
just release -- patch --dry-run
```

## 自动行为

- `just run` / `just build` / `just drive` 会自动执行项目预处理，并在能识别目标平台时自动执行对应的 `native:prepare`
- `just test` 会自动执行测试所需的 `pub get + l10n`
- `just release` / `just prerelease` 会在真正写入版本号和打 tag 前自动执行发版前检查
- `just sync` 不是 hook，而是手动的显式预热命令；日常直接 `just run` / `just build` 即可

## 国际化工作流

- 协作源文件只保留 `lib/l10n/modules/**` 下的模块化 ARB
- `lib/l10n/slang/` 和 `lib/l10n/generated/app_localizations_compat.g.dart` 不提交 Git
- 修改 ARB 后，执行 `just sync` 或 `just l10n`
- 日常运行/构建入口会自动处理 l10n，不需要额外手写 pre-run hook

## 编辑器、草稿与上传

- 编辑工作台统一承载源码与语义富文本模式；两种模式的固定工具顺序分别保存，表格、图片网格、对象工具和上传任务复用同一选区与撤销历史。
- 桌面回复弹层直接使用路由实际高度约束，默认取可用高度的 75% 并封顶 580 逻辑像素；正文与预览各自滚动，移动端保留原有 95% 高度。
- 富文本导入、源码镜像和提交快照使用语义编解码链路。修改 `tools/discourse-cook-bundle/src/` 后，需按该目录脚本重新生成 `assets/cook/discourse-cook.js`，避免 Dart 与 cook token 协议不一致。
- 草稿保留本地持久化、云端序列及冲突恢复状态；舍弃草稿会终止旧保存链路，上传任务开始后空草稿也能继续插入上传结果。
- 上传按站点能力采用 S3 分片，可在网络设置中强制关闭；进度、取消与失败清理由统一任务控制器管理。媒体压缩遵循站点附件上限，并保留实测大小与格式回退反馈。
- 玻璃材质由 `common_ui` 的全局开关和效果档位管理，shader 注册在该包的 `pubspec.yaml`；墨笺编辑器继续使用纸面、顶边细线与透明工具组。
- Toast 使用统一胶囊队列和玻璃表面，下载与 Notion 同步的失败会结束进度提示并显示可读错误。

## 话题列表时间

- 发帖时间位于最后回复时间左侧，当天显示时分，往日显示短日期；缺少 `createdAt` 时不显示。不为整张卡片或发帖日期添加悬停提示，避免遮挡列表阅读；自绘卡仍通过无障碍语义提供完整创建时间。时间格式统一复用 `TimeUtils`。
- 四档按本地日历日期差计算：当天（未来日期也归此档）、1～7 天、8～30 天、超过 30 天；颜色来自当前主题的文字角色与令牌，随明暗模式切换。
- 显示设置的「显示发帖时间」默认开启，持久化键为 `pref_show_topic_creation_time`。偏好快照通知已挂载自绘卡原地重排，布局缓存和预热签名包含开关；分钟心跳负责跨日切换，隐藏卡暂停刷新。
- 置顶紧凑行的时间不参与 `Row` 弹性均分，按内容收缩并限制为行可用宽度的 40%；标题独占剩余空间，时间和回复数保持靠右，避免标题提前截断和大字号横向溢出。
- 回归入口：`test/widgets/topic/topic_creation_time_test.dart`、`test/widgets/post/reply_sheet_preview_test.dart`。

## 多站点运行与隔离

- `ForumSite` 定义 LINUX DO、IDCFlare 的域名和 Logo；`SiteContext` 在启动阶段读取选择，当前引擎内保持不变。LINUX DO 沿用原存储键与目录，IDCFlare 使用 `site:idcflare:` 前缀和 `sites/idcflare` support 子目录。
- 左上角 Logo 调用 `SiteSwitchService`：先通过 `SiteDataLifecycle.flushBeforeSwitch()` 收取编辑器现场并刷盘，再保存选择并调用 `fluxdo/site_switch`。保存或原生重启失败会回滚选择；切站不调用登出或清理另一站数据。
- Windows / Linux 以进程重启释放 WebView 和原生代理，等待旧进程退出后才启动新引擎；保留窗口尺寸与最大化，Windows / X11 也保留位置。Wayland 窗口位置由合成器决定。Android 停止代理后重建 Activity 与引擎，保留 WebView Cookie。
- 两站分别保存密码、CSRF、UserAPIKey、RSA/nonce、Cookie、数据库与账号内容；主题、字体和 AI 模型配置保持全局，AI 会话分站。备份保留数据的原始站点归属，不导入当前站点选择或待打开链接。
- IDCFlare 默认打开系统浏览器的 `/user-api-key/new` 授权页，可在网页中选择 LINUX DO 登录，再经 `discourse://auth_redirect` 回调完成本站 OTP 会话兑换；内置完整网页登录保留为备用入口。不运行 LINUX DO 专属 fingerprint / `_rt` bootstrap，不显示 LDC/CDK 等专属功能。跨站主域链接先切站再打开，子域和非标准来源不能直接按论坛 ID 路由。
- 回归入口：`test/services/site_*_test.dart`、Cookie / SessionTokenAuthority 既有测试，以及 `packages/ai_model_manager/test/services/ai_chat_storage_site_test.dart`。原生交接还需实际验证双向切换、原站登录态与窗口状态。

## IDE 集成

- Android Studio / IntelliJ 的共享运行配置提交在 [`.run/`](</D:/teng/Documents/i/ldx/.run/>)，不放进被忽略的 `.idea/`
- `FluxDO` 运行配置的 before-launch 只保留一个 `Run Prepare`
- 这个 before-launch 会串行执行 `app:prepare` 和 `native:prepare auto`，避免 IDE 按多个步骤反复弹终端
- VS Code 的 [launch.json](/D:/teng/Documents/i/ldx/.vscode/launch.json:1) 和 [tasks.json](/D:/teng/Documents/i/ldx/.vscode/tasks.json:1) 也已切到同一套预处理链路

## 平台约定

- Android 只有在 `android/key.properties` 和 keystore 都完整可用时才使用本地签名
- 当本地签名材料完整时，`debug/profile/release` 都会使用本地签名
- 当本地签名材料缺失时，`debug` 使用默认 debug signing，`profile/release` 自动回退到 debug signing
- Android 构建会优先使用 Android Studio 自带 JBR；如需手动指定，可设置 `FLUXDO_ANDROID_JAVA_HOME`
- Apple 平台不再把 `DEVELOPMENT_TEAM` 写死在共享 `pbxproj`
- 如需 Xcode 真机签名或本地签名构建，复制 [apple/Local.xcconfig.example](/D:/teng/Documents/i/ldx/apple/Local.xcconfig.example:1) 为 `apple/Local.xcconfig`，按文件内注释选择签名方案
- 原生产物准备统一走 `just native -- ...` 或 `dart run tool/project_tasks.dart native:prepare ...`
- Windows / iOS 平台工程已移除内置 cargo / shell build hook，只消费仓库脚本预先落盘的 native 产物
- macOS 保留一个轻量级 bundle copy/sign 阶段，只负责拷贝和签名已准备好的 native 产物

## macOS 代码签名

macOS 默认走 adhoc 签名（`AppInfo.xcconfig` 中 `FLUXDO_APPLE_CODE_SIGN_IDENTITY_MACOSX = -`），无需证书即可构建。但 adhoc 签名的 CDHash 每次构建都变，钥匙串（`flutter_secure_storage`）会把新构建当成新 app，每次启动反复弹「想要使用钥匙串中的 flutter_secure_storage_service」授权窗。

消除弹窗需要一个稳定的签名身份。无 Apple ID 时可用自签证书：

```bash
# 1. 生成 100 年期自签代码签名证书 + p12（目录自选，不要放进仓库）
openssl req -x509 -newkey rsa:2048 -keyout fluxdo-key.pem -out fluxdo-cert.pem \
  -days 36500 -nodes -subj "/CN=FluxDO Code Signing" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"
openssl pkcs12 -export -legacy -out fluxdo-codesign.p12 \
  -inkey fluxdo-key.pem -in fluxdo-cert.pem -passout pass:<密码>

# 2. 导入 login 钥匙串并授信（codeSign 策略）
security import fluxdo-codesign.p12 -k ~/Library/Keychains/login.keychain-db \
  -P <密码> -T /usr/bin/codesign
security add-trusted-cert -p codeSign -r trustRoot \
  -k ~/Library/Keychains/login.keychain-db fluxdo-cert.pem

# 3. 确认 identity 有效
security find-identity -v -p codesigning   # 应列出 "FluxDO Code Signing"
```

然后在 `apple/Local.xcconfig` 中启用（见 example 文件的「用法 1」）。切换后首次启动钥匙串还会弹最后一次（旧 ACL 只认 adhoc 旧构建），点「始终允许」后 rebuild 不再弹。

CI 发版使用同一张证书：把 p12 的 base64 与密码配置为仓库 secrets `MACOS_CODESIGN_P12_BASE64` / `MACOS_CODESIGN_P12_PASSWORD`（见 `.github/workflows/build.yaml` 的 "Setup macOS code signing" 步骤）。secrets 缺失时（如 fork）自动回退 adhoc 签名，构建不会失败。自签证书不等于公证，用户下载 DMG 后仍需右键打开或 `xattr -cr` 解除隔离，与 adhoc 时代一致。
