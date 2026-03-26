# 多模态学习助手 - 项目开发蓝图与需求文档

## 1.项目概述
项目名称:基于大语言模型驱动的多模态学习助手(iOS端)

作者：22101218 张朝瀚

目标平台：iOS(原生客户端)+macOS(本地服务端 MVP)

核心驱动：云端API(多模态推理)

项目愿景：打造一个完全本地化运行核心逻辑、通过API调用云端大模型的智能学习助手，支持文本、图像、音视频的多模态输入与解析。

## 2.技术栈(极简本地化方案)
### 2.1前端(iOS客户端)
* UI框架：SwiftUI
* 多媒体框架：AVFoundation(相机、麦克风调用)
* 视觉处理：Vision(端侧轻量级OCR与图像预处理)
* 网络请求：URLSession

### 2.2后端(macOS本地服务)
* 语言与框架：Python 3+FastAPI
* 本地数据库：SQLite(存储对话历史、知识卡片)
* 文件存储：macOS本地物理路径存储(图片、PDF、录音)
* AI接口集成

## 3.核心功能模块(MVP)
### 3.1智能对话(基础)
* 功能描述：支持Markdown富文本渲染的多轮对话。
* 技术实现：FastAPI管理会话上下文(Memory)，前端实时渲染代码块与LaTeX数学公式。

### 3.2拍照解题(视觉感知)
* 功能描述：拍摄数理化题目或复杂图表，输出详细解题步骤(思维链)。
* 技术实现：iOS端Vision框架预处理图片，FastAPI接收图片并直接传递给Gemini 3.1 Pro，配合特定Prompt进行多模态推理。

### 3.3语音交互与音视频解析
* 功能描述：录音或上传音视频课件，提取核心逻辑。
* 技术实现：直接将音频文件/视频抽帧数据通过FastAPI转发至Gemini 3.1 Pro，利用其原生多模态窗口进行解析，无需第三方STT引擎。

### 3.4笔记提取与文档理解(长文本处理)
* 功能描述：上传PDF/Word课件，生成结构化大纲与知识点。
* 技术实现：利用大上下文窗口，直接解析全文文档提取重点，生成Markdown格式笔记并存入本地SQLite。

## 4.开发任务拆解

### 阶段一：后端基础搭建(FastAPI)
1.在本地初始化Python虚拟环境并安装`fastapi`、`uvicorn`、`sqlite3`、`google-genai`等依赖。

2.创建`main.py`，搭建基础的RESTful API路由结构(如`/chat`、`/upload/image`、`/upload/document`)。

3.编写数据库模型(使用SQLite)来存储用户会话(Session)和消息记录(Message)。

4.封装Gemini 3.1 Pro的API调用类，支持传入文本、图片路径和音频路径。

### 阶段二：iOS端基础搭建(SwiftUI)
1.使用Xcode创建一个新的iOS App项目(SwiftUI架构)。

2.构建主聊天界面(ChatView)，包含消息列表(ScrollView)和底部输入栏。

3.实现基础的网络请求层(NetworkManager)，与本地FastAPI服务(如`http://127.0.0.1:8000`)进行通信。

4.集成Markdown和LaTeX渲染组件(可使用第三方轻量级库或原生AttributedString处理基础格式)。

### 阶段三：多模态功能贯通
1.在iOS端底部输入栏添加“相机”、“相册”和“语音”按钮。

2.使用AVFoundation实现拍照和录音功能，并将文件上传至FastAPI的对应接口。

3.在后端接收文件，保存到macOS本地目录，并将文件对象与用户的Prompt结合，发送给API。

4.将Gemini返回的多模态解析结果流式(Streaming)或一次性返回给iOS客户端并渲染显示。

### 阶段四：测试与优化
1.联调所有的多模态输入场景(传图、传音频、传PDF)。

2.优化SwiftUI界面的过渡动画和加载状态(Loading View)。

3.完善后端的错误处理机制(如API key无效、文件格式不支持等)。