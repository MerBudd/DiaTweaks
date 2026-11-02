use std::{
    fs,
    path::PathBuf,
    process::Command,
};

use anyhow::{bail, Context, Result};
use clap::Subcommand;
use serde::{Deserialize, Serialize};

use crate::{
    env::Env,
    prefs::Prefs,
    ui::{self, Ui},
};

#[derive(Subcommand)]
pub enum ByokCommand {
    /// Show current BYOK configuration and status
    Status,
    /// Set BYOK provider, API key, model and briefs toggle
    Set {
        /// AI provider: google, anthropic, openai, openrouter
        #[arg(short, long)]
        provider: Option<String>,

        /// Your API key
        #[arg(short, long)]
        key: Option<String>,

        /// Default model name or ID
        #[arg(short, long)]
        model: Option<String>,

        /// Enable for morning briefs and summaries (true/false)
        #[arg(short, long)]
        briefs: Option<bool>,
    },
    /// Test API key and check available models
    Verify {
        /// Optional provider to test (defaults to configured provider)
        #[arg(short, long)]
        provider: Option<String>,

        /// Optional API key to test (defaults to configured key)
        #[arg(short, long)]
        key: Option<String>,
    },
    /// Fetch and list available models from the provider
    Models {
        /// Provider name (google, anthropic, openai, openrouter)
        #[arg(short, long)]
        provider: Option<String>,
    },
}

#[derive(Serialize, Deserialize, Default, Clone)]
pub struct ByokConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default = "default_provider")]
    pub provider: String,
    #[serde(rename = "apiKey", default)]
    pub api_key: String,
    #[serde(default)]
    pub model: String,
    #[serde(rename = "useForBriefs", default)]
    pub use_for_briefs: bool,
}

fn default_provider() -> String {
    "anthropic".to_string()
}

#[derive(Deserialize)]
struct VerifyResult {
    valid: bool,
    #[serde(default)]
    models: Vec<ModelInfo>,
    #[serde(default)]
    error: Option<String>,
}

#[derive(Deserialize)]
struct ModelInfo {
    id: String,
    #[serde(default)]
    name: String,
}

impl ByokConfig {
    fn path(env: &Env) -> PathBuf {
        env.support.join("byok.json")
    }

    pub fn load(env: &Env) -> Self {
        let p = Self::path(env);
        let mut cfg = if let Ok(content) = fs::read_to_string(&p) {
            serde_json::from_str(&content).unwrap_or_default()
        } else {
            ByokConfig {
                provider: default_provider(),
                ..Default::default()
            }
        };

        let prefs = Prefs::new(&env.domain);
        if let Some(enabled) = prefs.get("byok") {
            cfg.enabled = enabled;
        }
        if let Some(briefs) = prefs.get("byokBriefs") {
            cfg.use_for_briefs = briefs;
        }

        cfg
    }

    pub fn save(&self, env: &Env) -> Result<()> {
        let json = serde_json::to_string_pretty(self)?;
        let p = Self::path(env);
        if let Some(parent) = p.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(p, json)?;

        // Also sync the patch toggles in the settings domain
        let prefs = Prefs::new(&env.domain);
        prefs.set("byok", self.enabled);
        prefs.set("byokBriefs", self.use_for_briefs);
        let _ = prefs.save();

        Ok(())
    }
}

pub fn run(env: &Env, ui: &Ui, cmd: Option<ByokCommand>) -> Result<()> {
    match cmd.unwrap_or(ByokCommand::Status) {
        ByokCommand::Status => show_status(env, ui),
        ByokCommand::Set {
            provider,
            key,
            model,
            briefs,
        } => set_config(env, ui, provider, key, model, briefs),
        ByokCommand::Verify { provider, key } => verify_key(env, ui, provider, key),
        ByokCommand::Models { provider } => list_models(env, ui, provider),
    }
}

fn show_status(env: &Env, _ui: &Ui) -> Result<()> {
    let cfg = ByokConfig::load(env);
    let masked_key = if cfg.api_key.is_empty() {
        "(none set)".to_string()
    } else if cfg.api_key.len() <= 8 {
        "••••••••".to_string()
    } else {
        format!(
            "{}••••{}",
            &cfg.api_key[..4],
            &cfg.api_key[cfg.api_key.len() - 4..]
        )
    };

    ui::say("Bring Your Own Key (BYOK) Status:");
    ui::say(format_args!(
        "  BYOK Tweak:       {}",
        if cfg.enabled { "Enabled" } else { "Disabled" }
    ));
    ui::say(format_args!("  Provider:         {}", cfg.provider));
    ui::say(format_args!("  API Key:          {}", masked_key));
    ui::say(format_args!(
        "  Default Model:    {}",
        if cfg.model.is_empty() { "(default)" } else { &cfg.model }
    ));
    ui::say(format_args!(
        "  Briefs & Summaries: {}",
        if cfg.use_for_briefs { "Enabled (uses BYOK model)" } else { "Disabled (uses Dia default)" }
    ));
    ui::say(format_args!("  Config file:      {}", ByokConfig::path(env).display()));
    Ok(())
}

fn set_config(
    env: &Env,
    ui: &Ui,
    provider: Option<String>,
    key: Option<String>,
    model: Option<String>,
    briefs: Option<bool>,
) -> Result<()> {
    let mut cfg = ByokConfig::load(env);
    let mut changed = false;

    if let Some(p) = provider {
        let p_clean = p.to_lowercase();
        if !["google", "anthropic", "openai", "openrouter"].contains(&p_clean.as_str()) {
            bail!("Provider must be one of: google, anthropic, openai, openrouter");
        }
        cfg.provider = p_clean;
        changed = true;
    }

    if let Some(k) = key {
        cfg.api_key = k.trim().to_string();
        changed = true;
    }

    if let Some(m) = model {
        cfg.model = m.trim().to_string();
        changed = true;
    }

    if let Some(b) = briefs {
        cfg.use_for_briefs = b;
        changed = true;
    }

    if !changed {
        ui.info("No parameters provided to update. Run `diatweaks byok --help` for options.");
        return Ok(());
    }

    cfg.save(env)?;
    ui.success("BYOK configuration updated successfully.");

    // If key is set, auto-verify
    if !cfg.api_key.is_empty() {
        ui::say(format_args!("Testing {} API key...", cfg.provider));
        match run_verify(env, &cfg.provider, &cfg.api_key) {
            Ok(res) if res.valid => {
                ui.success(format_args!(
                    "✓ Key verified! {} models available.",
                    res.models.len()
                ));
            }
            Ok(res) => {
                ui.warn(format_args!(
                    "✕ Verification warning: {}",
                    res.error.unwrap_or_else(|| "Unknown error".to_string())
                ));
            }
            Err(e) => {
                ui.warn(format_args!("(Could not run verification script: {})", e));
            }
        }
    }
    Ok(())
}

fn verify_key(
    env: &Env,
    ui: &Ui,
    provider: Option<String>,
    key: Option<String>,
) -> Result<()> {
    let cfg = ByokConfig::load(env);
    let p = provider.unwrap_or(cfg.provider);
    let k = key.unwrap_or(cfg.api_key);

    if k.is_empty() {
        bail!("No API key configured. Provide --key or run `diatweaks byok set --key <API_KEY>`.");
    }

    ui::say(format_args!("Verifying API key for {}...", p));
    let res = run_verify(env, &p, &k)?;
    if res.valid {
        ui.success(format_args!(
            "✓ Key is valid! Successfully loaded {} models.",
            res.models.len()
        ));
        for m in res.models.iter().take(10) {
            ui::say(format_args!("  - {:<30} {}", m.id, m.name));
        }
        if res.models.len() > 10 {
            ui::say(format_args!("  ... and {} more models", res.models.len() - 10));
        }
    } else {
        bail!(
            "API key verification failed: {}",
            res.error.unwrap_or_else(|| "Unknown error".to_string())
        );
    }
    Ok(())
}

fn list_models(env: &Env, _ui: &Ui, provider: Option<String>) -> Result<()> {
    let cfg = ByokConfig::load(env);
    let p = provider.unwrap_or(cfg.provider);
    if cfg.api_key.is_empty() {
        bail!("No API key configured for {}. Set one first with `diatweaks byok set --key <KEY>`.", p);
    }

    ui::say(format_args!("Fetching models from {}...", p));
    let res = run_verify(env, &p, &cfg.api_key)?;
    if !res.valid {
        bail!(
            "Failed to fetch models: {}",
            res.error.unwrap_or_else(|| "Unknown error".to_string())
        );
    }

    ui::say(format_args!("Available models ({}):", res.models.len()));
    for m in &res.models {
        ui::say(format_args!("  {:<35} {}", m.id, m.name));
    }
    Ok(())
}

fn run_verify(env: &Env, provider: &str, key: &str) -> Result<VerifyResult> {
    let verify_script = env.support.join("byok/verify.js");
    let script_path = if verify_script.is_file() {
        verify_script
    } else {
        // Fallback to source directory
        PathBuf::from("src/byok/verify.js")
    };

    if !script_path.is_file() {
        bail!("Verification script not found at {}", script_path.display());
    }

    let output = Command::new("node")
        .arg(&script_path)
        .arg(provider)
        .arg(key)
        .output()
        .context("Failed to execute node for verification")?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let result: VerifyResult = serde_json::from_str(stdout.trim())
        .with_context(|| format!("Invalid JSON from verify.js: {}", stdout))?;

    Ok(result)
}
