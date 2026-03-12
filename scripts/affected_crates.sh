#!/usr/bin/env bash
# 依赖感知：根据变更文件 + cargo metadata 计算 changed_crates 与 affected_crates。
# 输出 JSON 到 stdout:
# {"changed_crates": [...], "affected_crates": [...], "file_to_crate": {"path":"crate"}}
# 若无可用的 Cargo 或非 Rust 仓库，输出空数组。
set -euo pipefail

COMPONENT_DIR="${1:-.}"
BASE_REF="${2:-origin/main}"
# 可选：变更文件列表（每行一个路径），若不传则内部 git diff
CHANGED_FILES_ARG=""
if [[ $# -ge 3 && -n "${3:-}" ]]; then
  CHANGED_FILES_ARG="$3"
fi

cd "$COMPONENT_DIR"
REPO_ROOT="${PWD}"

get_changed_files() {
  if [[ -n "$CHANGED_FILES_ARG" ]]; then
    printf '%s' "$CHANGED_FILES_ARG"
    return
  fi
  local files
  files=$(git diff --name-only "$BASE_REF" 2>/dev/null || true)
  if [[ -z "$files" ]]; then
    files=$(git diff --name-only HEAD~1 2>/dev/null || true)
  fi
  printf '%s' "$files"
}

if [[ ! -f "Cargo.toml" ]]; then
  echo '{"changed_crates":[],"affected_crates":[],"file_to_crate":{}}'
  exit 0
fi

if ! command -v cargo &>/dev/null; then
  echo '{"changed_crates":[],"affected_crates":[],"file_to_crate":{}}'
  exit 0
fi

CHANGED_FILES=$(get_changed_files)
if [[ -z "$CHANGED_FILES" ]]; then
  echo '{"changed_crates":[],"affected_crates":[],"file_to_crate":{}}'
  exit 0
fi

# 需要完整 resolve 图做反向依赖，不加 --no-deps
METADATA=$(cargo metadata --format-version 1 2>/dev/null || true)
if [[ -z "$METADATA" ]]; then
  echo '{"changed_crates":[],"affected_crates":[],"file_to_crate":{}}'
  exit 0
fi

# workspace 成员 id 列表
MEMBERS_JSON=$(echo "$METADATA" | jq -c '.workspace_members // [.resolve.root]')
# 包 id -> 包名（仅 workspace 成员）
ID_TO_NAME=$(echo "$METADATA" | jq -c --argjson members "$MEMBERS_JSON" '
  [.packages[] | select(.id as $id | ($members | index($id)) != null) | {key: .id, value: .name}] | from_entries
')
# 各成员 crate 根目录（相对 workspace_root）
WS_ROOT=$(echo "$METADATA" | jq -r '.workspace_root')
CRATE_ROOT_BY_NAME=$(echo "$METADATA" | jq -c --arg ws "$WS_ROOT" --argjson members "$MEMBERS_JSON" '
  def dirname: split("/")[0:-1] | join("/") | sub("^\\./"; "") | sub("/$"; "");
  def rel: if ($ws != "" and (.[:($ws | length)] == $ws)) then .[($ws | length):] | sub("^/"; "") else . end;
  [.packages[] | select(.id as $id | ($members | index($id)) != null)
   | {key: .name, value: (.manifest_path | rel | dirname | if . == "" then "." else . end)}]
  | map(select(.value != null)) | from_entries
')
if [[ -z "$CRATE_ROOT_BY_NAME" || "$CRATE_ROOT_BY_NAME" == "null" ]]; then
  echo '{"changed_crates":[],"affected_crates":[],"file_to_crate":{}}'
  exit 0
fi

# 变更文件 -> 所属 crate（最长前缀匹配）
changed_crates_arr=()
file_to_crate_json='{}'
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  f="${f#./}"
  best_crate=""
  best_len=0
  for name in $(echo "$CRATE_ROOT_BY_NAME" | jq -r 'keys[]'); do
    root=$(echo "$CRATE_ROOT_BY_NAME" | jq -r --arg n "$name" '.[$n]')
    [[ -z "$root" || "$root" == "null" ]] && continue
    if [[ "$root" == "." || "$f" == "$root" || "$f" == "$root"/* ]]; then
      if [[ "$root" == "." ]]; then
        len=0
      else
        len=${#root}
      fi
      if (( len > best_len )); then
        best_len=$len
        best_crate="$name"
      fi
    fi
  done
  if [[ -n "$best_crate" ]]; then
    changed_crates_arr+=("$best_crate")
    file_to_crate_json=$(echo "$file_to_crate_json" | jq -c --arg f "$f" --arg c "$best_crate" '. + {($f): $c}')
  fi
done <<< "$CHANGED_FILES"

CHANGED_CRATES_JSON=$(printf '%s\n' "${changed_crates_arr[@]}" | sort -u | jq -Rsc 'split("\n") | map(select(length>0))')

# 反向依赖：被依赖的 id -> [依赖它的 id]
REV_DEPS_RAW=$(echo "$METADATA" | jq -c '
  [.resolve.nodes[]? | . as $n | .deps[]? | {"rev": .pkg, "deponent": $n.id}]
  | group_by(.rev) | map({key: .[0].rev, value: [.[].deponent]}) | from_entries
')
# 转成 name -> [dependent names]（只保留 workspace 内的）
REV_DEPS_JSON=$(echo "$METADATA" | jq -c --argjson id2name "$ID_TO_NAME" --argjson rev "$REV_DEPS_RAW" '
  $rev | to_entries | map(
    ($id2name[.key] // .key) as $kname |
    {key: $kname, value: [.value[]? | $id2name[.]? // empty] | map(select(. != null))}
  ) | map(select((.value | length) > 0)) | from_entries
')
if [[ -z "$REV_DEPS_JSON" || "$REV_DEPS_JSON" == "null" ]]; then
  REV_DEPS_JSON="{}"
fi

# BFS 从 changed 扩散到 affected
affected_crates_arr=()
changed_arr=($(echo "$CHANGED_CRATES_JSON" | jq -r '.[]'))
declare -A visited
for c in "${changed_arr[@]}"; do
  affected_crates_arr+=("$c")
  visited[$c]=1
done
queue=("${changed_arr[@]}")
head=0
while [[ $head -lt ${#queue[@]} ]]; do
  cur="${queue[$head]}"
  head=$((head+1))
  deps=$(echo "$REV_DEPS_JSON" | jq -r --arg c "$cur" '.[$c][]? // empty')
  for d in $deps; do
    if [[ -z "${visited[$d]:-}" ]]; then
      visited[$d]=1
      affected_crates_arr+=("$d")
      queue+=("$d")
    fi
  done
done

AFFECTED_CRATES_JSON=$(printf '%s\n' "${affected_crates_arr[@]}" | sort -u | jq -Rsc 'split("\n") | map(select(length>0))')

echo "{\"changed_crates\":$CHANGED_CRATES_JSON,\"affected_crates\":$AFFECTED_CRATES_JSON,\"file_to_crate\":$file_to_crate_json}"
