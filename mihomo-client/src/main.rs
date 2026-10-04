//! mihomo-client —— Linux 无桌面 mihomo 客户端
//!
//! 设计前提见 docs/10-新项目设计/01-上游调研与架构设计.md：
//! 协议解析、配置校验、API 安全全部委托 mihomo 内核，客户端只做
//! 「生成配置 + 管服务 + 提供操作入口」。
//!
//! 首版范围（本机代理模式），旁路由在后续迭代。

mod cli;
mod config;
mod core;
mod render;

use anyhow::Result;
use clap::Parser;

use cli::Cli;
use config::Config;
use core::{find_core, Paths};

fn main() {
    if let Err(e) = run() {
        // 用 {:#} 打出 anyhow 的完整因果链（每层换行）
        eprintln!("错误: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    let paths = Paths::discover();

    // 允许 --home 覆盖（测试时很有用）
    let paths = match cli.home {
        Some(ref h) => Paths {
            root: h.clone().into(),
            core: h.join("bin/mihomo"),
            user_config: h.join("etc/config.yaml"),
            subscriptions: h.join("etc/subscriptions.yaml"),
            generated: h.join("var/config.gen.yaml"),
            workdir: h.join("var/mihomo"),
        },
        None => paths,
    };

    cli.run(&paths)
}

/// 读取用户配置；不存在时返回默认。
pub fn load_config(paths: &Paths) -> Result<Config> {
    if !paths.user_config.exists() {
        return Ok(Config::default());
    }
    let text = std::fs::read_to_string(&paths.user_config)?;
    // 空文件当默认处理（`touch config.yaml` 是常见起手）
    if text.trim().is_empty() {
        return Ok(Config::default());
    }
    serde_yaml::from_str(&text)
        .map_err(|e| anyhow::anyhow!("解析 {} 失败: {e}", paths.user_config.display()))
}

pub fn save_config(paths: &Paths, cfg: &Config) -> Result<()> {
    if let Some(p) = paths.user_config.parent() {
        std::fs::create_dir_all(p)?;
    }
    let text = serde_yaml::to_string(cfg)?;
    std::fs::write(&paths.user_config, text)
        .map_err(|e| anyhow::anyhow!("写入 {} 失败: {e}", paths.user_config.display()))
}