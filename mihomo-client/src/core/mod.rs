//! 内核交互：路径解析、`mihomo -t` 校验、原子切换、systemd 控制。
//!
//! 分工原则（贯穿本项目）：**能委托内核的绝不自己实现**。
//! 校验交给 `mihomo -t`，模式/节点切换交给 RESTful API，
//! 进程管理交给 systemd。

use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// 运行时目录布局。
#[derive(Debug, Clone)]
pub struct Paths {
    /// 安装根（如 /opt/mihomo-client）
    pub root: PathBuf,
    /// mihomo 内核二进制
    pub core: PathBuf,
    /// 用户配置
    pub user_config: PathBuf,
    /// 订阅配置
    pub subscriptions: PathBuf,
    /// 渲染产物（给 mihomo 用）
    pub generated: PathBuf,
    /// mihomo 工作目录（geodata、ruleset 落这里）
    pub workdir: PathBuf,
}

impl Paths {
    /// 从环境变量 `MIHOMO_CLIENT_HOME` 或默认路径推导。
    pub fn discover() -> Self {
        let root = std::env::var_os("MIHOMO_CLIENT_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/opt/mihomo-client"));
        Self {
            core: root.join("bin/mihomo"),
            user_config: root.join("etc/config.yaml"),
            subscriptions: root.join("etc/subscriptions.yaml"),
            generated: root.join("var/config.gen.yaml"),
            workdir: root.join("var/mihomo"),
            root,
        }
    }

    pub fn systemd_unit(&self) -> PathBuf {
        PathBuf::from("/etc/systemd/system/mihomo-client.service")
    }
}

/// `mihomo -t` 校验配置。
///
/// 这是**唯一的权威校验** —— 我们不试图自己复现内核的配置语义。
/// 内核返回 0 = 接受。
pub fn validate_config(core: &Path, workdir: &Path, cfg_file: &Path) -> Result<()> {
    if !core.exists() {
        bail!("找不到 mihomo 内核：{}", core.display());
    }
    std::fs::create_dir_all(workdir)
        .with_context(|| format!("创建工作目录 {}", workdir.display()))?;

    let out = Command::new(core)
        .arg("-t")
        .arg("-d")
        .arg(workdir)
        .arg("-f")
        .arg(cfg_file)
        .stdin(Stdio::null())
        .output()
        .context("执行 mihomo -t 失败")?;

    if out.status.success() {
        return Ok(());
    }
    // 把内核的原始报错透出来 —— 它比任何二次翻译都有用
    let mut msg = String::from_utf8_lossy(&out.stderr).trim().to_string();
    if msg.is_empty() {
        msg = String::from_utf8_lossy(&out.stdout).trim().to_string();
    }
    if msg.is_empty() {
        msg = format!("mihomo -t 返回 {} 但无输出", out.status);
    }
    bail!("配置校验未通过：\n{msg}")
}

/// 原子切换：写临时文件 -> 校验 -> 改名覆盖。
///
/// 不校验就替换的话，配置写错会导致服务起不来且**旧配置也丢了**。
pub fn atomic_apply(paths: &Paths, yaml: &str) -> Result<()> {
    let tmp = paths.generated.with_extension("yaml.new");
    std::fs::create_dir_all(paths.generated.parent().unwrap())
        .with_context(|| "创建 var 目录")?;
    std::fs::write(&tmp, yaml).with_context(|| format!("写入 {}", tmp.display()))?;

    // 先确保旧配置有一份备份，校验失败时能回滚
    if paths.generated.exists() {
        let bak = paths.generated.with_extension("yaml.bak");
        let _ = std::fs::copy(&paths.generated, &bak);
    }

    if let Err(e) = validate_config(&paths.core, &paths.workdir, &tmp) {
        // 校验失败：删掉临时文件，保留旧配置不动
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }

    std::fs::rename(&tmp, &paths.generated)
        .with_context(|| format!("替换 {}", paths.generated.display()))?;
    Ok(())
}

/// 校验当前已生成的配置（不改动）。
pub fn validate_current(paths: &Paths) -> Result<()> {
    if !paths.generated.exists() {
        bail!("尚未生成配置：{}", paths.generated.display());
    }
    validate_config(&paths.core, &paths.workdir, &paths.generated)
}

/// 调用 mihomo RESTful API。
pub struct Api {
    addr: String,
    secret: Option<String>,
}

impl Api {
    pub fn new(addr: &str, secret: Option<String>) -> Self {
        Self {
            addr: addr.trim_end_matches('/').to_string(),
            secret: secret.filter(|s| !s.is_empty()),
        }
    }

    fn curl(&self, method: &str, path: &str, body: Option<&str>) -> Result<String> {
        let mut cmd = Command::new("curl");
        cmd.arg("-s")
            .arg("--max-time")
            .arg("10")
            .arg("-X")
            .arg(method);
        if let Some(s) = self.secret.as_ref() {
            cmd.arg("-H").arg(format!("Authorization: Bearer {s}"));
        }
        if let Some(b) = body {
            cmd.arg("-H").arg("Content-Type: application/json").arg("-d").arg(b);
        }
        cmd.arg(format!("{}{}", self.addr, path));
        let out = cmd.output().context("调用 curl 失败")?;
        let code = out.status.code().unwrap_or(-1);
        let text = String::from_utf8_lossy(&out.stdout).to_string();
        if code != 0 {
            bail!("API {method} {path} 失败（curl 退出码 {code}）");
        }
        Ok(text)
    }

    pub fn version(&self) -> Result<String> {
        self.curl("GET", "/version", None)
    }

    /// 热切换模式（rule/global/direct）。
    pub fn set_mode(&self, mode: &str) -> Result<()> {
        // mihomo 的 PATCH 成功返回 204（无正文），失败返回 4xx/5xx。
        // curl 的 exit code 对 HTTP 错误码仍为 0，所以要自己判状态码。
        let body = format!("{{\"mode\":\"{mode}\"}}");
        let mut cmd = Command::new("curl");
        cmd.arg("-s").arg("-o").arg("/dev/null").arg("-w").arg("%{http_code}");
        cmd.arg("--max-time").arg("10").arg("-X").arg("PATCH");
        if let Some(s) = self.secret.as_ref() {
            cmd.arg("-H").arg(format!("Authorization: Bearer {s}"));
        }
        cmd.arg("-H").arg("Content-Type: application/json");
        cmd.arg("-d").arg(&body);
        cmd.arg(format!("{}/configs", self.addr));
        let out = cmd.output().context("调用 PATCH /configs 失败")?;
        let code = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if code == "204" || code == "200" {
            Ok(())
        } else {
            bail!("切换模式失败：HTTP {code}（内核返回非 2xx）")
        }
    }

    pub fn configs(&self) -> Result<String> {
        self.curl("GET", "/configs", None)
    }

    pub fn proxies(&self) -> Result<String> {
        self.curl("GET", "/proxies", None)
    }

    pub fn connections(&self) -> Result<String> {
        self.curl("GET", "/connections", None)
    }

    /// 切换选择组的节点。
    pub fn select_proxy(&self, group: &str, node: &str) -> Result<()> {
        // 组名可能含中文与符号，要做 URL 编码；
        // 这里用最小实现：交给 curl 的 --data-urlencode 之外
        // 需自己转义。保守做法是调用方先编码。
        let mut cmd = Command::new("curl");
        cmd.arg("-s").arg("-o").arg("/dev/null").arg("-w").arg("%{http_code}");
        cmd.arg("--max-time").arg("10").arg("-X").arg("PUT");
        if let Some(s) = self.secret.as_ref() {
            cmd.arg("-H").arg(format!("Authorization: Bearer {s}"));
        }
        cmd.arg("-H").arg("Content-Type: application/json");
        cmd.arg("-d").arg(format!("{{\"name\":\"{node}\"}}"));
        cmd.arg(format!("{}/proxies/{}", self.addr, urlencode(group)));
        let out = cmd.output().context("调用 PUT /proxies 失败")?;
        let code = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if code == "204" || code == "200" {
            Ok(())
        } else {
            bail!("切换节点失败：HTTP {code}")
        }
    }
}

fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// systemd 控制。
pub struct Systemd {
    pub unit: String,
}

impl Systemd {
    pub fn new(unit: &str) -> Self {
        Self {
            unit: unit.to_string(),
        }
    }

    pub fn is_active(&self) -> bool {
        Command::new("systemctl")
            .args(["is-active", "--quiet", &self.unit])
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }

    pub fn status(&self) -> Result<String> {
        let out = Command::new("systemctl")
            .args(["status", &self.unit, "--no-pager", "-l"])
            .output()
            .context("调用 systemctl status 失败")?;
        Ok(String::from_utf8_lossy(&out.stdout).to_string())
    }

    pub fn start(&self) -> Result<()> {
        run_systemctl(&["start", &self.unit])
    }
    pub fn stop(&self) -> Result<()> {
        run_systemctl(&["stop", &self.unit])
    }
    pub fn restart(&self) -> Result<()> {
        run_systemctl(&["restart", &self.unit])
    }
    pub fn reload(&self) -> Result<()> {
        run_systemctl(&["reload", &self.unit])
    }
    pub fn daemon_reload(&self) -> Result<()> {
        run_systemctl(&["daemon-reload"])
    }

    pub fn is_enabled(&self) -> bool {
        Command::new("systemctl")
            .args(["is-enabled", "--quiet", &self.unit])
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }

    pub fn enable(&self) -> Result<()> {
        run_systemctl(&["enable", &self.unit])
    }
}

fn run_systemctl(args: &[&str]) -> Result<()> {
    let out = Command::new("systemctl")
        .args(args)
        .output()
        .with_context(|| format!("systemctl {}", args.join(" ")))?;
    if out.status.success() {
        Ok(())
    } else {
        bail!(
            "systemctl {} 失败：{}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        )
    }
}

/// 生成 systemd unit 文本。
///
/// 关键点：**用专用用户跑 mihomo**。这是旁路由解环路的三个手段之一 ——
/// `tun.exclude-uid` 要靠它才有效。OpenClash 用 `nobody`，
/// mihomo discussions #1325 里作者明确说漏掉这步会直接 loopback error。
///
/// 坑（真机 216/GROUP）：不同 Debian 版本的 nobody 所属组不同
/// （Debian 12 是 `nogroup`，部分系统是 `nobody`）。所以：
/// - 默认**不写** `Group=`，让 systemd 按用户名的默认组解析；
/// - 用 `--group` 显式指定时���覆盖。
pub fn render_unit(
    paths: &Paths,
    run_user: Option<&str>,
    run_group: Option<&str>,
    cap_net_admin: bool,
) -> String {
    let user = run_user.unwrap_or("nobody");
    let caps = if cap_net_admin {
        // mihomo 需要这些能力：net_admin 建 TUN、net_raw 打洞、
        // net_bind_service 绑 53/1024 以下端口、sys_resource 提限、
        // dac_override 读订阅缓存目录
        "AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_RESOURCE CAP_DAC_OVERRIDE"
            .to_string()
    } else {
        "AmbientCapabilities=CAP_NET_RAW CAP_NET_BIND_SERVICE".to_string()
    };
    let group_line = match run_group {
        Some(g) if !g.is_empty() => format!("Group={g}\n"),
        _ => String::new(),
    };

    format!(
        r#"[Unit]
Description=mihomo-client (mihomo proxy client, self-hosted)
Documentation=https://wiki.metacubex.one/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={user}
{group_line}ExecStart={core} -d {workdir} -f {generated}
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
# mihomo 默认把日志写 stdout，但以 nobody 运行时若 journal 未收全，
# 排查会很被动。这里同时落一份文件到 workdir。
StandardOutput=journal
StandardError=journal

# 旁路由需要 net_admin（建 TUN）与 net_raw。
# Ambient 而非 CapabilityBoundingSet，配合上面的 User={user}：
# 只给内核需要的这几项，不给 root。
{caps}
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
# var/ 下要写 geodata 与 ruleset
ReadWritePaths={workdir}
PrivateTmp=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
"#,
        user = user,
        group_line = group_line,
        core = paths.core.display(),
        workdir = paths.workdir.display(),
        generated = paths.generated.display(),
        caps = caps,
    )
}

/// 安装 systemd unit（写到 /etc/systemd/system/）。
pub fn install_unit(
    paths: &Paths,
    run_user: Option<&str>,
    run_group: Option<&str>,
    cap_net_admin: bool,
) -> Result<()> {
    let path = paths.systemd_unit();
    let text = render_unit(paths, run_user, run_group, cap_net_admin);
    std::fs::write(&path, text)
        .with_context(|| format!("写入 {}", path.display()))?;
    Systemd::new("mihomo-client").daemon_reload()?;
    Ok(())
}

/// 判断 GeoData / rule-set 是否就绪。
///
/// 内核首次启动要下载 GeoIP(MMDB) 与 GeoSite(.dat)，
/// 下载完成前**所有走规则的请求都会失败**（HTTP 代理返回 502，
/// 但 SOCKS5 会等到就绪所以看起来"能用"）—— 这很容易被误判成配置错误。
/// 所以 status 要显式报出来。
pub fn geodata_ready(workdir: &Path) -> (bool, Vec<&'static str>) {
    let mut missing = Vec::new();
    // mihomo 默认文件名
    for (name, label) in [
        ("Country.mmdb", "GeoIP(MMDB)"),
        ("geoip.metadb", "GeoIP(metadb)"),
        ("geosite.dat", "GeoSite"),
    ] {
        if workdir.join(name).exists() {
            return (true, Vec::new());
        }
        missing.push(label);
    }
    (false, missing)
}

/// 判断内核是否正在运行（用 pgrep，避免依赖 systemd）。
pub fn core_running(core: &Path) -> bool {
    let name = core
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    if name.is_empty() {
        return false;
    }
    Command::new("pgrep")
        .args(["-f", &name])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// 找到可用的 mihomo 内核二进制。
pub fn find_core(hint: Option<&Path>) -> Result<PathBuf> {
    if let Some(h) = hint {
        if h.exists() {
            return Ok(h.to_path_buf());
        }
    }
    let cands = [
        "/opt/mihomo-client/bin/mihomo",
        "/usr/local/bin/mihomo",
        "/usr/bin/mihomo",
        // 开发期先借用 OpenClash 带来的（同一套mihomo 内核）
        "/etc/openclash/core/clash_meta",
    ];
    for c in cands {
        let p = Path::new(c);
        if p.exists() {
            return Ok(p.to_path_buf());
        }
    }
    bail!(
        "找不到 mihomo 内核。请放到 {}，或用 --core 指定路径。\n\
         也可从 https://github.com/MetaCubeX/mihomo/releases 下载。",
        Paths::discover().core.display()
    )
}