# filebox 新设备启动文档（给智能体 / 给人类）

> **给用户的一句话**：把下面这句复制给其他设备上的智能体，它就会照做：
>
> ```
> 你是本机的配置助手。请读取 https://raw.githubusercontent.com/lyz-wave/filebox-web/main/setup/AGENT.md ，严格按里面的「给智能体的执行流程」把 filebox 配置好；需要 GitHub 授权时，把验证码和链接发给我，我完成后再继续。不要向我索取密码，也不要把令牌粘到聊天里。
> ```

---

## 0. 快速事实

| 项目 | 值 |
|---|---|
| 数据仓库（私有） | https://github.com/lyz-wave/filebox |
| 网页版（手机 / 临时电脑） | https://lyz-wave.github.io/filebox-web/ |
| 网页源码（公开，只有界面） | https://github.com/lyz-wave/filebox-web |
| 本机已配置好的设备 | Windows `C:\Users\75486\Desktop\文件传输`（GitHub 账号 `lyz-wave`） |
| 文件存放位置 | 仓库根目录的 `inbox/` |
| 文件命名规则 | `<yyyymmdd-hhmmss>_<设备名>_<原文件名>` |
| 单文件限制 | git 推送 100MB 硬上限（50MB 警告）；网页 50MB 硬上限（建议 ≤25MB） |
| 网页令牌 | Fine-grained PAT，只授权 `lyz-wave/filebox` 的 `Contents: Read and write` |

**重要区分**：网页用的 Fine-grained 令牌 ≠ 命令行 `gh` 的登录凭据。`gh` 需要 `repo` / `read:org` 权限，最省事的方式是让脚本走 GitHub 的设备码授权（浏览器输入一次验证码）。

---

## 1. 给智能体的执行流程

目标：让本机能够用 `git` 收发文件，并知道网页版地址，最后给用户一段可直接照做的说明。

### 步骤 0：判断系统

- Windows：`powershell` / `pwsh`；用 `[Environment]::OSVersion` 确认。
- macOS / Linux：`uname -a`。
- iOS / iPadOS / Android：没有终端，**不要跑脚本**，直接跳到第 4 节「手机怎么用」。

### 步骤 1：运行一键脚本

**Windows**（普通用户权限，不需要管理员；winget 安装 Git 时可能弹一次 UAC，让用户点允许）：

```powershell
$p = Join-Path $env:TEMP "filebox-bootstrap.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/lyz-wave/filebox-web/main/setup/bootstrap.ps1" -OutFile $p -UseBasicParsing
powershell -NoProfile -ExecutionPolicy Bypass -File $p
```

**macOS / Linux**：

```bash
curl -fsSL https://raw.githubusercontent.com/lyz-wave/filebox-web/main/setup/bootstrap.sh -o /tmp/filebox-bootstrap.sh
bash /tmp/filebox-bootstrap.sh
```

脚本会自动：检查/安装 Git 与 GitHub CLI（gh）→ 检查登录（没登录就发起设备码授权）→ clone 或更新仓库 → 冒烟测试 `recv`。

**智能体注意**：脚本会在终端打印一次性验证码（形如 `5C41-87F7`）和 `https://github.com/login/device` 链接，然后**自己轮询等待授权**（最长约 10 分钟）。

- 把验证码和链接**原样发在聊天里**，让用户去点 Authorize；
- 用足够长的超时运行这一步（≥ 10 分钟），或后台运行并每隔几秒读取输出；
- 用户授权完成后脚本会自动继续，不需要你再输任何命令；
- 如果本机已经登录过（`gh auth status` 显示 `lyz-wave`），脚本会直接跳过授权。

### 步骤 2：验收（逐项执行，全部通过才算就绪）

```powershell
# Windows
git --version
gh auth status
git -C "$env:USERPROFILE\filebox" rev-parse --is-inside-work-tree
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\filebox\recv.ps1" -Quiet
Invoke-WebRequest -Uri "https://lyz-wave.github.io/filebox-web/" -UseBasicParsing | Select-Object -ExpandProperty StatusCode
```

```bash
# macOS / Linux
git --version
gh auth status
git -C "$HOME/filebox" rev-parse --is-inside-work-tree
bash "$HOME/filebox/recv.sh"
curl -sS -o /dev/null -w "%{http_code}\n" https://lyz-wave.github.io/filebox-web/
```

判定标准：

- `git --version` ≥ 2.20；
- `gh auth status` 显示 `Logged in to github.com account lyz-wave`；
- 仓库存在且是 git 仓库，`send.ps1 / recv.ps1`（或 `.sh`）存在；
- `recv` 输出「已是最新，没有新文件。」或列出文件，而不是报错；
- 网页地址返回 200。

### 步骤 3：给用户的总结（必须包含）

- **本机仓库路径**（默认 Windows `%USERPROFILE%\filebox`、macOS/Linux `~/filebox`）
- **发送**：`cd <仓库路径>` 然后 ` .\send.ps1 文件路径`（Windows）/ ` ./send.sh 文件`（macOS/Linux）
- **接收**：` .\recv.ps1` / ` ./recv.sh`
- **网页版**：https://lyz-wave.github.io/filebox-web/ （手机、借别人电脑时用；第一次要按第 4 节填令牌）
- 如果任何一步失败：明确说「本机未就绪」，给出失败的原始报错和修复建议，不要编造成功。

### 步骤 4：可选的端到端验证（推荐做一次）

发一个几字节的测试文件，确认推送链路通（会向仓库写一次提交，稍后可用 `clean` 清掉）：

```powershell
# Windows
$f = Join-Path $env:TEMP ("hello-filebox-" + $env:COMPUTERNAME + ".txt")
"hello from " + $env:COMPUTERNAME | Out-File -FilePath $f -Encoding utf8
cd "$env:USERPROFILE\filebox"; .\send.ps1 $f
```

```bash
# macOS / Linux
echo "hello from $(hostname)" > /tmp/hello-filebox.txt
cd "$HOME/filebox" && ./send.sh /tmp/hello-filebox.txt
```

### 禁止事项（给智能体）

- 不要向用户索取账号密码、不要要求用户把令牌贴进聊天；
- 不要往仓库提交任何密钥、token、私钥；
- 不要 `git push --force`、不要删除/重写历史（重置历史是用户明确要求时才可做）；
- 不要修改 `.gitattributes` / 脚本逻辑，除非用户明确要求；
- 装软件失败时不要反复重试几十次，把错误和可行的手动方案告诉用户。

---

## 2. 人类手动配置（不想跑脚本时）

### Windows

1. 安装 Git：`winget install --id Git.Git -e`（或用 https://git-scm.com/download/win）
2. 安装 GitHub CLI：`winget install --id GitHub.cli -e`
3. 登录：`gh auth login`（GitHub.com → HTTPS → 浏览器授权）
4. 克隆：`git clone https://github.com/lyz-wave/filebox.git "$env:USERPROFILE\filebox"`
5. 进入目录：`cd "$env:USERPROFILE\filebox"`
6. 如果提示「禁止运行脚本」：`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

### macOS

```bash
brew install git gh
gh auth login
git clone https://github.com/lyz-wave/filebox.git "$HOME/filebox"
cd "$HOME/filebox" && chmod +x send.sh recv.sh clean.sh text.sh
```

### Linux（Debian/Ubuntu 为例）

```bash
sudo apt-get update && sudo apt-get install -y git gh
gh auth login
git clone https://github.com/lyz-wave/filebox.git "$HOME/filebox"
cd "$HOME/filebox" && chmod +x send.sh recv.sh clean.sh text.sh
```

---

## 3. 日常用法

| 操作 | Windows | macOS / Linux |
|---|---|---|
| 发送单个文件 | ` .\send.ps1 .\报告.pdf` | ` ./send.sh ./报告.pdf` |
| 发送整个文件夹 | ` .\send.ps1 .\照片目录` | ` ./send.sh ./照片目录` |
| 自定义提交说明 | ` .\send.ps1 .\文件 -Message "说明"` | ` ./send.sh ./文件 --message "说明"` |
| 只提交本地不推送 | ` .\send.ps1 .\文件 -NoPush` | ` ./send.sh ./文件 --no-push` |
| 发送文字 / 网址 / 剪贴板 | ` .\text.ps1 "文字"` | ` ./text.sh "文字"` |
| 接收（列出新文件） | ` .\recv.ps1` | ` ./recv.sh` |
| 接收并另存一份 | ` .\recv.ps1 -OutDir D:\下载` | ` ./recv.sh --out ~/Downloads` |
| 清理 7 天前文件 | ` .\clean.ps1 -Days 7 -DryRun` | ` ./clean.sh --days 7 --dry-run` |

文件会以 `时间戳_设备名_原文件名` 的形式出现在 `inbox/`；电脑脚本、网页版、GitHub App 共用同一个 `inbox/`。

---

## 4. 手机 / 平板（没有终端）

### 4.1 用网页版（推荐）

1. 手机浏览器打开 https://lyz-wave.github.io/filebox-web/ ；
2. 点「令牌设置」，按页面里的 1 分钟教程生成 **Fine-grained PAT**：
   - Resource owner：`lyz-wave`
   - Repository access：Only select repositories → `lyz-wave/filebox`
   - Repository permissions：**Contents = Read and write**（其余不用给）
3. 粘贴令牌 + 设备名（如 `ipad`），点「保存并连接」；
4. 页面顶部还有「发送文字 / 剪贴板」框，粘贴文字点发送即可；列表里 💬 条目点「查看」看全文、点「复制」进剪贴板；
5. 拖文件或点选上传，列表里可下载、删除；令牌只存在本机浏览器，随时可在 GitHub 设置里吊销。

### 4.2 GitHub 手机 App / 浏览器（应急）

打开 https://github.com/lyz-wave/filebox/tree/main/inbox → Add file → Upload files（单文件 ≤25MB）；下载点文件右上角 Download。

---

## 5. 常见问题

| 现象 | 处理 |
|---|---|
| `gh auth status` 没登录 / 403 | 重新 `gh auth login`；或重跑 bootstrap 脚本 |
| push 报 `File exceeds 100.00 MB` | 拆分文件，或改用 Release / Git LFS |
| 网页连接后看不到文件 / 401 | 令牌过期或权限不足，重新生成 Contents 读写令牌 |
| 网页 403 rate limit | 等几分钟再试（认证用户额度 5000 次/小时） |
| 中文文件名显示乱码 | `git config --global core.quotepath false`（脚本已设置） |
| 拉下来换行符变了 | 仓库 `.gitattributes` 有 `* -text`，不要移除；检查本机 `core.autocrlf` |
| 公司网络/代理导致连不上 | 先开代理再重跑脚本；确认能访问 github.com 与 api.github.com |
| 手机没网络工具 | 用网页版或 GitHub App |

---

## 6. 安全与限制

- 网页是公开静态页面，不含任何文件；令牌只在本机浏览器 ↔ `api.github.com` 之间传递。
- 数据仓库是私有的，但内容仍存放在 GitHub 服务器；证件、密钥等敏感文件建议先本地加密（7z/age/gpg）再发。
- 不要往 `inbox/` 放密码、token、私钥。
- `clean` 只删当前版本，git 历史仍保留旧文件；需要彻底瘦身时按仓库 README 的「重置历史」操作（会改写历史，其他设备需重新 clone）。
- 网页单文件硬上限 50MB；git 单文件硬上限 100MB。更大的文件用 Release（单文件 ≤2GB）或 Git LFS。

---

## 7. 相关链接

- 启动文档（本文件）：https://raw.githubusercontent.com/lyz-wave/filebox-web/main/setup/AGENT.md
- 网页版：https://lyz-wave.github.io/filebox-web/
- 数据仓库：https://github.com/lyz-wave/filebox
- 网页源码：https://github.com/lyz-wave/filebox-web
- Windows 一键脚本：https://raw.githubusercontent.com/lyz-wave/filebox-web/main/setup/bootstrap.ps1
- macOS/Linux 一键脚本：https://raw.githubusercontent.com/lyz-wave/filebox-web/main/setup/bootstrap.sh
- 机器可读清单：https://raw.githubusercontent.com/lyz-wave/filebox-web/main/setup/manifest.json
