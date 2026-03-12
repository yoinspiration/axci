//! Core logic: load rules, git diff, cargo metadata, evaluate and produce output.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Output {
    pub skip_all: bool,
    pub targets: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct Rules {
    non_code: NonCode,
    run_all_patterns: Vec<String>,
    /// When set, a file triggers run_all only if it matches a run_all_pattern and does NOT match any of these.
    #[serde(default)]
    run_all_exclude_patterns: Vec<String>,
    selection_rules: Vec<SelectionRule>,
    target_order: Vec<String>,
    #[serde(default)]
    run_all_crates: Vec<String>,
    #[serde(default)]
    crate_rules: Vec<CrateRule>,
    /// Crate + path: when a changed file belongs to one of the crates and matches path_patterns, add targets.
    #[serde(default)]
    crate_path_rules: Vec<CratePathRule>,
}

#[derive(Debug, Deserialize)]
struct CratePathRule {
    #[allow(dead_code)]
    id: String,
    crates: Vec<String>,
    path_patterns: Vec<String>,
    targets: Vec<String>,
    #[serde(default)]
    direct_only: bool,
}

#[derive(Debug, Deserialize)]
struct NonCode {
    #[serde(default)]
    dirs: Vec<String>,
    #[serde(default)]
    exts: Vec<String>,
    #[serde(default)]
    files: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct SelectionRule {
    #[allow(dead_code)]
    id: String,
    patterns: Vec<String>,
    targets: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct CrateRule {
    #[allow(dead_code)]
    id: String,
    crates: Vec<String>,
    targets: Vec<String>,
    #[serde(default)]
    direct_only: bool,
}

/// Resolve rules file path: component's .github/axci-test-target-rules.json first, then default.
fn resolve_rules_path(repo_path: &Path, default_rules: Option<&Path>) -> Option<std::path::PathBuf> {
    let component_rules = repo_path.join(".github").join("axci-test-target-rules.json");
    if component_rules.exists() {
        return Some(component_rules);
    }
    if let Some(p) = default_rules {
        if p.exists() {
            return Some(p.to_path_buf());
        }
    }
    None
}

/// Run git diff --name-only base_ref in repo_path.
fn git_changed_files(repo_path: &Path, base_ref: &str) -> Result<Vec<String>, String> {
    let out = Command::new("git")
        .current_dir(repo_path)
        .args(["diff", "--name-only", base_ref])
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        eprintln!("[affected] git diff {} failed, trying HEAD~1", base_ref);
        let out2 = Command::new("git")
            .current_dir(repo_path)
            .args(["diff", "--name-only", "HEAD~1"])
            .output()
            .map_err(|e| e.to_string())?;
        if !out2.status.success() {
            return Ok(Vec::new());
        }
        let s = String::from_utf8_lossy(&out2.stdout);
        return Ok(s.lines().map(str::trim).filter(|x| !x.is_empty()).map(String::from).collect());
    }
    let s = String::from_utf8_lossy(&out.stdout);
    Ok(s.lines().map(str::trim).filter(|x| !x.is_empty()).map(String::from).collect())
}

/// Match path against a single pattern; * matches any substring (like shell).
fn path_matches_pattern(path: &str, pattern: &str) -> bool {
    let path = path.trim_start_matches("./");
    let parts: Vec<&str> = pattern.split('*').collect();
    if parts.len() == 1 {
        return path == pattern || path == pattern.trim_end_matches('/');
    }
    if !path.starts_with(parts[0]) {
        return false;
    }
    let mut rest = &path[parts[0].len()..];
    for (i, part) in parts.iter().enumerate().skip(1) {
        if part.is_empty() {
            continue;
        }
        match rest.find(part) {
            Some(pos) => rest = &rest[pos + part.len()..],
            None => return false,
        }
        if i == parts.len() - 1 && !rest.is_empty() {
            return false;
        }
    }
    true
}

fn is_non_code(path: &str, rules: &Rules) -> bool {
    let path = path.trim_start_matches("./");
    for d in &rules.non_code.dirs {
        if path.starts_with(d) {
            return true;
        }
    }
    for e in &rules.non_code.exts {
        if path.ends_with(e) {
            return true;
        }
    }
    for f in &rules.non_code.files {
        if path == f {
            return true;
        }
    }
    false
}

/// Returns (changed_crates, affected_crates, file_to_crate for changed files that belong to a workspace crate).
fn compute_crates(
    repo_path: &Path,
    _base_ref: &str,
    changed_files: &[String],
) -> (Vec<String>, Vec<String>, HashMap<String, String>) {
    let empty_map = HashMap::new();
    let manifest = repo_path.join("Cargo.toml");
    if !manifest.exists() {
        return (Vec::new(), Vec::new(), empty_map);
    }
    let meta = match cargo_metadata::MetadataCommand::new()
        .manifest_path(&manifest)
        .exec()
    {
        Ok(m) => m,
        Err(_) => return (Vec::new(), Vec::new(), empty_map),
    };
    let members: Vec<_> = meta.workspace_members.iter().collect();
    let ws_root = meta.workspace_root.as_str();
    let mut crate_root_by_name: HashMap<String, String> = HashMap::new();
    let mut id_to_name: HashMap<cargo_metadata::PackageId, String> = HashMap::new();
    for p in &meta.packages {
        if members.iter().any(|id| **id == p.id) {
            id_to_name.insert(p.id.clone(), p.name.clone());
            let manifest_path = p.manifest_path.as_str();
            let root = if manifest_path.starts_with(ws_root) {
                let rel = manifest_path[ws_root.len()..].trim_start_matches('/');
                rel.rsplit_once('/').map(|(dir, _)| dir.to_string()).unwrap_or_default()
            } else {
                manifest_path.rsplit_once('/').map(|(dir, _)| dir.to_string()).unwrap_or_default()
            };
            // Empty root = package at workspace root; use "." so "src/foo.rs" etc. can match
            let root_key = if root.is_empty() { "." } else { &root };
            crate_root_by_name.insert(p.name.clone(), root_key.to_string());
        }
    }
    // Changed files -> crates (longest prefix match); and file -> crate for crate_path_rules
    // Root "." means workspace-root package; it matches any path (length 0) so it's the fallback.
    let mut changed_crates: HashSet<String> = HashSet::new();
    let mut file_to_crate: HashMap<String, String> = HashMap::new();
    for f in changed_files {
        let f_trim = f.trim_start_matches("./");
        let mut best: Option<(String, usize)> = None;
        for (name, root) in &crate_root_by_name {
            let matches = if root == "." {
                true
            } else {
                f_trim == root || f_trim.starts_with(&format!("{}/", root))
            };
            if matches {
                let len = if root == "." { 0 } else { root.len() };
                if best.as_ref().map(|(_, l)| *l < len).unwrap_or(true) {
                    best = Some((name.clone(), len));
                }
            }
        }
        if let Some((name, _)) = best {
            changed_crates.insert(name.clone());
            file_to_crate.insert(f.clone(), name);
        }
    }
    // Reverse deps: dep_id -> [dependent ids]
    let mut rev_deps: HashMap<String, Vec<String>> = HashMap::new();
    if let Some(resolve) = &meta.resolve {
        for node in &resolve.nodes {
            let node_name = id_to_name.get(&node.id).cloned().unwrap_or_else(|| node.id.repr.clone());
            for dep in &node.deps {
                let dep_name = id_to_name.get(&dep.pkg).cloned().unwrap_or_else(|| dep.pkg.repr.clone());
                rev_deps.entry(dep_name).or_default().push(node_name.clone());
            }
        }
    }
    // BFS from changed to affected
    let mut affected: HashSet<String> = changed_crates.clone();
    let mut queue: Vec<_> = changed_crates.iter().cloned().collect();
    let mut head = 0;
    while head < queue.len() {
        let cur = &queue[head];
        head += 1;
        if let Some(dependents) = rev_deps.get(cur) {
            for d in dependents {
                if affected.insert(d.clone()) {
                    queue.push(d.clone());
                }
            }
        }
    }
    let changed_vec: Vec<String> = changed_crates.into_iter().collect();
    let affected_vec: Vec<String> = affected.into_iter().collect();
    (changed_vec, affected_vec, file_to_crate)
}

fn decide_output(
    rules: &Rules,
    changed_files: &[String],
    changed_crates: &[String],
    affected_crates: &[String],
    file_to_crate: &HashMap<String, String>,
) -> Output {
    if changed_files.is_empty() {
        return Output {
            skip_all: true,
            targets: Vec::new(),
        };
    }

    let has_code_change = changed_files.iter().any(|f| !is_non_code(f, rules));
    if !has_code_change {
        return Output {
            skip_all: true,
            targets: Vec::new(),
        };
    }

    let mut needs_all = false;
    for f in changed_files {
        for p in &rules.run_all_patterns {
            if path_matches_pattern(f, p) {
                let excluded = rules
                    .run_all_exclude_patterns
                    .iter()
                    .any(|ex| path_matches_pattern(f, ex));
                if !excluded {
                    needs_all = true;
                    break;
                }
            }
        }
        if needs_all {
            break;
        }
    }

    for c in &rules.run_all_crates {
        if changed_crates.iter().any(|x| x == c) {
            needs_all = true;
            break;
        }
    }

    let mut selected: HashSet<String> = HashSet::new();
    if !needs_all {
        for f in changed_files {
            for rule in &rules.selection_rules {
                for p in &rule.patterns {
                    if path_matches_pattern(f, p) {
                        for t in &rule.targets {
                            selected.insert(t.clone());
                        }
                        break;
                    }
                }
            }
        }
        for rule in &rules.crate_rules {
            let check = if rule.direct_only {
                changed_crates
            } else {
                affected_crates
            };
            for c in &rule.crates {
                if check.iter().any(|x| x == c) {
                    for t in &rule.targets {
                        selected.insert(t.clone());
                    }
                    break;
                }
            }
        }
        for f in changed_files {
            let crate_name = match file_to_crate.get(f) {
                Some(c) => c,
                None => continue,
            };
            for rule in &rules.crate_path_rules {
                let check = if rule.direct_only {
                    changed_crates
                } else {
                    affected_crates
                };
                if !check.iter().any(|x| x == crate_name) {
                    continue;
                }
                if !rule.crates.iter().any(|c| c == crate_name) {
                    continue;
                }
                let path_matches = rule.path_patterns.iter().any(|p| path_matches_pattern(f, p));
                if path_matches {
                    for t in &rule.targets {
                        selected.insert(t.clone());
                    }
                    break;
                }
            }
        }
    }

    let targets = if needs_all || selected.is_empty() {
        rules.target_order.clone()
    } else {
        rules
            .target_order
            .iter()
            .filter(|t| selected.contains(*t))
            .cloned()
            .collect()
    };

    Output {
        skip_all: false,
        targets,
    }
}

pub fn run(
    repo_path: &Path,
    base_ref: &str,
    rules_path_arg: Option<&str>,
) -> Result<Output, String> {
    let default_rules = rules_path_arg.map(Path::new);
    let rules_file = resolve_rules_path(repo_path, default_rules)
        .ok_or_else(|| "no rules file found (.github/axci-test-target-rules.json or default)".to_string())?;
    let content = std::fs::read_to_string(&rules_file).map_err(|e| e.to_string())?;
    let rules: Rules = serde_json::from_str(&content).map_err(|e| e.to_string())?;

    let changed_files = git_changed_files(repo_path, base_ref)?;
    eprintln!("[affected] changed files ({}):", changed_files.len());
    for f in &changed_files {
        eprintln!("  {}", f);
    }

    let (changed_crates, affected_crates, file_to_crate) = compute_crates(repo_path, base_ref, &changed_files);
    if !changed_crates.is_empty() || !affected_crates.is_empty() {
        eprintln!("[affected] changed_crates: {:?}", changed_crates);
        eprintln!("[affected] affected_crates: {:?}", affected_crates);
    }

    let out = decide_output(
        &rules,
        &changed_files,
        &changed_crates,
        &affected_crates,
        &file_to_crate,
    );
    if out.skip_all {
        eprintln!("[affected] only non-code files changed or no changes → skip all tests");
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules_fixture() -> Rules {
        let raw = r#"
{
  "non_code": {
    "dirs": ["doc/"],
    "exts": [".md", ".txt"],
    "files": ["LICENSE"]
  },
  "run_all_patterns": ["kernel/*", ".github/workflows/*"],
  "run_all_exclude_patterns": ["kernel/src/hal/arch/*"],
  "selection_rules": [
    {
      "id": "aarch64_path",
      "patterns": ["src/hal/arch/aarch64/*", "kernel/src/hal/arch/aarch64/*"],
      "targets": ["aarch64-qemu"]
    },
    {
      "id": "x86_path",
      "patterns": ["src/hal/arch/x86_64/*"],
      "targets": ["x86-qemu"]
    },
    {
      "id": "phytium_path",
      "patterns": ["*phytium*", "*e2000*"],
      "targets": ["board-phytium"]
    },
    {
      "id": "rk3568_path",
      "patterns": ["*rk3568*", "*rockchip*"],
      "targets": ["board-rk3568"]
    }
  ],
  "target_order": ["aarch64-qemu", "x86-qemu", "board-phytium", "board-rk3568"],
  "run_all_crates": ["axruntime"],
  "crate_rules": [],
  "crate_path_rules": [
    {
      "id": "driver_phytium",
      "crates": ["driver"],
      "path_patterns": ["*phytium*", "*e2000*"],
      "targets": ["board-phytium"],
      "direct_only": false
    },
    {
      "id": "driver_rockchip",
      "crates": ["driver"],
      "path_patterns": ["*rk3568*", "*rockchip*"],
      "targets": ["board-rk3568"],
      "direct_only": false
    }
  ]
}
        "#;
        serde_json::from_str(raw).expect("valid test rules")
    }

    fn rules_with_direct_only_fixture() -> Rules {
        let raw = r#"
{
  "non_code": { "dirs": ["doc/"], "exts": [".md"], "files": [] },
  "run_all_patterns": [],
  "selection_rules": [],
  "target_order": ["board-phytium", "board-rk3568"],
  "run_all_crates": [],
  "crate_rules": [],
  "crate_path_rules": [
    {
      "id": "driver_direct_only",
      "crates": ["driver"],
      "path_patterns": ["*phytium*"],
      "targets": ["board-phytium"],
      "direct_only": true
    }
  ]
}
        "#;
        serde_json::from_str(raw).expect("valid direct-only test rules")
    }

    #[test]
    fn doc_only_changes_should_skip_all() {
        let rules = rules_fixture();
        let changed_files = vec!["doc/readme.md".to_string()];
        let out = decide_output(&rules, &changed_files, &[], &[], &HashMap::new());
        assert!(out.skip_all);
        assert!(out.targets.is_empty());
    }

    #[test]
    fn aarch64_path_should_select_only_aarch64_target() {
        let rules = rules_fixture();
        let changed_files = vec!["src/hal/arch/aarch64/api.rs".to_string()];
        let out = decide_output(&rules, &changed_files, &[], &[], &HashMap::new());
        assert!(!out.skip_all);
        assert_eq!(out.targets, vec!["aarch64-qemu"]);
    }

    #[test]
    fn run_all_with_exclude_should_not_trigger_full_for_arch_path() {
        let rules = rules_fixture();
        let changed_files = vec!["kernel/src/hal/arch/aarch64/api.rs".to_string()];
        let out = decide_output(&rules, &changed_files, &[], &[], &HashMap::new());
        assert!(!out.skip_all);
        assert_eq!(out.targets, vec!["aarch64-qemu"]);
    }

    #[test]
    fn crate_path_rule_should_select_phytium_only() {
        let rules = rules_fixture();
        let changed_files = vec!["src/driver/blk/phytium.rs".to_string()];
        let changed_crates = vec!["driver".to_string()];
        let affected_crates = vec!["driver".to_string()];
        let mut file_to_crate = HashMap::new();
        file_to_crate.insert("src/driver/blk/phytium.rs".to_string(), "driver".to_string());
        let out = decide_output(
            &rules,
            &changed_files,
            &changed_crates,
            &affected_crates,
            &file_to_crate,
        );
        assert!(!out.skip_all);
        assert_eq!(out.targets, vec!["board-phytium"]);
    }

    #[test]
    fn crate_path_rule_should_select_rk3568_only() {
        let rules = rules_fixture();
        let changed_files = vec!["src/driver/soc/rockchip/clk/rk3568-clk.rs".to_string()];
        let changed_crates = vec!["driver".to_string()];
        let affected_crates = vec!["driver".to_string()];
        let mut file_to_crate = HashMap::new();
        file_to_crate.insert(
            "src/driver/soc/rockchip/clk/rk3568-clk.rs".to_string(),
            "driver".to_string(),
        );
        let out = decide_output(
            &rules,
            &changed_files,
            &changed_crates,
            &affected_crates,
            &file_to_crate,
        );
        assert!(!out.skip_all);
        assert_eq!(out.targets, vec!["board-rk3568"]);
    }

    #[test]
    fn unmatched_code_change_should_fallback_to_all_targets() {
        let rules = rules_fixture();
        let changed_files = vec!["src/misc/unknown.rs".to_string()];
        let out = decide_output(&rules, &changed_files, &[], &[], &HashMap::new());
        assert!(!out.skip_all);
        assert_eq!(
            out.targets,
            vec!["aarch64-qemu", "x86-qemu", "board-phytium", "board-rk3568"]
        );
    }

    #[test]
    fn run_all_crate_should_force_all_targets() {
        let rules = rules_fixture();
        let changed_files = vec!["src/any/path.rs".to_string()];
        let changed_crates = vec!["axruntime".to_string()];
        let out = decide_output(&rules, &changed_files, &changed_crates, &[], &HashMap::new());
        assert!(!out.skip_all);
        assert_eq!(
            out.targets,
            vec!["aarch64-qemu", "x86-qemu", "board-phytium", "board-rk3568"]
        );
    }

    #[test]
    fn selected_targets_should_follow_target_order() {
        let rules = rules_fixture();
        let changed_files = vec!["src/driver/rockchip-phytium-mixed.rs".to_string()];
        let out = decide_output(&rules, &changed_files, &[], &[], &HashMap::new());
        assert!(!out.skip_all);
        assert_eq!(out.targets, vec!["board-phytium", "board-rk3568"]);
    }

    #[test]
    fn direct_only_crate_path_rule_should_ignore_affected_only_match() {
        let rules = rules_with_direct_only_fixture();
        let changed_files = vec!["src/driver/blk/phytium.rs".to_string()];
        let changed_crates: Vec<String> = vec![];
        let affected_crates = vec!["driver".to_string()];
        let mut file_to_crate = HashMap::new();
        file_to_crate.insert("src/driver/blk/phytium.rs".to_string(), "driver".to_string());
        let out = decide_output(
            &rules,
            &changed_files,
            &changed_crates,
            &affected_crates,
            &file_to_crate,
        );
        // direct_only=true should not fire on affected-only, so fallback to all (target_order)
        assert!(!out.skip_all);
        assert_eq!(out.targets, vec!["board-phytium", "board-rk3568"]);
    }
}
