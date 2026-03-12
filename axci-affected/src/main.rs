//! AxCI affected-target selection engine.
//! Reads rules JSON, git diff, optional cargo metadata; outputs skip_all + ordered targets.

mod engine;

use std::env;
use std::path::Path;

fn main() {
    let args: Vec<String> = env::args().collect();
    let repo_dir = args.get(1).map(String::as_str).unwrap_or(".");
    let base_ref = args.get(2).map(String::as_str).unwrap_or("origin/main");
    let rules_path = args.get(3).map(String::as_str);

    let repo_path = Path::new(repo_dir);
    let result = engine::run(repo_path, base_ref, rules_path);

    match result {
        Ok(out) => {
            // Human-readable summary to stderr
            eprintln!("[affected] skip_all: {}", out.skip_all);
            eprintln!("[affected] targets: {:?}", out.targets);
            // Machine-readable JSON to stdout
            if let Err(e) = serde_json::to_writer(std::io::stdout(), &out) {
                eprintln!("error: {}", e);
                std::process::exit(1);
            }
        }
        Err(e) => {
            eprintln!("error: {}", e);
            std::process::exit(1);
        }
    }
}
