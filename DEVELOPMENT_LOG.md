# 项目开发进度与优化备忘录 (Development Log)

**最后更新：** 2026-03-27  
**当前版本：** v1.7 (Unified File Upload and Office Document Pipeline)

---

## 1. 当前开发进度

### ✅ 后端 (FastAPI + SQLite)
- **多轮对话**：支持 `session_id` 会话追踪，自动从 SQLite 拼装历史消息上下文发给 Gemini。
- **统一文件上传**：`/upload/file` 现已支持图片、音频、PDF、TXT/MD 以及主流 Office 文档上传，并返回附件类型、MIME、文件大小等元信息。
- **文件安全收口**：后端对客户端传入文件路径做了安全解析，只允许使用 `uploads` 目录内文件，删除会话时也只清理该目录内的关联文件。
- **办公文档处理链路**：`doc/docx/ppt/pptx/xls/xlsx` 会先通过 LibreOffice 转为临时 PDF，再上传给 Gemini。
- **Gemini 文件上传重试**：上传文件到 Gemini Files API 时已加入自动重试和退避，降低网络抖动导致的失败概率。
- **临时文件清理**：后端会在请求结束后清理 Office 转 PDF 的临时目录；服务启动时还会自动清理过期临时目录和孤儿上传文件，并提供手动维护接口。
- **数据库连接管理**：SQLite 连接统一切换到 context manager，用完即关，减少异常路径下的锁库风险。
- **知识卡片接口**：已支持卡片列表获取、创建、删除、更新。
- **知识卡片元信息**：`knowledge_cards` 现已支持 `category` 和 `tags` 字段；旧库启动时会自动补列。
- **系统指令**：Gemini 仍使用教育助手系统提示，要求 Markdown 结构化输出与 LaTeX 公式规范。

### ✅ iOS 客户端 (SwiftUI)
- **主界面**：聊天页、侧边抽屉、会话列表、卡片盒均可正常使用。
- **统一附件输入**：支持相册、拍照、文件选择器上传图片、音频、PDF 和主流办公文档。
- **Markdown/LaTeX 渲染**：`WKWebView + MathJax + marked` 方案可正常渲染复杂数学内容。
- **会话竞态处理**：快速切换历史会话时，旧请求不会覆盖新结果。
- **发送竞态处理**：消息发送期间会阻止重复触发；附件上传也会绑定到正确的本地消息。
- **网络层重构**：`NetworkManager` 已统一 URL 构造、请求发送和错误解码，并能透传 FastAPI 的 `detail`。
- **错误提示**：聊天页已从阻塞式 `alert` 升级为非阻塞 banner，并针对上传、转换、后端连接、Gemini 网络中断等场景提供更清晰文案。
- **附件状态提示**：发送时可看到“上传中 / 转换文档中 / AI 解析中”等整体状态，同时每个附件也会显示待发送、上传中、已就绪、失败状态，并支持失败后一键重试。
- **知识卡片管理**：
  - 支持从聊天消息收藏为卡片
  - 支持编辑已有卡片
  - 支持分类与标签
  - 支持按标题、正文、分类、标签搜索
  - 支持按分类分组展示
  - 支持点击分类标题折叠/展开

---

## 2. 本轮已完成的重点改动

### 后端
- 将 `assistant.db` 路径改为相对 `backend` 目录的稳定路径。
- 增加 `normalize_file_paths`、`resolve_upload_path`，收口文件访问范围。
- `/cards` 相关接口增加分类和标签字段支持。
- `knowledge_cards` 表支持自动补 `category` / `tags` 列。
- 统一了附件上传校验：扩展名、MIME、文件大小都会在后端检查。
- 增加 Office 文档到 PDF 的转换流程，并在 Gemini 不支持原始 Office MIME 的前提下改为上传转换后的 PDF。
- 为 Gemini 文件上传和模型生成都补了网络异常识别与重试逻辑。
- 增加启动清理和手动维护接口，用于回收过期 `/tmp/office-to-pdf-*` 临时目录与孤儿上传文件。

### iOS
- `API_BASE_URL` 改为从 build settings / Info.plist 读取，不再硬编码在源码里。
- `ChatMessage` 改为显式管理本地 `UUID`，用于稳定地更新发送中的消息。
- 将图片专用上传升级为统一附件上传，输入区新增文件选择器。
- `ChatViewModel` 增加附件发送状态管理、失败保留与手动重试能力。
- 聊天页错误提示升级为非阻塞 banner，并新增整体进度与附件级状态展示。
- 卡片编辑弹窗支持两种模式：
  - 新建卡片
  - 编辑已有卡片
- 知识卡片列表已升级为“资料库”形式，而不是简单长列表。

---

## 3. 当前代码结构与注意事项

### 后端主要文件
- [main.py](/Users/taylorosie13/project-AILearningAssistant/backend/main.py)
  目前仍承担路由、Gemini 调用、文件处理和部分数据转换逻辑，后续仍可继续拆分为 service 层。
- [database.py](/Users/taylorosie13/project-AILearningAssistant/backend/database.py)
  负责 SQLite 初始化与连接管理。
- [models.py](/Users/taylorosie13/project-AILearningAssistant/backend/models.py)
  维护 Pydantic 请求模型。

### iOS 主要文件
- [ChatViewModel.swift](/Users/taylorosie13/project-AILearningAssistant/phone/AILearningAssistant/AILearningAssistant/ViewModels/ChatViewModel.swift)
  当前承担聊天状态、会话状态、卡片状态和错误提示，后续体量继续增大时可再拆分。
- [NetworkManager.swift](/Users/taylorosie13/project-AILearningAssistant/phone/AILearningAssistant/AILearningAssistant/Network/NetworkManager.swift)
  已成为统一请求入口，后续新增接口建议继续复用当前模式。
- [KnowledgeCardView.swift](/Users/taylorosie13/project-AILearningAssistant/phone/AILearningAssistant/AILearningAssistant/Views/KnowledgeCardView.swift)
  已支持搜索、分组、折叠、编辑入口，是当前卡片功能的核心页面。

### 当前已知注意点
- `MarkdownView.swift` 仍依赖 CDN 加载 `MathJax` 和 `marked`，离线环境下可能影响公式/Markdown 渲染。
- `backend/main.py` 仍然偏大，后续如果继续扩功能，建议尽早拆分。
- `xcodebuild` 在当前终端环境里受 `xcode-select` 指向 CommandLineTools 影响；你本机 Xcode 手动 build 已成功。
- Office 文档转 PDF 依赖本机 LibreOffice；若路径变化，需要同步调整后端检测逻辑。
- 当前旧格式 `doc/ppt/xls` 与现代格式 `docx/pptx/xlsx` 共用转换链路，但仍建议继续验证更多边缘样本文件。

---

## 4. 推荐的下一步开发方向

### 优先推荐
1. **上传前本地大小检查**
   在 iOS 端选中文件时就拦截超过 20MB 的附件，减少无效上传。
2. **LibreOffice 转换超时与日志增强**
   为文档转 PDF 增加超时控制和更细的错误日志，便于排查边缘文件。
3. **图片查看体验**
   聊天图片支持点击全屏预览。

### 第二梯队
1. **会话搜索**
   在历史会话中按预览内容进行检索。
2. **知识卡片来源回跳**
   从卡片回到原始会话。
3. **后端分层**
   将 Gemini 调用、数据库访问、文件处理继续拆到 service 层。

---

## 5. 本次提交前说明

- 本次开发已覆盖后端与 iOS 两端，核心主题是“统一文件上传与办公文档处理闭环”。
- 本次提交建议包含：
  - 后端文件上传、Office 转 PDF、Gemini 上传重试、临时文件清理
  - iOS 附件输入、附件状态、非阻塞错误提示
- 工作区里仍存在与本次提交无关的本地文件：
  - [NEXT_DEVELOPMENT_PLAN.md](/Users/taylorosie13/project-AILearningAssistant/NEXT_DEVELOPMENT_PLAN.md)
- 提交 git 时建议不要把无关文件混进本次功能提交。
