# CloudDaemon

CloudDaemon 是一套用于管理 Linux VPS 上 `systemd` 服务的双端工具：

- [agent/](./agent)：Go 编写的 HTTPS agent，负责暴露服务状态、控制动作和日志接口
- [web/](./web)：Flutter PWA，浏览器直接连接各台 agent 进行管理

## 主要功能
- 启动、停止、重启 `systemd .service`
- 查看最近日志，并通过 WebSocket 实时追尾
- 通过“选择服务器 -> 列出全部服务 -> 搜索 -> 添加”把服务加入管理列表
- 已收藏服务按 `service_name` 全局生效，同名服务会自动应用到所有服务器
- 通过 JSON 导入导出 VPS 列表和已管理服务
- 使用 IndexedDB 在浏览器本地保存配置和管理列表

## 项目结构
- [agent/](./agent)
- [web/](./web)
- [docs/deployment.md](./docs/deployment.md)
- [docs/agent-self-signed-deployment.md](./docs/agent-self-signed-deployment.md)
- [docs/json-format.md](./docs/json-format.md)

## GitHub Actions 自动部署到 Cloudflare Pages
仓库已经包含部署工作流：[deploy-cloudflare-pages.yml](./.github/workflows/deploy-cloudflare-pages.yml)。

在把仓库推送到 GitHub 并启用自动部署前，请先在仓库里配置：
- Secret `CLOUDFLARE_API_TOKEN`
- Secret `CLOUDFLARE_ACCOUNT_ID`
- Variable `CLOUDFLARE_PAGES_PROJECT_NAME`

这个工作流会在推送到 `main` 时自动执行：
- 安装 Flutter
- 执行 `flutter pub get`
- 执行 `flutter analyze`
- 执行 `flutter test`
- 构建 `web/build/web`
- 通过 `wrangler pages deploy` 部署到 Cloudflare Pages

如果你使用这套 GitHub Actions 直接上传部署，建议不要再同时启用 Cloudflare Pages 自带的 Git 集成去部署同一个分支，避免重复发布。

## 编译 Linux amd64 Agent
仓库根目录已经提供脚本：[build-agent-linux-amd64.ps1](./build-agent-linux-amd64.ps1)

执行：

```powershell
.\build-agent-linux-amd64.ps1
```

默认产物输出到：

```text
agent/dist/clouddaemon-agent
```
