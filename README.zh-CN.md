# Sub2API Menu Bar

[English](README.md) | 简体中文

一个用于自建 [Sub2API](https://github.com/Wei-Shaw/sub2api) 网关的原生
macOS 菜单栏监控工具。

只需将 Codex 或其他 Agent 配置为连接 Sub2API，之后即使在 Sub2API 中切换
上游中转或订阅账户，也不需要重启 Agent；菜单栏会自动显示最新请求实际使用的
上游账户和状态。

> 当前属于早期版本，界面以中文为主；支持的第三方中转监控接口见下文说明。

## 功能

- 显示首字延迟（TTFT）和请求总耗时
- 识别最新请求实际使用的 Sub2API 上游账户
- 自动区分 API Key 第三方中转和 OAuth 自有订阅
- 显示 OAuth 订阅的 5 小时和 7 天剩余额度
- 显示第三方中转余额、分组倍率、当前并发、渠道延迟、PING 和 7 天可用性
- 显示最近 5 次首字延迟
- 在独立的“上游”页面显示全部账户、调度状态和逐账户健康状态
- 第三方中转按需登录，不需要的或已经失效的中转可以跳过
- 直接在账户列表中启用或暂停 Sub2API 账户调度

应用不会自动修改路由。调度状态必须由用户逐账户明确操作；第三方中转监控默认
按需启用。跳过某个中转只会停止监控请求，不会改变 Sub2API 是否可以路由到该账户。
网页登录取得的访问令牌保存在 macOS 钥匙串中，不会写入 JSON 配置文件。

## 界面截图

菜单栏会根据 Sub2API 实际选择的账户类型改变显示内容：OAuth 账户显示订阅
剩余额度，API Key 中转显示余额、倍率、并发、PING 和可用性。

<table>
  <tr>
    <th>OAuth 订阅账户</th>
    <th>API Key 第三方中转</th>
  </tr>
  <tr>
    <td><img src="docs/images/oauth-subscription.png" alt="Sub2API Menu Bar 显示 OAuth 订阅账户" width="340"></td>
    <td><img src="docs/images/api-key-relay.png" alt="Sub2API Menu Bar 显示第三方 API Key 中转" width="340"></td>
  </tr>
</table>

## 系统要求

- macOS 13 或更高版本
- 可以访问的自建 Sub2API 实例
- 能够读取使用记录和上游账户信息的 Sub2API 管理员账户

## 安装

从 [最新 Release](https://github.com/huangsw666/sub2api-menubar/releases/latest)
下载 macOS 通用 ZIP，解压后打开 `install.command`。应用目前采用 ad-hoc 签名，
尚未经过 Apple 公证；如果 macOS 阻止首次运行，请按住 Control 点击
`install.command`，选择“打开”并确认。

用户明确允许安装脚本运行后，脚本只会清除已安装 App Bundle 的隔离属性，
以便 LaunchAgent 能够启动它。安装包同时支持 Apple Silicon 和 Intel Mac，
无需安装 Xcode。

如果希望从源码构建，请先安装 Apple Command Line Tools，然后执行：

```bash
git clone https://github.com/huangsw666/sub2api-menubar.git
cd sub2api-menubar
./scripts/install.sh
```

首次安装会创建配置文件：

```text
~/Library/Application Support/Sub2APIMenuBar/config.json
```

修改 `sub2api_base_url` 后重启服务：

```bash
launchctl kickstart -k "gui/$(id -u)/io.github.huangsw666.sub2api-menubar"
```

点击菜单栏的 `AI --`，使用钥匙图标登录 Sub2API。登录页面需要像当前 Sub2API
版本一样，将 `auth_token` 和可选的 `refresh_token` 保存在浏览器 localStorage
中。第三方中转登录不是必需的：打开“上游”页面，只为需要监控的中转点击“登录”。

## 配置

以下最小配置会监控管理员可见的最新一条匹配请求：

```json
{
  "sub2api_base_url": "https://sub2api.example.com",
  "sub2api_login_path": "/login",
  "tracked_user_id": null,
  "tracked_api_key_id": null,
  "tracked_group": null,
  "usage_interval_seconds": 10,
  "channel_interval_seconds": 30,
  "balance_interval_seconds": 60,
  "http_timeout_seconds": 8
}
```

可以设置 `tracked_user_id`、`tracked_api_key_id` 或 `tracked_group` 来缩小
使用记录的匹配范围；保持为 `null` 时，接受当前管理员能够看到的最新记录。

### 自动发现 API Key 第三方中转

正常情况下不需要手动配置中转适配器。最新请求使用 API Key 账户时，应用会
自动执行以下流程：

1. 从 Sub2API 账户记录读取账户名称和 `credentials.base_url`。
2. 根据该地址自动确定第三方中转监控站点。
3. 在第三方中转的 API 密钥列表中，查找名称与 Sub2API 账户名称一致的密钥。
4. 读取同名密钥的分组、倍率和当前并发。
5. 使用密钥的实际分组查询渠道延迟、PING 和可用性。

例如，Sub2API 中的账户名称是 `callai`，第三方中转站的 API 密钥名称也必须是
`callai`。名称匹配忽略大小写，但除此之外必须完全一致；如果没有找到同名密钥，
应用会报告名称不匹配，不会猜测或选择其他密钥。

应用不会自动打开第三方中转登录窗口。用户可以为某个账户点击“登录”，也可以点击
“跳过”永久停止在本机监控该账户。跳过后账户仍显示在列表中，但不会发起第三方接口请求。

<table>
  <tr>
    <th>1. Sub2API 账户名称</th>
    <th>2. 第三方中转 API 密钥名称</th>
  </tr>
  <tr>
    <td><img src="docs/images/sub2api-account-name.png" alt="Sub2API 中名称为 callai 的账户" width="440"></td>
    <td><img src="docs/images/relay-api-key-name.png" alt="第三方中转站中名称为 callai 的 API 密钥" width="440"></td>
  </tr>
</table>

第三方中转需要提供以下兼容接口：

- `GET /api/v1/auth/me`：返回 `balance` 余额字段
- `GET /api/v1/keys`：返回密钥分组、倍率和当前并发
- `GET /api/v1/channel-monitors`：返回渠道状态、延迟、PING 和可用性

接口响应可以直接是数组，也可以是使用 `items`、`records`、`list` 或
`monitors` 字段的常见分页对象。

### 账户调度

“上游”页面会列出 `GET /api/v1/admin/accounts` 返回的全部账户。每个账户的“调度”
开关调用 `POST /api/v1/admin/accounts/:id/schedulable`，只提交一个
`schedulable` 布尔值。暂停最近请求正在使用的账户时需要确认；应用也不会允许暂停最后一个
仍参与调度的账户。

### 可选的中转覆盖配置

绝大多数用户不需要这一配置。只有在中转监控地址、登录路径、API 密钥名称或
渠道分组无法按上述规则自动推导时，才需要在 `upstreams` 中添加覆盖项：

```json
{
  "name": "Example Relay",
  "account_names": ["example-relay"],
  "base_url": "https://relay.example.com",
  "login_path": "/login",
  "key_name": "my-key-name",
  "channel_group": "gpt"
}
```

`account_names` 是 Sub2API 返回的账户名称，匹配时忽略大小写。

## 服务管理

```bash
./scripts/status.sh
./scripts/uninstall.sh
```

卸载脚本只停止并删除 LaunchAgent，保留已编译的 App、配置文件和钥匙串令牌，
因此重新安装不会破坏本地数据。

Release 安装器可以迁移早期 `local.ai-latency-monitor` 原型的配置。应用首次
使用时会通过原生 Security API 导入匹配的旧钥匙串令牌；macOS 可能要求确认
一次钥匙串访问权限。

## 从源码构建

```bash
xcrun swiftc -swift-version 5 \
  -framework AppKit -framework WebKit -framework Security \
  Sources/Sub2APIMenuBar.swift -o Sub2APIMenuBar
```

构建通用 Release ZIP 和 SHA-256 校验文件：

```bash
./scripts/build-release.sh
```

## 项目状态

这是一个为了验证更多实际使用场景而提前开源的个人工具。欢迎使用 Issue 模板
提交 Bug、兼容的中转接口信息和功能需求。后续计划请查看
[ROADMAP.md](ROADMAP.md)。

## 许可证

[MIT](LICENSE)
