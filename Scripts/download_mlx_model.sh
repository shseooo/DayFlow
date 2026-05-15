#!/bin/bash
#
# 빌드 시점에 MLX 모델 파일을 HuggingFace 에서 받아 앱 번들에 포함시키기 위해
# 프로젝트 디렉토리에 다운로드한다. Xcode 의 Run Script Phase 에서 호출되며,
# 이미 받아둔 파일이 있으면 skip 한다 (idempotent).
#
# 다운로드 대상 디렉토리: $SRCROOT/DayFlow/MLXModels/<repo-basename>/
# 이 디렉토리를 Xcode target 의 Resources 에 folder reference (파란 폴더) 로
# 등록하면, 빌드 결과 .app/Contents/Resources/MLXModels/... 에 그대로 복사된다.

set -euo pipefail

# Xcode 가 SRCROOT 를 항상 set 해주지만, 로컬에서 단독 실행할 때도 동작하도록 fallback.
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

MODEL_REPO="mlx-community/gemma-4-e2b-it-4bit"
MODEL_BASENAME="$(basename "$MODEL_REPO")"
# Xcode 의 PBXFileSystemSynchronizedRootGroup 이 ${SRCROOT}/MLXModels 를 보고 있으므로
# 프로젝트 루트 (DayFlow/ 와 같은 레벨) 의 MLXModels 디렉토리에 받는다.
TARGET_DIR="${SRCROOT}/MLXModels/${MODEL_BASENAME}"

# MLX VLM 이 모델 디렉토리에서 기대하는 파일 셋.
# mlx-community 변환 본은 single-shard safetensors 인 경우가 많지만,
# 일부 모델은 multi-shard (model-00001-of-00002.safetensors 같은) 일 수 있어
# index 파일을 우선 받고 거기 적힌 shard 들을 다 받는 식으로 처리한다.
#
# 필수: 모델/토크나이저 동작에 반드시 필요한 최소 셋.
REQUIRED_FILES=(
    "config.json"
    "tokenizer.json"
    "tokenizer_config.json"
)

# 선택: 리포에 있을 수도 / 없을 수도 있는 파일. file_exists_remote 로 먼저 확인 후 받는다.
# - special_tokens_map.json, added_tokens.json: 일부 모델에서만 분리 제공 (Gemma 계열은 tokenizer.json 내부에 통합)
# - generation_config.json: 기본 sampling 파라미터. 없으면 디폴트 사용
# - preprocessor_config.json / processor_config.json: VLM 의 이미지 전처리 설정
# - chat_template.json / chat_template.jinja: 채팅 템플릿 별도 제공 시
OPTIONAL_FILES=(
    "special_tokens_map.json"
    "generation_config.json"
    "preprocessor_config.json"
    "processor_config.json"
    "chat_template.json"
    "chat_template.jinja"
    "added_tokens.json"
)

mkdir -p "$TARGET_DIR"

hf_url() {
    echo "https://huggingface.co/${MODEL_REPO}/resolve/main/$1"
}

# HEAD 로 존재 확인 (Hugging Face 는 LFS 리다이렉트가 있어 --head 만으로는 부족)
file_exists_remote() {
    local file="$1"
    local code
    code=$(curl -sLI -o /dev/null -w "%{http_code}" "$(hf_url "$file")")
    [[ "$code" == "200" ]]
}

# 파일 다운로드 (resume 가능, 부분 파일은 자동 처리)
download_file() {
    local file="$1"
    local dst="$TARGET_DIR/$file"
    if [[ -f "$dst" ]] && [[ -s "$dst" ]]; then
        echo "  ✓ cached: $file"
        return 0
    fi
    echo "  ↓ downloading: $file"
    curl -L --fail --retry 3 --retry-delay 2 \
        --create-dirs \
        -o "$dst.part" \
        "$(hf_url "$file")"
    mv "$dst.part" "$dst"
}

echo "[download_mlx_model] target = $TARGET_DIR"
echo "[download_mlx_model] repo   = $MODEL_REPO"

# 필수 파일
for f in "${REQUIRED_FILES[@]}"; do
    download_file "$f"
done

# 선택 파일 (있으면 받고, 없으면 통과)
for f in "${OPTIONAL_FILES[@]}"; do
    if file_exists_remote "$f"; then
        download_file "$f"
    fi
done

# safetensors weights 처리:
# 1) index 파일이 있으면 그것을 받고, 거기서 shard 파일명을 뽑아내 일괄 다운로드
# 2) 없으면 single-file model.safetensors 다운로드
INDEX_FILE="model.safetensors.index.json"
if file_exists_remote "$INDEX_FILE"; then
    download_file "$INDEX_FILE"
    # weight_map 의 값(파일명)들을 유니크 추출
    SHARDS=$(python3 -c "
import json, sys
with open('${TARGET_DIR}/${INDEX_FILE}') as f:
    idx = json.load(f)
print('\n'.join(sorted(set(idx.get('weight_map', {}).values()))))
")
    while IFS= read -r shard; do
        [[ -z "$shard" ]] && continue
        download_file "$shard"
    done <<< "$SHARDS"
else
    download_file "model.safetensors"
fi

echo "[download_mlx_model] done."
